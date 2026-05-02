(* Caller must load HOLSourceParser, TacticParse, smlExecute, and smlTimeout
   before using this helper; the generated staged script does that prelude. *)
structure HolbuildGoalfragRuntime =
struct

type config = {checkpoint_enabled : bool,
               tactic_timeout : real option,
               timeout_marker : string option,
               plan_theorem : string option,
               trace_all : bool,
               plan_only_marker : string option}

val checkpoint_enabled_ref = ref false
val tactic_timeout_ref = ref (NONE : real option)
val tactic_timeout_marker_ref = ref (NONE : string option)
val plan_theorem_ref = ref (NONE : string option)
val trace_all_ref = ref false
val plan_only_marker_ref = ref (NONE : string option)
val plan_active_ref = ref false
val trace_active_ref = ref false
val trace_current_theorem_ref = ref ""
val theorem_info_ref = ref NONE : (string * string * string * string * string * string * string * string * string * bool * int) option ref
val context_info_ref = ref NONE : (string * string * int) option ref
val proving_with_goalfrag_ref = ref false
val active_tactic_text_ref = ref ""
val successful_step_count_ref = ref 0
val successful_prefix_end_ref = ref 0

fun env_bool name =
  case OS.Process.getEnv name of
      SOME "1" => SOME true
    | SOME "true" => SOME true
    | SOME "yes" => SOME true
    | SOME "0" => SOME false
    | SOME "false" => SOME false
    | SOME "no" => SOME false
    | _ => NONE

fun bool_text true = "true"
  | bool_text false = "false"

fun seconds (a, b) = Time.toReal (Time.-(b, a))

fun fmt_time t = Real.fmt (StringCvt.FIX (SOME 3)) t
fun fmt_ms t = Real.fmt (StringCvt.FIX (SOME 3)) (1000.0 * t)

fun delete_file path = OS.FileSys.remove path handle _ => ()

fun file_exists path = OS.FileSys.access(path, [OS.FileSys.A_READ]) handle _ => false

fun rename_file old new = OS.FileSys.rename {old = old, new = new}

fun rename_if_exists old new = if file_exists old then rename_file old new else ()

fun delete_checkpoint path =
  (delete_file (path ^ ".ok.bak");
   delete_file (path ^ ".bak");
   delete_file (path ^ ".ok");
   delete_file (path ^ ".meta");
   delete_file (path ^ ".prefix");
   delete_file path)

fun write_checkpoint_ok path ok_text =
  let val out = TextIO.openOut (path ^ ".ok")
  in TextIO.output(out, ok_text); TextIO.closeOut out end

(* Keep the new checkpoint filename stable. PolyML child states record parent
   filenames, so saving to a temporary filename and then renaming can leave a
   later child unable to find its parent. A future implementation may use PolyML
   parent-name retargeting, but until that is explicit and tested we replace in
   place with a .bak pair that checkpoint selection can restore after interrupt. *)
fun backup_checkpoint path =
  (delete_file (path ^ ".bak");
   delete_file (path ^ ".ok.bak");
   rename_if_exists (path ^ ".ok") (path ^ ".ok.bak");
   rename_if_exists path (path ^ ".bak"))

fun discard_checkpoint_backup path =
  (delete_file (path ^ ".bak"); delete_file (path ^ ".ok.bak"))

fun write_timeout_marker label seconds =
  case !tactic_timeout_marker_ref of
      NONE => ()
    | SOME path =>
        let val out = TextIO.openOut path
        in TextIO.output(out, String.concat [label, "\t", Real.toString seconds, "\n"]);
           TextIO.closeOut out
        end

fun timeout_message label seconds =
  String.concat ["holbuild tactic timeout after ", Real.toString seconds, "s: ", label]

fun with_tactic_timeout label f x =
  case !tactic_timeout_ref of
      NONE => f x
    | SOME seconds =>
        (smlTimeout.timeout seconds f x
         handle smlTimeout.FunctionTimeout =>
           (write_timeout_marker label seconds;
            raise Fail (timeout_message label seconds)))

fun save_checkpoint label default_share path ok_text depth =
  if not (!checkpoint_enabled_ref) then ()
  else
    let
      val share = Option.getOpt(env_bool "HOLBUILD_SHARE_COMMON_DATA", default_share)
      val timing = Option.getOpt(env_bool "HOLBUILD_CHECKPOINT_TIMING", false)
      val t0 = Time.now()
      val _ = backup_checkpoint path
      val _ = if share then PolyML.shareCommonData PolyML.rootFunction else ()
      val t1 = Time.now()
      val _ = PolyML.SaveState.saveChild(path, depth)
      val t2 = Time.now()
      val _ = write_checkpoint_ok path ok_text
      val _ = discard_checkpoint_backup path
      val _ =
        if timing then
          TextIO.output
            (TextIO.stdErr,
             String.concat ["holbuild checkpoint kind=", label,
                            " share=", bool_text share,
                            " depth=", Int.toString depth,
                            " share_s=", fmt_time (seconds (t0, t1)),
                            " save_s=", fmt_time (seconds (t1, t2)),
                            " size=", Position.toString (OS.FileSys.fileSize path),
                            " path=", path, "\n"])
        else ()
    in () end

fun write_text_file path text =
  let val out = TextIO.openOut path
  in TextIO.output(out, text); TextIO.closeOut out end

