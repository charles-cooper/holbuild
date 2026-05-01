(* Caller must load HOLSourceParser, TacticParse, smlExecute, and smlTimeout
   before using this helper; the generated staged script does that prelude. *)
structure HolbuildGoalfragRuntime =
struct

type config = {checkpoint_enabled : bool,
               tactic_timeout : real option,
               timeout_marker : string option}

val checkpoint_enabled_ref = ref false
val tactic_timeout_ref = ref (NONE : real option)
val tactic_timeout_marker_ref = ref (NONE : string option)
val theorem_info_ref = ref NONE : (string * string * string * string * string * string * string * string * bool * int) option ref
val context_info_ref = ref NONE : (string * string * int) option ref
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

fun delete_file path = OS.FileSys.remove path handle _ => ()

fun delete_checkpoint path =
  (delete_file (path ^ ".ok"); delete_file (path ^ ".meta"); delete_file (path ^ ".prefix"); delete_file path)

fun write_checkpoint_ok path ok_text =
  let val out = TextIO.openOut (path ^ ".ok")
  in TextIO.output(out, ok_text); TextIO.closeOut out end

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
      val _ = delete_checkpoint path
      val _ = if share then PolyML.shareCommonData PolyML.rootFunction else ()
      val t1 = Time.now()
      val _ = PolyML.SaveState.saveChild(path, depth)
      val t2 = Time.now()
      val _ = write_checkpoint_ok path ok_text
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
    | SOME (_, _, _, _, _, _, failed_prefix_path, failed_prefix_ok, _, depth) =>
        if not (!checkpoint_enabled_ref) then ()
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

fun begin_theorem (name, tactic_text, context_path, context_ok,
                   end_path, end_ok, failed_prefix_path, failed_prefix_ok, has_attrs) =
  let val depth = length (PolyML.SaveState.showHierarchy())
  in
    if !checkpoint_enabled_ref then
      (delete_checkpoint context_path; delete_checkpoint end_path; delete_checkpoint failed_prefix_path)
    else ();
    theorem_info_ref := SOME (name, tactic_text, context_path, context_ok,
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

fun print_goal_state label =
  let
    val goals = proofManagerLib.top_goals()
  in
    TextIO.output(TextIO.stdErr,
      String.concat ["\nholbuild goal state at failed fragment: ", label,
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
fun opaque_named body name sp = String.isPrefix name (opaque_text body sp)
fun opaque_is_induction body sp = opaque_named body "Induct_on" sp orelse opaque_named body "Induct" sp
fun opaque_is_case_split body sp = opaque_named body "Cases_on" sp
fun opaque_is_conj_tac body sp = opaque_named body "CONJ_TAC" sp orelse opaque_named body "conj_tac" sp

fun expr_is_conj_tac body e =
  case e of
      TacticParse.Opaque (_, sp) => opaque_is_conj_tac body sp
    | TacticParse.Group (_, _, e) => expr_is_conj_tac body e
    | _ => false

fun expr_can_create_shared_subgoals body e =
  case e of
      TacticParse.Opaque (_, sp) => opaque_is_induction body sp orelse opaque_is_case_split body sp
    | TacticParse.Repeat e => expr_is_conj_tac body e
    | TacticParse.Try e => expr_is_conj_tac body e
    | TacticParse.Group (_, _, e) => expr_can_create_shared_subgoals body e
    | TacticParse.RepairGroup (_, _, e, _) => expr_can_create_shared_subgoals body e
    | _ => false

fun then_requires_atomic body [] = false
  | then_requires_atomic body [_] = false
  | then_requires_atomic body (e :: rest) =
      expr_can_create_shared_subgoals body e orelse
      expr_requires_atomic body e orelse
      then_requires_atomic body rest
and expr_requires_atomic body e =
  case e of
      TacticParse.Then es => then_requires_atomic body es
    | TacticParse.Group (_, _, e) => expr_requires_atomic body e
    | TacticParse.RepairGroup (_, _, e, _) => expr_requires_atomic body e
    | _ => false

fun body_requires_atomic body = expr_requires_atomic body (parse_tactic body) handle _ => false

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
    | TacticParse.LReverse => true
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

fun exprs_contain_branch es = List.exists expr_contains_branch es
and expr_contains_branch e =
  case e of
      TacticParse.Then es => exprs_contain_branch es
    | TacticParse.ThenLT _ => true
    | TacticParse.LThen1 _ => true
    | TacticParse.LTacsToLT _ => true
    | TacticParse.LNullOk _ => true
    | TacticParse.LSelectGoal _ => true
    | TacticParse.LSelectGoals _ => true
    | TacticParse.LSelectThen _ => true
    | TacticParse.LSplit _ => true
    | TacticParse.Group (_, _, e) => expr_contains_branch e
    | TacticParse.RepairGroup (_, _, e, _) => expr_contains_branch e
    | _ => false

fun reverse_branch_expr body (TacticParse.ThenLT (lhs, [rhs as TacticParse.LNullOk (TacticParse.LTacsToLT _)])) =
      expr_contains_reverse body lhs orelse expr_contains_reverse body rhs
  | reverse_branch_expr body (TacticParse.ThenLT (lhs, [rhs as TacticParse.LThen1 _])) =
      expr_contains_reverse body lhs orelse expr_contains_reverse body rhs
  | reverse_branch_expr body (TacticParse.Group (_, _, e)) = reverse_branch_expr body e
  | reverse_branch_expr _ _ = false

fun group_atom_expr body (TacticParse.FAtom (TacticParse.Group (_, _, e))) =
      if expr_contains_branch e orelse reverse_branch_expr body e then NONE
      else if is_composable e then SOME e else NONE
  | group_atom_expr _ _ = NONE

fun reexpand_group_atoms body frags =
  let
    fun reexpand e =
      let val subFrags = TacticParse.linearize (fn x => Option.isSome (TacticParse.topSpan x)) e
      in reexpand_group_atoms body (flatten_frags subFrags) end
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

fun frag_type (TacticParse.FAtom (TacticParse.LSelectGoal _)) = "select"
  | frag_type (TacticParse.FAtom (TacticParse.LSelectGoals _)) = "selects"
  | frag_type (TacticParse.FAtom TacticParse.LReverse) = "expand_list"
  | frag_type (TacticParse.FAtom (TacticParse.LTacsToLT _)) = "expand_list"
  | frag_type (TacticParse.FAtom _) = "expand"
  | frag_type (TacticParse.FFOpen _) = "open"
  | frag_type (TacticParse.FFMid _) = "mid"
  | frag_type (TacticParse.FFClose _) = "close"
  | frag_type _ = ""

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
          | TacticParse.Subgoal _ => if is_term_quote raw then "sg " ^ raw else raw
          | _ => raw
      end
  | frag_text _ (TacticParse.FFOpen opn) = open_name opn
  | frag_text _ (TacticParse.FFMid mid) = mid_name mid
  | frag_text _ (TacticParse.FFClose cls) = close_name cls
  | frag_text _ _ = ""

fun is_select "select" = true
  | is_select "selects" = true
  | is_select _ = false

fun subgoal_term subgoalText =
  if String.isPrefix "sg " subgoalText then SOME (String.extract(subgoalText, 3, NONE)) else NONE

fun join_tactic [] = "ALL_TAC"
  | join_tactic [t] = t
  | join_tactic ts = String.concatWith " \\\\ " ts

fun collect_then1_steps steps =
  let
    fun go [] _ _ = NONE
      | go ((_, "close", _) :: rest) acc last = SOME (join_tactic (rev acc), last, rest)
      | go ((endp, "expand", text) :: rest) acc _ = go rest (text :: acc) endp
      | go _ _ _ = NONE
  in go steps [] 0 end

fun merge_subgoal_then1 connective term bodySteps acc =
  case collect_then1_steps bodySteps of
      SOME (tacText, tacEnd, rest) =>
        SOME (merge_by_steps rest ((tacEnd, "expand", term ^ connective ^ "(" ^ tacText ^ ")") :: acc))
    | NONE => NONE
and merge_by_steps [] acc = rev acc
  | merge_by_steps ((subEnd, "expand", subgoalText) ::
                    (reverseStep as (_, "expand_list", "Tactical.REVERSE_LT")) ::
                    (openStep as (_, "open", "open_then1")) :: rest) acc =
      (case subgoal_term subgoalText of
           SOME term =>
             (case merge_subgoal_then1 " suffices_by " term rest acc of
                  SOME steps => steps
                | NONE => merge_by_steps (reverseStep :: openStep :: rest) ((subEnd, "expand", subgoalText) :: acc))
         | NONE => merge_by_steps (reverseStep :: openStep :: rest) ((subEnd, "expand", subgoalText) :: acc))
  | merge_by_steps ((subEnd, "expand", subgoalText) ::
                    (openStep as (_, "open", "open_then1")) :: rest) acc =
      (case subgoal_term subgoalText of
           SOME term =>
             (case merge_subgoal_then1 " by " term rest acc of
                  SOME steps => steps
                | NONE => merge_by_steps (openStep :: rest) ((subEnd, "expand", subgoalText) :: acc))
         | NONE => merge_by_steps (openStep :: rest) ((subEnd, "expand", subgoalText) :: acc))
  | merge_by_steps (step :: rest) acc = merge_by_steps rest (step :: acc)

fun merge_reverse_steps [] acc = rev acc
  | merge_reverse_steps ((_, "expand_list", "Tactical.REVERSE_LT") :: rest)
                        ((tacEnd, "expand", tacText) :: acc) =
      merge_reverse_steps rest ((tacEnd, "expand", "Tactical.REVERSE (" ^ tacText ^ ")") :: acc)
  | merge_reverse_steps (step :: rest) acc = merge_reverse_steps rest (step :: acc)

fun join_then_tactic [] = "ALL_TAC"
  | join_then_tactic [t] = t
  | join_then_tactic ts = String.concatWith " >> " ts

fun is_branch_open "open_then1" = true
  | is_branch_open "open_first" = true
  | is_branch_open _ = false

fun collect_branch_body steps =
  let
    fun go [] _ _ = NONE
      | go ((_, "close", closeText) :: rest) acc last = SOME (join_then_tactic (rev acc), last, closeText, rest)
      | go ((endp, "expand", text) :: rest) acc _ = go rest (text :: acc) endp
      | go _ _ _ = NONE
  in go steps [] 0 end

fun merge_branch_body_steps [] acc = rev acc
  | merge_branch_body_steps ((openStep as (_, "open", openText)) :: rest) acc =
      if is_branch_open openText then
        (case collect_branch_body rest of
             SOME (bodyText, bodyEnd, closeText, after) =>
               if body_requires_atomic bodyText then
                 merge_branch_body_steps after ((bodyEnd, "close", closeText) ::
                                                (bodyEnd, "expand", bodyText) :: openStep :: acc)
               else merge_branch_body_steps rest (openStep :: acc)
           | NONE => merge_branch_body_steps rest (openStep :: acc))
      else merge_branch_body_steps rest (openStep :: acc)
  | merge_branch_body_steps (step :: rest) acc = merge_branch_body_steps rest (step :: acc)

fun merge_select_steps [] acc = rev acc
  | merge_select_steps ((endP, kind, patText) :: rest) acc =
      if is_select kind then
        let
          fun collect [] sels = (rev sels, [])
            | collect ((ep, k, t) :: rest') sels =
                if is_select k then collect rest' (t :: sels) else (rev sels, (ep, k, t) :: rest')
          val (sels, afterSels) = collect rest [patText]
          fun prefix [] = ""
            | prefix [p] = "Q.SELECT_GOAL_LT " ^ p
            | prefix (p::ps) =
                "Q.SELECT_GOAL_LT " ^ p ^ " >>~ Q.SELECT_GOALS_LT " ^
                String.concatWith " >>~ Q.SELECT_GOALS_LT " ps
          val selectPrefix = prefix sels
          fun consume ((_, "open", "open_then1") :: (tacEnd, "expand", tacText) :: (_, "close", _) :: rest') =
                SOME (selectPrefix ^ " >- " ^ tacText, tacEnd, rest')
            | consume ((_, "open", "open_first") :: (tacEnd, "expand", tacText) :: (_, "close", _) :: rest') =
                SOME (selectPrefix ^ " >- " ^ tacText, tacEnd, rest')
            | consume _ = NONE
        in
          case consume afterSels of
              SOME (text, tacEnd, rest') => merge_select_steps rest' ((tacEnd, "expand_list", text) :: acc)
            | NONE => merge_select_steps afterSels acc
        end
      else merge_select_steps rest ((endP, kind, patText) :: acc)

fun steps body =
  let
    val tree = parse_tactic body
    fun isAtom e = Option.isSome (TacticParse.topSpan e)
    val frags = reexpand_group_atoms body (flatten_frags (TacticParse.linearize isAtom tree))
    fun assign [] _ acc = rev acc
      | assign (f::rest) last acc =
          let
            val typ = frag_type f
            val txt = frag_text body f
            val (endPos, last') =
              case f of
                  TacticParse.FAtom _ => let val e = frag_end f in (e, e) end
                | _ => (last, last)
          in
            if String.size txt > 0 then assign rest last' ((endPos, typ, txt) :: acc)
            else assign rest last acc
          end
  in
    merge_select_steps
      (merge_branch_body_steps
        (merge_reverse_steps (merge_by_steps (assign frags 0 []) []) []) []) []
  end

fun report_step_failure label e = (save_failed_prefix_checkpoint (); print_goal_state label; raise e)

fun apply_ftac label ftac =
  with_tactic_timeout label (fn () => (proofManagerLib.ef ftac; ())) ()
  handle e => report_step_failure label e

fun eval_step label program fail_msg =
  with_tactic_timeout label
    (fn () => if smlExecute.quse_string program then () else raise Fail fail_msg) ()
  handle e => report_step_failure label e

fun step ("open", text) =
      let
        val ftac =
          if String.isPrefix "open_nth_goal " text then
            goalFrag.open_nth_goal (Option.valOf (Int.fromString (String.extract(text, 14, NONE))))
          else if String.isPrefix "open_split_lt " text then
            goalFrag.open_split_lt (Option.valOf (Int.fromString (String.extract(text, 14, NONE))))
          else
            case text of
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
              | _ => raise Fail ("unknown open frag: " ^ text)
      in apply_ftac text ftac end
  | step ("mid", text) =
      let
        val ftac =
          case text of
              "next_first" => goalFrag.next_first
            | "next_tacs_to_lt" => goalFrag.next_tacs_to_lt
            | "next_split_lt" => goalFrag.next_split_lt
            | "next_select_lt" => goalFrag.next_select_lt
            | _ => raise Fail ("unknown mid frag: " ^ text)
      in apply_ftac text ftac end
  | step ("close", text) =
      let
        val ftac =
          case text of
              "close_paren" => goalFrag.close_paren
            | "close_first" => goalFrag.close_first
            | "close_repeat" => goalFrag.close_repeat
            | "close_first_lt" => goalFrag.close_first_lt
            | _ => raise Fail ("unknown close frag: " ^ text)
      in apply_ftac text ftac end
  | step ("expand", text) =
      eval_step text
        ("proofManagerLib.ef(goalFrag.expand((" ^ text ^ ")));")
        ("tactic fragment failed: " ^ text)
  | step ("expand_list", text) =
      eval_step text
        ("proofManagerLib.ef(goalFrag.expand_list((" ^ text ^ ")));")
        ("list tactic fragment failed: " ^ text)
  | step (typ, _) = raise Fail ("unknown fragment type: " ^ typ)

fun run_steps_from _ [] = ()
  | run_steps_from index ((end_pos, typ, text) :: rest) =
      (successful_step_count_ref := index;
       step (typ, text);
       successful_step_count_ref := index + 1;
       successful_prefix_end_ref := end_pos;
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

fun goalfrag_prove name end_path end_ok checkpoint_depth g tac tactic_text =
  let
    val _ = active_tactic_text_ref := tactic_text
    val _ = proofManagerLib.set_goalfrag g
    val _ = run_steps (steps tactic_text)
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
      | loop count ((end_pos, _, _) :: rest) =
          if end_pos <= common_bytes then loop (count + 1) rest else count
  in
    loop 0 plan
  end

fun finish_failed_prefix name old_prefix_text old_step_count tactic_text =
  let
    val _ = active_tactic_text_ref := tactic_text
    val plan = steps tactic_text
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
  in th end

fun goalfrag_prover (g, tac) =
  case !theorem_info_ref of
      NONE => Tactical.TAC_PROOF(g, tac)
    | SOME (name, tactic_text, _, _, end_path, end_ok, _, _, has_attrs, checkpoint_depth) =>
        let
          val atomic = has_attrs orelse tactic_text = ""
          val th =
            if atomic then atomic_prove name g tac
            else goalfrag_prove name end_path end_ok checkpoint_depth g tac tactic_text
          val _ = theorem_info_ref := NONE
        in
          th
        end
        handle e =>
          (theorem_info_ref := NONE;
           context_info_ref := NONE;
           drop_all();
           raise e)

fun install ({checkpoint_enabled, tactic_timeout, timeout_marker} : config) =
  (checkpoint_enabled_ref := checkpoint_enabled;
   tactic_timeout_ref := tactic_timeout;
   tactic_timeout_marker_ref := timeout_marker;
   theorem_info_ref := NONE;
   context_info_ref := NONE;
   Tactical.set_prover goalfrag_prover)

end