fun save_failed_prefix_checkpoint () =
  case !theorem_info_ref of
      NONE => ()
    | SOME (kind, _, _, _, _, _, _, failed_prefix_path, failed_prefix_ok, _, depth) =>
        if kind <> "theorem" orelse not (!checkpoint_enabled_ref) then ()
        else
          let
            val prefix_end = !successful_prefix_end_ref
            val prefix_text = String.substring(!active_tactic_text_ref, 0, prefix_end)
            val meta_text =
              String.concat ["step_count=", Int.toString (!successful_step_count_ref), "\n",
                             "prefix_end=", Int.toString prefix_end, "\n"]
            val _ = save_checkpoint "failed_prefix" false failed_prefix_path failed_prefix_ok depth
            val _ = write_text_file (failed_prefix_path ^ ".meta") meta_text
            val _ = write_text_file (failed_prefix_path ^ ".prefix") prefix_text
          in () end

fun begin_theorem (kind, name, tactic_text, context_path, context_ok,
                   end_path, end_ok, failed_prefix_path, failed_prefix_ok, has_attrs) =
  let val depth = length (PolyML.SaveState.showHierarchy())
  in
    theorem_info_ref := SOME (kind, name, tactic_text, context_path, context_ok,
                              end_path, end_ok, failed_prefix_path, failed_prefix_ok, has_attrs, depth);
    context_info_ref := SOME (context_path, context_ok, depth)
  end

fun save_theorem_context () =
  case !context_info_ref of
      NONE => ()
    | SOME (context_path, context_ok, depth) =>
        (context_info_ref := NONE;
         save_checkpoint "theorem_context" false context_path context_ok depth)

fun top_goal_text [] = "<no open goals>\n"
  | top_goal_text (goal :: _) = PP.pp_to_string 100 proofManagerLib.std_goal_pp goal ^ "\n"

fun active_theorem_name () =
  case !theorem_info_ref of
      SOME (_, name, _, _, _, _, _, _, _, _, _) => SOME name
    | NONE => NONE

fun failed_theorem_line () =
  case active_theorem_name () of
      NONE => ""
    | SOME name => "\nholbuild failed theorem: " ^ name

fun print_goal_state label =
  let
    val goals = proofManagerLib.top_goals()
  in
    TextIO.output(TextIO.stdErr,
      String.concat ["\nholbuild goal state at failed fragment: ", label,
                     failed_theorem_line (),
                     "\nholbuild remaining goals: ", Int.toString (length goals), "\n",
                     "holbuild top goal:\n",
                     top_goal_text goals,
                     "holbuild end top goal\n"])
  end
  handle e =>
    TextIO.output(TextIO.stdErr,
      String.concat ["holbuild failed to print goal state: ", General.exnMessage e, "\n"])

fun parse_tactic s =
  let
    val fed = ref false
    fun read _ = if !fed then "" else (fed := true; s)
    val result =
      HOLSourceParser.parseSML "<holbuild tactic>" read
        (fn _ => fn _ => fn msg => raise Fail msg)
        HOLSourceParser.initialScope
  in
    case #parseDec result () of
        SOME (HOLSourceAST.DecExp e) => TacticParse.parseTacticBlock e
      | NONE => TacticParse.parseTacticBlock (HOLSourceAST.ExpEmpty 0)
      | _ => raise Fail "expected tactic expression"
  end

fun flatten_frags frags =
  let
    fun go [] acc = rev acc
      | go (TacticParse.FFOpen opn :: rest) acc = go rest (TacticParse.FFOpen opn :: acc)
      | go (TacticParse.FFMid mid :: rest) acc = go rest (TacticParse.FFMid mid :: acc)
      | go (TacticParse.FFClose cls :: rest) acc = go rest (TacticParse.FFClose cls :: acc)
      | go (TacticParse.FAtom a :: rest) acc = go rest (TacticParse.FAtom a :: acc)
      | go (TacticParse.FGroup (_, inner) :: rest) acc = go rest (rev (flatten_frags inner) @ acc)
      | go (TacticParse.FBracket (opn, inner, cls, _) :: rest) acc =
          let val flat = TacticParse.FFOpen opn :: flatten_frags inner @ [TacticParse.FFClose cls]
          in go rest (rev flat @ acc) end
      | go (TacticParse.FMBracket (opn, mid, cls, [], _) :: rest) acc =
          go rest (TacticParse.FFClose cls :: TacticParse.FFOpen opn :: acc)
      | go (TacticParse.FMBracket (opn, mid, cls, arms, _) :: rest) acc =
          let
            fun interleave [] _ = []
              | interleave [a] _ = flatten_frags a
              | interleave (a::as') mid = flatten_frags a @ [TacticParse.FFMid mid] @ interleave as' mid
            val flat = TacticParse.FFOpen opn :: interleave arms mid @ [TacticParse.FFClose cls]
          in go rest (rev flat @ acc) end
  in go frags [] end

fun alt_span (TacticParse.Subgoal (s, e)) = SOME (s, e)
  | alt_span (TacticParse.Rename p) = SOME p
  | alt_span (TacticParse.LSelectGoal p) = SOME p
  | alt_span (TacticParse.LSelectGoals p) = SOME p
  | alt_span (TacticParse.LTacsToLT (TacticParse.OOpaque (_, p))) = SOME p
  | alt_span _ = NONE

fun frag_end (TacticParse.FAtom a) =
      (case (TacticParse.topSpan a, alt_span a) of
           (SOME (_, r), _) => r
         | (NONE, SOME (_, r)) => r
         | _ => 0)
  | frag_end _ = 0

fun is_composable (TacticParse.Then _) = true
  | is_composable (TacticParse.ThenLT _) = true
  | is_composable (TacticParse.LThen1 _) = true
  | is_composable (TacticParse.LThenLT _) = true
  | is_composable (TacticParse.Group _) = true
  | is_composable _ = false

fun span_text body (a, b) = String.substring(body, a, b - a)

fun text_contains_reverse body sp =
  let val s = span_text body sp
  in String.isSubstring "REVERSE" s orelse String.isSubstring "reverse" s end

fun opaque_text body sp = span_text body sp

fun exprs_contain_reverse body es = List.exists (expr_contains_reverse body) es
and expr_contains_reverse body e =
  case e of
      TacticParse.Then es => exprs_contain_reverse body es
    | TacticParse.ThenLT (e, es) => expr_contains_reverse body e orelse exprs_contain_reverse body es
    | TacticParse.First es => exprs_contain_reverse body es
    | TacticParse.Try e => expr_contains_reverse body e
    | TacticParse.Repeat e => expr_contains_reverse body e
    | TacticParse.MapEvery (sp, es) => text_contains_reverse body sp orelse exprs_contain_reverse body es
    | TacticParse.MapFirst (sp, es) => text_contains_reverse body sp orelse exprs_contain_reverse body es
    | TacticParse.Opaque (_, sp) => text_contains_reverse body sp
    | TacticParse.LThen (e, es) => expr_contains_reverse body e orelse exprs_contain_reverse body es
    | TacticParse.LThenLT es => exprs_contain_reverse body es
    | TacticParse.LThen1 e => expr_contains_reverse body e
    | TacticParse.LTacsToLT e => expr_contains_reverse body e
    | TacticParse.LNullOk e => expr_contains_reverse body e
    | TacticParse.LFirst es => exprs_contain_reverse body es
    | TacticParse.LAllGoals e => expr_contains_reverse body e
    | TacticParse.LNthGoal (e, sp) => expr_contains_reverse body e orelse text_contains_reverse body sp
    | TacticParse.LLastGoal e => expr_contains_reverse body e
    | TacticParse.LHeadGoal e => expr_contains_reverse body e
    | TacticParse.LSplit (sp, e1, e2) => text_contains_reverse body sp orelse expr_contains_reverse body e1 orelse expr_contains_reverse body e2
    | TacticParse.LReverse => false
    | TacticParse.LTry e => expr_contains_reverse body e
    | TacticParse.LRepeat e => expr_contains_reverse body e
    | TacticParse.LFirstLT e => expr_contains_reverse body e
    | TacticParse.LSelectThen (e1, e2) => expr_contains_reverse body e1 orelse expr_contains_reverse body e2
    | TacticParse.LOpaque (_, sp) => text_contains_reverse body sp
    | TacticParse.List (sp, es) => text_contains_reverse body sp orelse exprs_contain_reverse body es
    | TacticParse.Group (_, sp, e) => text_contains_reverse body sp orelse expr_contains_reverse body e
    | TacticParse.RepairGroup (sp, _, e, _) => text_contains_reverse body sp orelse expr_contains_reverse body e
    | TacticParse.OOpaque (_, sp) => text_contains_reverse body sp
    | _ => false

fun exprs_contain_tacs_to_lt es = List.exists expr_contains_tacs_to_lt es
and expr_contains_tacs_to_lt e =
  case e of
      TacticParse.Then es => exprs_contain_tacs_to_lt es
    | TacticParse.ThenLT (e, es) => expr_contains_tacs_to_lt e orelse exprs_contain_tacs_to_lt es
    | TacticParse.Group (_, _, e) => expr_contains_tacs_to_lt e
    | TacticParse.RepairGroup (_, _, e, _) => expr_contains_tacs_to_lt e
    | TacticParse.LNullOk e => expr_contains_tacs_to_lt e
    | TacticParse.LTacsToLT _ => true
    | _ => false

fun tacs_to_lt_branch_expr (TacticParse.ThenLT (_, [TacticParse.LNullOk (TacticParse.LTacsToLT _)])) = true
  | tacs_to_lt_branch_expr (TacticParse.Group (_, _, e)) = tacs_to_lt_branch_expr e
  | tacs_to_lt_branch_expr _ = false

fun expr_source_contains_reverse body e =
  case TacticParse.topSpan e of
      SOME sp => text_contains_reverse body sp
    | NONE => false

fun reverse_branch_expr body (TacticParse.ThenLT (lhs, [rhs as TacticParse.LNullOk (TacticParse.LTacsToLT _)])) =
      expr_source_contains_reverse body lhs orelse expr_contains_reverse body lhs orelse expr_contains_reverse body rhs
  | reverse_branch_expr body (TacticParse.ThenLT (lhs, [rhs as TacticParse.LThen1 _])) =
      expr_source_contains_reverse body lhs orelse expr_contains_reverse body lhs orelse expr_contains_reverse body rhs
  | reverse_branch_expr body (TacticParse.Group (_, _, e)) = reverse_branch_expr body e
  | reverse_branch_expr _ _ = false

fun group_atom_expr body (TacticParse.FAtom (TacticParse.Group (_, _, e))) =
      if expr_contains_tacs_to_lt e orelse reverse_branch_expr body e then NONE
      else if is_composable e then SOME e else NONE
  | group_atom_expr _ _ = NONE

fun expr_contains_then1 e =
  case e of
      TacticParse.Then es => List.exists expr_contains_then1 es
    | TacticParse.ThenLT (lhs, es) => expr_contains_then1 lhs orelse List.exists expr_contains_then1 es
    | TacticParse.Group (_, _, e) => expr_contains_then1 e
    | TacticParse.RepairGroup (_, _, e, _) => expr_contains_then1 e
    | TacticParse.LNullOk e => expr_contains_then1 e
    | TacticParse.LThen1 _ => true
    | _ => false

fun scope_per_goal_if_needed e frags =
  if expr_contains_then1 e then
    TacticParse.FFOpen TacticParse.FOpen :: frags @ [TacticParse.FFClose TacticParse.FClose]
  else frags

fun reexpand_group_atoms body frags =
  let
    fun reexpand e =
      let val subFrags = TacticParse.linearize (fn x => Option.isSome (TacticParse.topSpan x)) e
      in scope_per_goal_if_needed e (reexpand_group_atoms body (flatten_frags subFrags)) end
    fun go [] acc = rev acc
      | go (f::rest) acc =
          (case group_atom_expr body f of
               SOME e => go rest (rev (reexpand e) @ acc)
             | NONE => go rest (f :: acc))
  in go frags [] end

fun open_name TacticParse.FOpen = "open_paren"
  | open_name TacticParse.FOpenThen1 = "open_then1"
  | open_name TacticParse.FOpenFirst = "open_first"
  | open_name TacticParse.FOpenRepeat = "open_repeat"
  | open_name TacticParse.FOpenTacsToLT = "open_tacs_to_lt"
  | open_name TacticParse.FOpenNullOk = "open_null_ok"
  | open_name (TacticParse.FOpenNthGoal (i, _)) = "open_nth_goal " ^ Int.toString i
  | open_name TacticParse.FOpenLastGoal = "open_last_goal"
  | open_name TacticParse.FOpenHeadGoal = "open_head_goal"
  | open_name (TacticParse.FOpenSplit (i, _)) = "open_split_lt " ^ Int.toString i
  | open_name TacticParse.FOpenSelect = "open_select_lt"
  | open_name TacticParse.FOpenFirstLT = "open_first_lt"

fun mid_name TacticParse.FNextFirst = "next_first"
  | mid_name TacticParse.FNextTacsToLT = "next_tacs_to_lt"
  | mid_name TacticParse.FNextSplit = "next_split_lt"
  | mid_name TacticParse.FNextSelect = "next_select_lt"

fun close_name TacticParse.FClose = "close_paren"
  | close_name TacticParse.FCloseFirst = "close_first"
  | close_name TacticParse.FCloseRepeat = "close_repeat"
  | close_name TacticParse.FCloseFirstLT = "close_first_lt"

datatype goalfrag_step =
    StepOpen of {end_pos : int, label : string}
  | StepMid of {end_pos : int, label : string}
  | StepClose of {end_pos : int, label : string}
  | StepExpand of {end_pos : int, label : string}
  | StepExpandList of {end_pos : int, label : string}
  | StepSelect of {end_pos : int, label : string}
  | StepSelects of {end_pos : int, label : string}

fun step_end (StepOpen {end_pos, ...}) = end_pos
  | step_end (StepMid {end_pos, ...}) = end_pos
  | step_end (StepClose {end_pos, ...}) = end_pos
  | step_end (StepExpand {end_pos, ...}) = end_pos
  | step_end (StepExpandList {end_pos, ...}) = end_pos
  | step_end (StepSelect {end_pos, ...}) = end_pos
  | step_end (StepSelects {end_pos, ...}) = end_pos

fun step_label (StepOpen {label, ...}) = label
  | step_label (StepMid {label, ...}) = label
  | step_label (StepClose {label, ...}) = label
  | step_label (StepExpand {label, ...}) = label
  | step_label (StepExpandList {label, ...}) = label
  | step_label (StepSelect {label, ...}) = label
  | step_label (StepSelects {label, ...}) = label

fun step_kind (StepOpen _) = "open"
  | step_kind (StepMid _) = "mid"
  | step_kind (StepClose _) = "close"
  | step_kind (StepExpand _) = "expand"
  | step_kind (StepExpandList _) = "expand_list"
  | step_kind (StepSelect _) = "select"
  | step_kind (StepSelects _) = "selects"

fun substring s (a, b) = String.substring(s, a, b - a)

fun raw_frag_text body a =
  case (TacticParse.topSpan a, alt_span a) of
      (SOME sp, _) => substring body sp
    | (NONE, SOME sp) => substring body sp
    | _ => ""

fun is_term_quote raw =
  String.isPrefix "`" raw orelse
  String.isPrefix "\226\128\152" raw orelse
  String.isPrefix "\226\128\156" raw

fun frag_text body (TacticParse.FAtom a) =
      let val raw = raw_frag_text body a
      in
        case a of
            TacticParse.LReverse => "Tactical.REVERSE_LT"
          | TacticParse.LTacsToLT _ => if String.size raw = 0 then raw else "Tactical.TACS_TO_LT (" ^ raw ^ ")"
          | TacticParse.Rename _ => "Q.RENAME_TAC " ^ raw
          | TacticParse.Group (_, _, TacticParse.Rename _) => "Q.RENAME_TAC " ^ raw
          | TacticParse.Subgoal _ => if is_term_quote raw then "sg " ^ raw else raw
          | _ => raw
      end
  | frag_text _ (TacticParse.FFOpen opn) = open_name opn
  | frag_text _ (TacticParse.FFMid mid) = mid_name mid
  | frag_text _ (TacticParse.FFClose cls) = close_name cls
  | frag_text _ _ = ""

fun is_select_step (StepSelect _) = true
  | is_select_step (StepSelects _) = true
  | is_select_step _ = false

fun select_prefix_step (StepSelect {label, ...}) = "Q.SELECT_GOAL_LT " ^ label
  | select_prefix_step (StepSelects {label, ...}) = "Q.SELECT_GOALS_LT " ^ label
  | select_prefix_step _ = raise Fail "expected select step"

fun join_tactic [] = "ALL_TAC"
  | join_tactic [t] = t
  | join_tactic ts = String.concatWith " \\\\ " ts

fun collect_then1_steps steps =
  let
    fun go [] _ _ = NONE
      | go (StepClose _ :: rest) acc last = SOME (join_tactic (rev acc), last, rest)
      | go (StepExpand {end_pos, label} :: rest) acc _ = go rest (label :: acc) end_pos
      | go _ _ _ = NONE
  in go steps [] 0 end

fun merge_reverse_steps [] acc = rev acc
  | merge_reverse_steps (StepExpandList {label = "Tactical.REVERSE_LT", ...} :: rest)
                        (StepExpand {end_pos, label} :: acc) =
      merge_reverse_steps rest (StepExpand {end_pos = end_pos, label = "Tactical.REVERSE (" ^ label ^ ")"} :: acc)
  | merge_reverse_steps (step :: rest) acc = merge_reverse_steps rest (step :: acc)

fun drop_prefix prefix text =
  if String.isPrefix prefix text then SOME (String.extract(text, size prefix, NONE)) else NONE

fun rename_pattern label =
  case drop_prefix "Q.RENAME_TAC " label of
      SOME pattern => pattern
    | NONE => label

fun merge_select_then1_steps [] acc = rev acc
  | merge_select_then1_steps (StepOpen {label = "open_select_lt", ...} ::
                              StepExpand {label = pattern, ...} ::
                              StepMid {label = "next_select_lt", ...} ::
                              StepOpen {label = "open_paren", ...} :: rest) acc =
      (case collect_then1_steps rest of
           SOME (tacText, tacEnd, StepClose _ :: rest') =>
             merge_select_then1_steps rest'
               (StepExpandList {end_pos = tacEnd,
                                label = "Q.SELECT_GOALS_LT_THEN1 " ^ rename_pattern pattern ^ " (" ^ tacText ^ ")"} :: acc)
         | _ => merge_select_then1_steps rest acc)
  | merge_select_then1_steps (step :: rest) acc = merge_select_then1_steps rest (step :: acc)

fun merge_select_steps [] acc = rev acc
  | merge_select_steps (selectStep :: rest) acc =
      if is_select_step selectStep then
        let
          fun collect [] sels = (rev sels, [])
            | collect (step :: rest') sels =
                if is_select_step step then collect rest' (step :: sels) else (rev sels, step :: rest')
          val (sels, afterSels) = collect rest [selectStep]
          fun prefix [] = ""
            | prefix (first :: rest) =
                String.concatWith " >>~ " (map select_prefix_step (first :: rest))
          val selectPrefix = prefix sels
          val selectEnd = step_end (List.last sels)
          fun consume (StepOpen {label = "open_then1", ...} :: StepExpand {end_pos, label} :: StepClose _ :: rest') =
                SOME (selectPrefix ^ " >- " ^ label, end_pos, rest')
            | consume (StepOpen {label = "open_first", ...} :: StepExpand {end_pos, label} :: StepClose _ :: rest') =
                SOME (selectPrefix ^ " >- " ^ label, end_pos, rest')
            | consume _ = NONE
        in
          case consume afterSels of
              SOME (text, tacEnd, rest') => merge_select_steps rest' (StepExpandList {end_pos = tacEnd, label = text} :: acc)
            | NONE => merge_select_steps afterSels (StepExpandList {end_pos = selectEnd, label = selectPrefix} :: acc)
        end
      else merge_select_steps rest (selectStep :: acc)

fun step_of_frag end_pos label (TacticParse.FAtom (TacticParse.LSelectGoal _)) =
      SOME (StepSelect {end_pos = end_pos, label = label})
  | step_of_frag end_pos label (TacticParse.FAtom (TacticParse.LSelectGoals _)) =
      SOME (StepSelects {end_pos = end_pos, label = label})
  | step_of_frag end_pos label (TacticParse.FAtom TacticParse.LReverse) =
      SOME (StepExpandList {end_pos = end_pos, label = label})
  | step_of_frag end_pos label (TacticParse.FAtom (TacticParse.LTacsToLT _)) =
      SOME (StepExpandList {end_pos = end_pos, label = label})
  | step_of_frag end_pos label (TacticParse.FAtom _) =
      SOME (StepExpand {end_pos = end_pos, label = label})
  | step_of_frag end_pos label (TacticParse.FFOpen _) =
      SOME (StepOpen {end_pos = end_pos, label = label})
  | step_of_frag end_pos label (TacticParse.FFMid _) =
      SOME (StepMid {end_pos = end_pos, label = label})
  | step_of_frag end_pos label (TacticParse.FFClose _) =
      SOME (StepClose {end_pos = end_pos, label = label})
  | step_of_frag _ _ _ = NONE

fun steps body =
  let
    val tree = parse_tactic body
    fun atomic_group e = tacs_to_lt_branch_expr e orelse reverse_branch_expr body e
    fun isAtom (TacticParse.Group (_, _, e)) = atomic_group e
      | isAtom (TacticParse.RepairGroup (_, _, e, _)) = atomic_group e
      | isAtom e = Option.isSome (TacticParse.topSpan e)
    val frags = reexpand_group_atoms body (flatten_frags (TacticParse.linearize isAtom tree))
    fun assign [] _ acc = rev acc
      | assign (f::rest) last acc =
          let
            val txt = frag_text body f
            val (endPos, last') =
              case f of
                  TacticParse.FAtom _ => let val e = frag_end f in (e, e) end
                | _ => (last, last)
          in
            if String.size txt = 0 then assign rest last acc
            else
              case step_of_frag endPos txt f of
                  SOME step => assign rest last' (step :: acc)
                | NONE => assign rest last acc
          end
    fun shift_step delta step =
      case step of
          StepOpen {end_pos, label} => StepOpen {end_pos = end_pos + delta, label = label}
        | StepMid {end_pos, label} => StepMid {end_pos = end_pos + delta, label = label}
        | StepClose {end_pos, label} => StepClose {end_pos = end_pos + delta, label = label}
        | StepExpand {end_pos, label} => StepExpand {end_pos = end_pos + delta, label = label}
        | StepExpandList {end_pos, label} => StepExpandList {end_pos = end_pos + delta, label = label}
        | StepSelect {end_pos, label} => StepSelect {end_pos = end_pos + delta, label = label}
        | StepSelects {end_pos, label} => StepSelects {end_pos = end_pos + delta, label = label}
    fun trim_left text =
      let
        val n = size text
        fun loop i = if i >= n orelse not (Char.isSpace (String.sub(text, i))) then i else loop (i + 1)
      in String.extract(text, loop 0, NONE) end
    fun find_from needle text start =
      let
        val n = size text
        val m = size needle
        fun loop i =
          if i + m > n then NONE
          else if String.substring(text, i, m) = needle then SOME i
          else loop (i + 1)
      in if m = 0 then NONE else loop start end
    fun reverse_branch_split label =
      let
        fun candidate needle =
          case find_from needle label 0 of
              NONE => NONE
            | SOME i => Option.map (fn _ => i) (find_from ">-" label i)
        fun earliest (NONE, x) = x
          | earliest (x, NONE) = x
          | earliest (SOME a, SOME b) = SOME (Int.min(a, b))
      in earliest (candidate ">> reverse", candidate ">> Tactical.REVERSE") end
    fun split_reverse_branch_step (StepExpand {end_pos, label}) =
          (case reverse_branch_split label of
               NONE => [StepExpand {end_pos = end_pos, label = label}]
             | SOME split =>
                 let
                   val prefix = String.substring(label, 0, split)
                   val suffix = trim_left (String.extract(label, split + 2, NONE))
                   val start_pos = end_pos - size label
                 in
                   if trim_left prefix = "" then [StepExpand {end_pos = end_pos, label = label}]
                   else map (shift_step start_pos) (steps prefix) @ [StepExpand {end_pos = end_pos, label = suffix}]
                 end)
      | split_reverse_branch_step step = [step]
    fun split_reverse_branch_steps steps' = List.concat (map split_reverse_branch_step steps')
  in
    merge_select_then1_steps
      (merge_select_steps
        (merge_reverse_steps (split_reverse_branch_steps (assign frags 0 [])) []) []) []
  end

fun report_step_failure label e = (save_failed_prefix_checkpoint (); print_goal_state label; raise e)

fun apply_ftac label ftac =
  with_tactic_timeout label (fn () => (proofManagerLib.ef ftac; ())) ()
  handle e => report_step_failure label e

fun eval_step label program fail_msg =
  with_tactic_timeout label
    (fn () => if smlExecute.quse_string program then () else raise Fail fail_msg) ()
  handle e => report_step_failure label e

fun open_ftac label =
  if String.isPrefix "open_nth_goal " label then
    goalFrag.open_nth_goal (Option.valOf (Int.fromString (String.extract(label, 14, NONE))))
  else if String.isPrefix "open_split_lt " label then
    goalFrag.open_split_lt (Option.valOf (Int.fromString (String.extract(label, 14, NONE))))
  else
    case label of
        "open_paren" => goalFrag.open_paren
      | "open_then1" => goalFrag.open_then1
      | "open_first" => goalFrag.open_first
      | "open_repeat" => goalFrag.open_repeat
      | "open_tacs_to_lt" => goalFrag.open_tacs_to_lt
      | "open_null_ok" => goalFrag.open_null_ok
      | "open_last_goal" => goalFrag.open_last_goal
      | "open_head_goal" => goalFrag.open_head_goal
      | "open_select_lt" => goalFrag.open_select_lt
      | "open_first_lt" => goalFrag.open_first_lt
      | _ => raise Fail ("unknown open frag: " ^ label)

fun mid_ftac label =
  case label of
      "next_first" => goalFrag.next_first
    | "next_tacs_to_lt" => goalFrag.next_tacs_to_lt
    | "next_split_lt" => goalFrag.next_split_lt
    | "next_select_lt" => goalFrag.next_select_lt
    | _ => raise Fail ("unknown mid frag: " ^ label)

fun close_ftac label =
  case label of
      "close_paren" => goalFrag.close_paren
    | "close_first" => goalFrag.close_first
    | "close_repeat" => goalFrag.close_repeat
    | "close_first_lt" => goalFrag.close_first_lt
    | _ => raise Fail ("unknown close frag: " ^ label)

fun step (StepOpen {label, ...}) = apply_ftac label (open_ftac label)
  | step (StepMid {label, ...}) = apply_ftac label (mid_ftac label)
  | step (StepClose {label, ...}) = apply_ftac label (close_ftac label)
  | step (StepExpand {label, ...}) =
      eval_step label
        ("proofManagerLib.ef(goalFrag.expand((" ^ label ^ ")));")
        ("tactic fragment failed: " ^ label)
  | step (StepExpandList {label, ...}) =
      eval_step label
        ("proofManagerLib.ef(goalFrag.expand_list((" ^ label ^ ")));")
        ("list tactic fragment failed: " ^ label)
  | step (StepSelect {label, ...}) = raise Fail ("unmerged select fragment: " ^ label)
  | step (StepSelects {label, ...}) = raise Fail ("unmerged select fragments: " ^ label)

fun inspection_matches wanted name =
  case wanted of
      NONE => false
    | SOME selected => selected = name

fun trace_enabled () =
  !trace_active_ref orelse Option.getOpt(env_bool "HOLBUILD_GOALFRAG_TRACE", false)

fun plan_enabled () =
  !plan_active_ref orelse trace_enabled ()

fun current_goal_count () = length (proofManagerLib.top_goals()) handle _ => ~1

fun trace_line parts =
  if trace_enabled () then TextIO.output(TextIO.stdErr, String.concat parts) else ()

fun display_label label =
  String.translate
    (fn #"\n" => "\\n"
      | #"\t" => "\\t"
      | c => String.str c)
    label

fun trace_goalfrag_plan theorem_name plan =
  if plan_enabled () then
    (TextIO.output(TextIO.stdErr,
       String.concat ["holbuild goalfrag plan theorem=", theorem_name,
                      " steps=", Int.toString (length plan), "\n"]);
     List.app
       (fn (index, step') =>
          TextIO.output(TextIO.stdErr,
            String.concat ["holbuild goalfrag plan step=", Int.toString index,
                           " theorem=", theorem_name,
                           " kind=", step_kind step',
                           " end=", Int.toString (step_end step'),
                           " label=", display_label (step_label step'), "\n"]))
       (ListPair.zip (List.tabulate(length plan, fn i => i), plan)))
  else ()

fun stop_after_plan_if_requested () =
  if !plan_active_ref andalso not (!trace_active_ref) then
    case !plan_only_marker_ref of
        NONE => ()
      | SOME path => (write_text_file path "holbuild-goalfrag-plan-ok\n";
                      OS.Process.exit OS.Process.success)
  else ()

fun trace_goalfrag_before index step' =
  trace_line ["holbuild goalfrag before theorem=", !trace_current_theorem_ref,
              " step=", Int.toString index,
              " kind=", step_kind step',
              " goals=", Int.toString (current_goal_count()),
              " label=", display_label (step_label step'), "\n"]

fun trace_goalfrag_after status elapsed index step' =
  trace_line ["holbuild goalfrag after theorem=", !trace_current_theorem_ref,
              " step=", Int.toString index,
              " kind=", step_kind step',
              " status=", status,
              " elapsed_ms=", fmt_ms elapsed,
              " goals=", Int.toString (current_goal_count()),
              " label=", display_label (step_label step'), "\n"]

fun run_maybe_traced_step index step' =
  if trace_enabled () then
    let
      val _ = trace_goalfrag_before index step'
      val t0 = Time.now()
      val result = (step step'; NONE) handle e => SOME e
      val elapsed = seconds (t0, Time.now())
    in
      case result of
          NONE => trace_goalfrag_after "ok" elapsed index step'
        | SOME e => (trace_goalfrag_after "failed" elapsed index step'; raise e)
    end
  else step step'

fun run_steps_from _ [] = ()
  | run_steps_from index (step' :: rest) =
      (successful_step_count_ref := index;
       run_maybe_traced_step index step';
       successful_step_count_ref := index + 1;
       successful_prefix_end_ref := step_end step';
       run_steps_from (index + 1) rest)

fun drop_steps 0 steps = steps
  | drop_steps _ [] = []
  | drop_steps n (_ :: rest) = drop_steps (n - 1) rest

fun run_steps steps =
  (successful_step_count_ref := 0;
   successful_prefix_end_ref := 0;
   run_steps_from 0 steps)

fun backup_n 0 = ()
  | backup_n n = (proofManagerLib.b(); backup_n (n - 1))

fun drop_all () = (proofManagerLib.drop_all (); ()) handle _ => ()

fun atomic_prove label g tac =
  with_tactic_timeout label (fn () => Tactical.TAC_PROOF(g, tac)) ()
  handle e => (proofManagerLib.set_goal g; report_step_failure label e)

datatype 'a traced_result = TraceOk of 'a | TraceError of exn

fun with_theorem_trace name f =
  let
    val old_active = !trace_active_ref
    val old_plan_active = !plan_active_ref
    val old_name = !trace_current_theorem_ref
    val _ = plan_active_ref := (inspection_matches (!plan_theorem_ref) name orelse !trace_all_ref)
    val _ = trace_active_ref := !trace_all_ref
    val _ = trace_current_theorem_ref := name
    val result = TraceOk (f ()) handle e => TraceError e
    val _ = trace_active_ref := old_active
    val _ = plan_active_ref := old_plan_active
    val _ = trace_current_theorem_ref := old_name
  in
    case result of TraceOk value => value | TraceError e => raise e
  end

fun goalfrag_prove name end_path end_ok checkpoint_depth g tac tactic_text =
  let
    val _ = active_tactic_text_ref := tactic_text
    val _ = proofManagerLib.set_goalfrag g
    val plan = steps tactic_text
    val _ = trace_goalfrag_plan name plan
    val _ = stop_after_plan_if_requested ()
    val _ = run_steps plan
    val th = proofManagerLib.top_thm()
             handle e => (print_goal_state (name ^ " finish"); raise e)
    val _ = save_checkpoint "end_of_proof" false end_path end_ok checkpoint_depth
    val _ = proofManagerLib.drop_all()
  in th end

fun common_prefix_size old_text new_text =
  let
    val old_n = size old_text
    val new_n = size new_text
    val limit = Int.min(old_n, new_n)
    fun loop i =
      if i >= limit then i
      else if String.sub(old_text, i) = String.sub(new_text, i) then loop (i + 1)
      else i
  in
    loop 0
  end

fun step_count_at_prefix common_bytes plan =
  let
    fun loop count [] = count
      | loop count (step' :: rest) =
          if step_end step' <= common_bytes then loop (count + 1) rest else count
  in
    loop 0 plan
  end

fun finish_failed_prefix name old_prefix_text old_step_count tactic_text =
  with_theorem_trace name (fn () =>
    let
      val _ = active_tactic_text_ref := tactic_text
      val plan = steps tactic_text
      val _ = trace_goalfrag_plan name plan
      val _ = stop_after_plan_if_requested ()
      val common_bytes = common_prefix_size old_prefix_text tactic_text
      val skip_count = step_count_at_prefix common_bytes plan
      val backup_count = Int.max(0, old_step_count - skip_count)
      val _ = backup_n backup_count
      val _ = successful_step_count_ref := skip_count
      val _ = successful_prefix_end_ref := common_bytes
      val _ = run_steps_from skip_count (drop_steps skip_count plan)
      val th = proofManagerLib.top_thm()
               handle e => (print_goal_state (name ^ " finish"); raise e)
      val _ = proofManagerLib.drop_all()
    in th end)

fun prove_outer_theorem (g, tac) (_, name, tactic_text, _, _, end_path, end_ok, _, _, has_attrs, checkpoint_depth) =
  let
    val atomic = has_attrs orelse tactic_text = ""
    val _ = proving_with_goalfrag_ref := true
    val th =
      with_theorem_trace name (fn () =>
        if atomic then atomic_prove name g tac
        else goalfrag_prove name end_path end_ok checkpoint_depth g tac tactic_text)
      handle e => (proving_with_goalfrag_ref := false; raise e)
    val _ = proving_with_goalfrag_ref := false
    val _ = theorem_info_ref := NONE
  in
    th
  end

fun goalfrag_prover (g, tac) =
  if !proving_with_goalfrag_ref then
    Tactical.TAC_PROOF(g, tac)
  else
    case !theorem_info_ref of
        NONE => Tactical.TAC_PROOF(g, tac)
      | SOME info =>
          prove_outer_theorem (g, tac) info
          handle e =>
            (proving_with_goalfrag_ref := false;
             theorem_info_ref := NONE;
             context_info_ref := NONE;
             drop_all();
             raise e)

fun install ({checkpoint_enabled, tactic_timeout, timeout_marker, plan_theorem, trace_all, plan_only_marker} : config) =
  (checkpoint_enabled_ref := checkpoint_enabled;
   tactic_timeout_ref := tactic_timeout;
   tactic_timeout_marker_ref := timeout_marker;
   plan_theorem_ref := plan_theorem;
   trace_all_ref := trace_all;
   plan_only_marker_ref := plan_only_marker;
   plan_active_ref := false;
   trace_active_ref := false;
   theorem_info_ref := NONE;
   context_info_ref := NONE;
   proving_with_goalfrag_ref := false;
   Tactical.set_prover goalfrag_prover)

end
