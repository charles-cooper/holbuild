structure HolbuildGoalfragPlan =
struct

datatype step =
    StepOpen of {start_pos : int, end_pos : int, label : string}
  | StepMid of {start_pos : int, end_pos : int, label : string}
  | StepClose of {start_pos : int, end_pos : int, label : string}
  | StepExpand of {start_pos : int, end_pos : int, label : string}
  | StepPlain of {start_pos : int, end_pos : int, label : string}
  | StepExpandList of {start_pos : int, end_pos : int, label : string}
  | StepSelect of {start_pos : int, end_pos : int, label : string}
  | StepSelects of {start_pos : int, end_pos : int, label : string}

fun step_start (StepOpen {start_pos, ...}) = start_pos
  | step_start (StepMid {start_pos, ...}) = start_pos
  | step_start (StepClose {start_pos, ...}) = start_pos
  | step_start (StepExpand {start_pos, ...}) = start_pos
  | step_start (StepPlain {start_pos, ...}) = start_pos
  | step_start (StepExpandList {start_pos, ...}) = start_pos
  | step_start (StepSelect {start_pos, ...}) = start_pos
  | step_start (StepSelects {start_pos, ...}) = start_pos

fun step_end (StepOpen {end_pos, ...}) = end_pos
  | step_end (StepMid {end_pos, ...}) = end_pos
  | step_end (StepClose {end_pos, ...}) = end_pos
  | step_end (StepExpand {end_pos, ...}) = end_pos
  | step_end (StepPlain {end_pos, ...}) = end_pos
  | step_end (StepExpandList {end_pos, ...}) = end_pos
  | step_end (StepSelect {end_pos, ...}) = end_pos
  | step_end (StepSelects {end_pos, ...}) = end_pos

fun step_label (StepOpen {label, ...}) = label
  | step_label (StepMid {label, ...}) = label
  | step_label (StepClose {label, ...}) = label
  | step_label (StepExpand {label, ...}) = label
  | step_label (StepPlain {label, ...}) = label
  | step_label (StepExpandList {label, ...}) = label
  | step_label (StepSelect {label, ...}) = label
  | step_label (StepSelects {label, ...}) = label

fun step_kind (StepOpen _) = "open"
  | step_kind (StepMid _) = "mid"
  | step_kind (StepClose _) = "close"
  | step_kind (StepExpand _) = "expand"
  | step_kind (StepPlain _) = "plain"
  | step_kind (StepExpandList _) = "expand_list"
  | step_kind (StepSelect _) = "select"
  | step_kind (StepSelects _) = "selects"

fun ignore_parse_error _ _ _ = ()

fun parse_tactic s =
  let
    val fed = ref false
    fun read _ = if !fed then "" else (fed := true; s)
    val result =
      HOLSourceParser.parseSML "<holbuild tactic>" read
        ignore_parse_error
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

fun span_to_last start [] = SOME start
  | span_to_last (start, _) args =
      (case TacticParse.topSpan (List.last args) of
           SOME (_, stop) => SOME (start, stop)
         | NONE => NONE)

fun alt_span (TacticParse.Subgoal (s, e)) = SOME (s, e)
  | alt_span (TacticParse.MapEvery (f, args)) = span_to_last f args
  | alt_span (TacticParse.MapFirst (f, args)) = span_to_last f args
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

fun expr_contains_try e =
  case e of
      TacticParse.Then es => List.exists expr_contains_try es
    | TacticParse.ThenLT (e, es) => expr_contains_try e orelse List.exists expr_contains_try es
    | TacticParse.First es => List.exists expr_contains_try es
    | TacticParse.Try _ => true
    | TacticParse.Group (_, _, e) => expr_contains_try e
    | TacticParse.RepairGroup (_, _, e, _) => expr_contains_try e
    | TacticParse.LThen (e, es) => expr_contains_try e orelse List.exists expr_contains_try es
    | TacticParse.LThenLT es => List.exists expr_contains_try es
    | TacticParse.LTry _ => true
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
      if expr_contains_tacs_to_lt e orelse expr_contains_try e orelse reverse_branch_expr body e then NONE
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

fun is_lthen1_branch e =
  case e of
      TacticParse.LThen1 _ => true
    | TacticParse.Group (_, _, x) => is_lthen1_branch x
    | TacticParse.RepairGroup (_, _, x, _) => is_lthen1_branch x
    | _ => false

fun then1_chain_count e =
  case e of
      TacticParse.ThenLT (lhs, lts) =>
        (if List.exists is_lthen1_branch lts then 1 else 0) + then1_chain_count lhs
    | TacticParse.Group (_, _, x) => then1_chain_count x
    | TacticParse.RepairGroup (_, _, x, _) => then1_chain_count x
    | _ => 0

fun chained_then1_expr e = then1_chain_count e >= 3

fun expr_contains_impl_tac body e =
  case TacticParse.topSpan e of
      SOME sp => String.isSubstring "impl_tac" (span_text body sp)
    | NONE =>
        (case e of
             TacticParse.Then es => List.exists (expr_contains_impl_tac body) es
           | TacticParse.ThenLT (lhs, es) => expr_contains_impl_tac body lhs orelse List.exists (expr_contains_impl_tac body) es
           | TacticParse.Group (_, _, x) => expr_contains_impl_tac body x
           | TacticParse.RepairGroup (_, _, x, _) => expr_contains_impl_tac body x
           | TacticParse.LThen1 x => expr_contains_impl_tac body x
           | TacticParse.LNullOk x => expr_contains_impl_tac body x
           | _ => false)

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

fun trim_space text =
  let
    val n = size text
    fun left i = if i >= n orelse not (Char.isSpace (String.sub(text, i))) then i else left (i + 1)
    fun right i = if i < 0 orelse not (Char.isSpace (String.sub(text, i))) then i else right (i - 1)
    val l = left 0
    val r = right (n - 1)
  in if r < l then "" else String.substring(text, l, r - l + 1) end

fun open_name body TacticParse.FOpen = "open_paren"
  | open_name body TacticParse.FOpenThen1 = "open_then1"
  | open_name body TacticParse.FOpenFirst = "open_first"
  | open_name body TacticParse.FOpenRepeat = "open_repeat"
  | open_name body TacticParse.FOpenTacsToLT = "open_tacs_to_lt"
  | open_name body TacticParse.FOpenNullOk = "open_null_ok"
  | open_name body (TacticParse.FOpenNthGoal sp) = "open_nth_goal " ^ trim_space (span_text body sp)
  | open_name body TacticParse.FOpenLastGoal = "open_last_goal"
  | open_name body TacticParse.FOpenHeadGoal = "open_head_goal"
  | open_name body (TacticParse.FOpenSplit sp) = "open_split_lt " ^ trim_space (span_text body sp)
  | open_name body TacticParse.FOpenSelect = "open_select_lt"
  | open_name body TacticParse.FOpenFirstLT = "open_first_lt"

fun mid_name TacticParse.FNextFirst = "next_first"
  | mid_name TacticParse.FNextTacsToLT = "next_tacs_to_lt"
  | mid_name TacticParse.FNextSplit = "next_split_lt"
  | mid_name TacticParse.FNextSelect = "next_select_lt"

fun close_name TacticParse.FClose = "close_paren"
  | close_name TacticParse.FCloseFirst = "close_first"
  | close_name TacticParse.FCloseRepeat = "close_repeat"
  | close_name TacticParse.FCloseFirstLT = "close_first_lt"

fun substring s (a, b) = String.substring(s, a, b - a)

fun raw_frag_text body a =
  case (TacticParse.topSpan a, alt_span a) of
      (SOME sp, _) => substring body sp
    | (NONE, SOME sp) => substring body sp
    | _ => ""

fun expr_text body e = raw_frag_text body e

fun list_expr_text body args =
  "[" ^ String.concatWith ", " (map (expr_text body) args) ^ "]"

fun is_term_quote raw =
  String.isPrefix "`" raw orelse
  String.isPrefix "\226\128\152" raw orelse
  String.isPrefix "\226\128\156" raw

fun frag_text body (TacticParse.FAtom a) =
      let val raw = raw_frag_text body a
      in
        case a of
            TacticParse.Then [] => "ALL_TAC"
          | TacticParse.First [] => "NO_TAC"
          | TacticParse.LThenLT [] => "ALL_LT"
          | TacticParse.LFirst [] => "NO_LT"
          | TacticParse.LReverse => "Tactical.REVERSE_LT"
          | TacticParse.LTacsToLT _ => if String.size raw = 0 then raw else "Tactical.TACS_TO_LT (" ^ raw ^ ")"
          | TacticParse.MapEvery (f, args) => "MAP_EVERY " ^ substring body f ^ " " ^ list_expr_text body args
          | TacticParse.MapFirst (f, args) => "MAP_FIRST " ^ substring body f ^ " " ^ list_expr_text body args
          | TacticParse.Rename _ => "Q.RENAME_TAC " ^ raw
          | TacticParse.Group (_, _, TacticParse.Rename _) => "Q.RENAME_TAC " ^ raw
          | TacticParse.Subgoal _ => if is_term_quote raw then "sg " ^ raw else raw
          | _ => raw
      end
  | frag_text body (TacticParse.FFOpen opn) = open_name body opn
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
      | go (StepExpand {end_pos, label, ...} :: rest) acc _ = go rest (label :: acc) end_pos
      | go _ _ _ = NONE
  in go steps [] 0 end

fun merge_reverse_steps [] acc = rev acc
  | merge_reverse_steps (StepExpandList {label = "Tactical.REVERSE_LT", end_pos = reverse_end, ...} :: rest)
                        (StepExpand {start_pos, label, ...} :: acc) =
      merge_reverse_steps rest (StepExpand {start_pos = start_pos, end_pos = reverse_end, label = "Tactical.REVERSE (" ^ label ^ ")"} :: acc)
  | merge_reverse_steps (step :: rest) acc = merge_reverse_steps rest (step :: acc)

fun drop_prefix prefix text =
  if String.isPrefix prefix text then SOME (String.extract(text, size prefix, NONE)) else NONE

fun rename_pattern label =
  case drop_prefix "Q.RENAME_TAC " label of
      SOME pattern => pattern
    | NONE => label

fun merge_select_then1_steps [] acc = rev acc
  | merge_select_then1_steps ((select_open as StepOpen {label = "open_select_lt", ...}) ::
                              (pattern_step as StepExpand {label = pattern, ...}) ::
                              (next_step as StepMid {label = "next_select_lt", ...}) ::
                              (body_open as StepOpen {label = "open_paren", ...}) :: rest) acc =
      (case collect_then1_steps rest of
           SOME (tacText, tacEnd, StepClose _ :: rest') =>
             merge_select_then1_steps rest'
               (StepExpandList {start_pos = step_start select_open, end_pos = tacEnd,
                                label = "Q.SELECT_GOALS_LT_THEN1 " ^ rename_pattern pattern ^ " (" ^ tacText ^ ")"} :: acc)
         | _ => merge_select_then1_steps (pattern_step :: next_step :: body_open :: rest) (select_open :: acc))
  | merge_select_then1_steps (step :: rest) acc = merge_select_then1_steps rest (step :: acc)

fun merge_select_steps [] acc = rev acc
  | merge_select_steps (selectStep :: rest) acc =
      if is_select_step selectStep then
        let
          fun collect [] sels = (rev sels, [])
            | collect (step :: rest') sels =
                if is_select_step step then collect rest' (step :: sels) else (rev sels, step :: rest')
          val (sels, afterSels) = collect rest [selectStep]
          val selectPrefix = String.concatWith " >>~ " (map select_prefix_step sels)
          val selectStart = step_start selectStep
          val selectEnd = step_end (List.last sels)
          fun consume (StepOpen {label = "open_then1", ...} :: StepExpand {end_pos, label, ...} :: StepClose _ :: rest') =
                SOME (selectPrefix ^ " >- " ^ label, end_pos, rest')
            | consume (StepOpen {label = "open_first", ...} :: StepExpand {end_pos, label, ...} :: StepClose _ :: rest') =
                SOME (selectPrefix ^ " >- " ^ label, end_pos, rest')
            | consume _ = NONE
        in
          case consume afterSels of
              SOME (text, tacEnd, rest') => merge_select_steps rest' (StepExpandList {start_pos = selectStart, end_pos = tacEnd, label = text} :: acc)
            | NONE => merge_select_steps afterSels (StepExpandList {start_pos = selectStart, end_pos = selectEnd, label = selectPrefix} :: acc)
        end
      else merge_select_steps rest (selectStep :: acc)

fun step_of_frag end_pos label (TacticParse.FAtom (TacticParse.LSelectGoal _)) =
      SOME (StepSelect {start_pos = end_pos, end_pos = end_pos, label = label})
  | step_of_frag end_pos label (TacticParse.FAtom (TacticParse.LSelectGoals _)) =
      SOME (StepSelects {start_pos = end_pos, end_pos = end_pos, label = label})
  | step_of_frag end_pos label (TacticParse.FAtom TacticParse.LReverse) =
      SOME (StepExpandList {start_pos = end_pos, end_pos = end_pos, label = label})
  | step_of_frag end_pos label (TacticParse.FAtom (TacticParse.LTacsToLT _)) =
      SOME (StepExpandList {start_pos = end_pos, end_pos = end_pos, label = label})
  | step_of_frag end_pos label (TacticParse.FAtom a) =
      if TacticParse.isTac a then SOME (StepExpand {start_pos = end_pos, end_pos = end_pos, label = label})
      else SOME (StepExpandList {start_pos = end_pos, end_pos = end_pos, label = label})
  | step_of_frag end_pos label (TacticParse.FFOpen _) =
      SOME (StepOpen {start_pos = end_pos, end_pos = end_pos, label = label})
  | step_of_frag end_pos label (TacticParse.FFMid _) =
      SOME (StepMid {start_pos = end_pos, end_pos = end_pos, label = label})
  | step_of_frag end_pos label (TacticParse.FFClose _) =
      SOME (StepClose {start_pos = end_pos, end_pos = end_pos, label = label})
  | step_of_frag _ _ _ = NONE

fun steps_from_tree body tree =
  let
    fun full_span () = (0, size body)
    fun span_of default e =
      case TacticParse.topSpan e of
          SOME sp => sp
        | NONE =>
            (case e of
                 TacticParse.MapEvery (_, []) => default
               | TacticParse.MapFirst (_, []) => default
               | TacticParse.LNullOk x => span_of default x
               | _ => Option.getOpt(alt_span e, default))
    fun text_of sp = trim_space (span_text body sp)
    fun text_or sp fallback =
      let val raw = text_of sp
      in if String.size raw = 0 then fallback else raw end
    fun term_quote_text raw =
      if is_term_quote raw then "sg " ^ raw else raw
    fun tactic_label default fallback e =
      case e of
          TacticParse.MapEvery _ =>
            let val raw = text_of default
            in if String.size raw = 0 then frag_text body (TacticParse.FAtom e) else raw end
        | TacticParse.MapFirst _ =>
            let val raw = text_of default
            in if String.size raw = 0 then frag_text body (TacticParse.FAtom e) else raw end
        | _ => text_or (span_of default e) fallback
    fun list_label default fallback e =
      case e of
          TacticParse.LReverse => "Tactical.REVERSE_LT"
        | TacticParse.LSelectGoal p => "Q.SELECT_GOAL_LT " ^ text_or p "[]"
        | TacticParse.LSelectGoals p => "Q.SELECT_GOALS_LT " ^ text_or p "[]"
        | TacticParse.LSelectThen (TacticParse.Group (_, _, TacticParse.Rename p), rhs) =>
            "Q.SELECT_GOALS_LT_THEN1 " ^ text_or p "[]" ^ " (" ^ tactic_label (span_of default rhs) "ALL_TAC" rhs ^ ")"
        | TacticParse.LTacsToLT (TacticParse.List (p, _)) =>
            "Tactical.TACS_TO_LT (" ^ text_or p "[]" ^ ")"
        | TacticParse.LTacsToLT arg =>
            "Tactical.TACS_TO_LT (" ^ tactic_label (span_of default arg) "[]" arg ^ ")"
        | TacticParse.LNullOk lt =>
            "Tactical.NULL_OK_LT (" ^ list_label (span_of default lt) "ALL_LT" lt ^ ")"
        | TacticParse.LThenLT [] => text_or (span_of default e) "ALL_LT"
        | TacticParse.LFirst [] => text_or (span_of default e) "NO_LT"
        | _ => text_or (span_of default e) fallback
    fun atomic_tac default fallback e =
      let val sp = span_of default e
      in [StepExpand {start_pos = #1 sp, end_pos = #2 sp, label = tactic_label default fallback e}] end
    fun suffices_by_expr e =
      case e of
          TacticParse.ThenLT (TacticParse.Group (_, _, TacticParse.ThenLT (TacticParse.Subgoal _, [TacticParse.LReverse])), [TacticParse.LThen1 _]) => true
        | TacticParse.ThenLT (TacticParse.ThenLT (TacticParse.Subgoal _, [TacticParse.LReverse]), [TacticParse.LThen1 _]) => true
        | _ => false
    fun thenl_lt (TacticParse.LNullOk (TacticParse.LTacsToLT _)) = true
      | thenl_lt (TacticParse.Group (_, _, x)) = thenl_lt x
      | thenl_lt _ = false
    fun reverse_thenl_expr (TacticParse.ThenLT (lhs, lts)) = expr_contains_reverse body lhs andalso List.exists thenl_lt lts
      | reverse_thenl_expr _ = false
    fun atomic_list default fallback e =
      let val sp = span_of default e
      in [StepExpandList {start_pos = #1 sp, end_pos = #2 sp, label = list_label default fallback e}] end
    fun close_at sp label = StepClose {start_pos = #1 sp, end_pos = #2 sp, label = label}
    (* Tactic-level combinators run once per input goal.  When the current
       GoalFrag state has multiple goals, wrap decomposed list-tactic structure
       in open_paren/close_paren so THEN1/FIRST choices cannot leak across
       sibling input goals. *)
    fun scoped_per_input_goal sp steps =
      StepOpen {start_pos = #1 sp, end_pos = #2 sp, label = "open_paren"} ::
      steps @ [close_at sp "close_paren"]
    fun interleave _ [] = []
      | interleave _ [x] = x
      | interleave mid (x :: xs) = x @ [mid] @ interleave mid xs
    fun plan_tac default e =
      case e of
          TacticParse.Then [] => atomic_tac default "ALL_TAC" e
        | TacticParse.Then es => List.concat (map (fn x => plan_tac (span_of default x) x) es)
        | TacticParse.ThenLT (lhs, lts) =>
            if reverse_thenl_expr e then atomic_tac default "ALL_TAC" e
            else
              let
                val sp = span_of default e
                val lhs_sp = span_of sp lhs
                val body =
                  plan_tac lhs_sp lhs @
                  List.concat (map (fn x => plan_lt (span_of sp x) x) lts)
              in scoped_per_input_goal sp body end
        | TacticParse.Subgoal _ =>
            let val sp = span_of default e
            in [StepExpand {start_pos = #1 sp, end_pos = #2 sp, label = term_quote_text (text_or sp "``" )}] end
        | TacticParse.First [] => atomic_tac default "NO_TAC" e
        | TacticParse.First es =>
            let
              val sp = span_of default e
              val arms = map (fn x => plan_tac (span_of sp x) x) es
              val body =
                [StepOpen {start_pos = #1 sp, end_pos = #2 sp, label = "open_first"}] @
                interleave (StepMid {start_pos = #1 sp, end_pos = #2 sp, label = "next_first"}) arms @
                [close_at sp "close_first"]
            in scoped_per_input_goal sp body end
        | TacticParse.Try _ => atomic_tac default "ALL_TAC" e
        (* goalFrag.close_repeat is not a faithful REPEAT tactic boundary for
           all real tactics (e.g. CASE_TAC validations), so keep REPEAT/rpt
           atomic until a direct executable encoding is proven safe. *)
        | TacticParse.Repeat _ => atomic_tac default "ALL_TAC" e
        | TacticParse.MapEvery _ => atomic_tac default "ALL_TAC" e
        | TacticParse.MapFirst _ => atomic_tac default "NO_TAC" e
        | TacticParse.Rename _ => atomic_tac default "ALL_TAC" e
        | TacticParse.Opaque _ => atomic_tac default "ALL_TAC" e
        | TacticParse.Group (_, sp, x) => if suffices_by_expr x then atomic_tac sp "ALL_TAC" e else plan_tac sp x
        | TacticParse.RepairEmpty (true, _, s) => [StepExpand {start_pos = #1 default, end_pos = #2 default, label = s}]
        | TacticParse.RepairGroup (sp, _, x, _) => if suffices_by_expr x then atomic_tac sp "ALL_TAC" e else plan_tac sp x
        | _ => atomic_tac default "ALL_TAC" e
    and plan_lt default e =
      case e of
          TacticParse.LThenLT [] => atomic_list default "ALL_LT" e
        | TacticParse.LThenLT es => List.concat (map (fn x => plan_lt (span_of default x) x) es)
        | TacticParse.LThen (lt, tacs) =>
            plan_lt (span_of default lt) lt @
            List.concat (map (fn x => plan_tac (span_of default x) x) tacs)
        | TacticParse.LThen1 x =>
            let val sp = span_of default x
            in [StepOpen {start_pos = #1 sp, end_pos = #2 sp, label = "open_then1"}] @
               plan_tac sp x @ [close_at sp "close_paren"]
            end
        | TacticParse.LAllGoals x => plan_tac (span_of default x) x
        | TacticParse.LReverse => atomic_list default "Tactical.REVERSE_LT" e
        | TacticParse.LSelectGoal _ => atomic_list default "Q.SELECT_GOAL_LT []" e
        | TacticParse.LSelectGoals _ => atomic_list default "Q.SELECT_GOALS_LT []" e
        | TacticParse.Group (_, sp, x) => plan_lt sp x
        | TacticParse.RepairEmpty (false, _, s) => [StepExpandList {start_pos = #1 default, end_pos = #2 default, label = s}]
        | TacticParse.RepairGroup (sp, _, x, _) => plan_lt sp x
        | _ => atomic_list default "ALL_LT" e
  in
    plan_tac (full_span ()) tree
  end

fun escape_inline label =
  String.translate
    (fn #"\n" => "\\n"
      | #"\t" => "\\t"
      | c => String.str c)
    label

fun pad2 n = if n < 10 then "0" ^ Int.toString n else Int.toString n

fun display_kind (StepExpand _) = "tactic"
  | display_kind (StepPlain _) = "plain_tactic"
  | display_kind (StepExpandList _) = "list_tac"
  | display_kind (StepOpen _) = "open"
  | display_kind (StepMid _) = "next"
  | display_kind (StepClose _) = "close"
  | display_kind (StepSelect _) = "select"
  | display_kind (StepSelects _) = "selects"

fun drop_prefix prefix text =
  if String.isPrefix prefix text then SOME (String.extract(text, size prefix, NONE)) else NONE

fun rename_pattern label =
  case drop_prefix "Q.RENAME_TAC " label of
      SOME pattern => pattern
    | NONE => label

val body_margin = "  "

fun line depth index prefix text =
  body_margin ^ pad2 index ^ " " ^ String.concat (List.tabulate(depth, fn _ => "  ")) ^ prefix ^ text ^ "\n"

fun indent depth = String.concat (List.tabulate(depth, fn _ => "  "))

fun block_line depth index prefix text =
  case String.fields (fn c => c = #"\n") text of
      [] => line depth index prefix ""
    | [single] => line depth index prefix single
    | first :: rest =>
        line depth index prefix first ^
        String.concat (map (fn part => body_margin ^ "   " ^ indent depth ^ part ^ "\n") rest)

fun detail_block depth prefix text =
  case String.fields (fn c => c = #"\n") text of
      [] => body_margin ^ "   " ^ indent depth ^ prefix ^ "\n"
    | [single] => body_margin ^ "   " ^ indent depth ^ prefix ^ single ^ "\n"
    | first :: rest =>
        body_margin ^ "   " ^ indent depth ^ prefix ^ first ^ "\n" ^
        String.concat (map (fn part => body_margin ^ "   " ^ indent depth ^ "   " ^ part ^ "\n") rest)

fun find_sub needle text =
  let
    val n = size text
    val m = size needle
    fun loop i =
      if i + m > n then NONE
      else if String.substring(text, i, m) = needle then SOME i
      else loop (i + 1)
  in
    loop 0
  end

fun strip_trailing_paren text =
  if size text > 0 andalso String.sub(text, size text - 1) = #")" then
    String.substring(text, 0, size text - 1)
  else text

fun select_then1_parts label =
  case drop_prefix "Q.SELECT_GOALS_LT_THEN1 " label of
      NONE => NONE
    | SOME rest =>
        case find_sub "] (" rest of
            NONE => NONE
          | SOME split =>
              let
                val pattern = String.substring(rest, 0, split + 1)
                val body = strip_trailing_paren (String.extract(rest, split + 3, NONE))
              in
                SOME (rename_pattern pattern, body)
              end

fun depth_before (StepClose _) depth = Int.max(0, depth - 1)
  | depth_before _ depth = depth

fun format_expand index depth prefix label =
  block_line depth index prefix label

fun format_expand_list index depth prefix label =
  case select_then1_parts label of
      SOME (pattern, body) =>
        line depth index (prefix ^ "list_tac ") ("Q.SELECT_GOALS_LT_THEN1 " ^ pattern ^ " (") ^
        detail_block (depth + 1) "" body ^
        body_margin ^ "   " ^ indent depth ^ ")\n"
    | NONE => block_line depth index (prefix ^ "list_tac ") label

fun display_open_label label =
  if String.isPrefix "open_nth_goal " label then "NTH_GOAL " ^ String.extract(label, 14, NONE)
  else if String.isPrefix "open_split_lt " label then "split_lt " ^ String.extract(label, 14, NONE)
  else
    case label of
        "open_then1" => ">-"
      | "open_first" => "FIRST"
      | "open_repeat" => "rpt"
      | "open_tacs_to_lt" => "Tactical.TACS_TO_LT ["
      | "open_null_ok" => "NULL_OK_LT ("
      | "open_last_goal" => "LAST_GOAL ("
      | "open_head_goal" => "HEAD_GOAL ("
      | "open_select_lt" => "select_lt ["
      | "open_first_lt" => "FIRST_LT ["
      | _ => label

fun display_mid_label label =
  case label of
      "next_first" => "|"
    | "next_tacs_to_lt" => ","
    | "next_split_lt" => "|"
    | "next_select_lt" => "|"
    | _ => label

fun display_close_label label =
  case label of
      "close_repeat" => ""
    | "close_first" => "]"
    | "close_first_lt" => "]"
    | _ => label

fun current_seen seen_stack =
  case seen_stack of
      [] => false
    | seen :: _ => seen

fun mark_current_seen seen_stack =
  case seen_stack of
      [] => [true]
    | _ :: rest => true :: rest

fun reset_current_seen seen_stack =
  case seen_stack of
      [] => [false]
    | _ :: rest => false :: rest

fun sequence_prefix seen_stack = if current_seen seen_stack then ">> " else ""

fun current_pending pending_stack =
  case pending_stack of
      [] => ""
    | pending :: _ => pending

fun clear_current_pending pending_stack =
  case pending_stack of
      [] => [""]
    | _ :: rest => "" :: rest

fun step_prefix seen_stack pending_stack =
  case current_pending pending_stack of
      "" => sequence_prefix seen_stack
    | pending => pending

fun format_step index depth prefix step =
  let val d = depth_before step depth
  in
    case step of
        StepExpand {label, ...} => format_expand index d prefix label
      | StepPlain {label, ...} => block_line d index (prefix ^ "plain ") label
      | StepExpandList {label, ...} => format_expand_list index d prefix label
      | StepOpen {label, ...} => line d index prefix (display_open_label label)
      | StepMid {label, ...} => line d index prefix (display_mid_label label)
      | StepClose {label, ...} => line d index prefix (display_close_label label)
      | StepSelect {label, ...} => line d index (prefix ^ "select ") label
      | StepSelects {label, ...} => line d index (prefix ^ "selects ") label
  end

fun display_step (StepOpen {label = "open_paren", ...}) = false
  | display_step (StepClose {label = "close_paren", ...}) = false
  | display_step (StepClose {label = "close_repeat", ...}) = false
  | display_step (StepClose {label = "close_first", ...}) = false
  | display_step (StepClose {label = "close_first_lt", ...}) = false
  | display_step _ = true

datatype pp_frame = HiddenFrame | VisibleFrame | Then1Frame of {close_depth : int, after_depth : int}

fun pop_frame stack =
  case stack of
      [] => (VisibleFrame, [])
    | frame :: rest => (frame, rest)

fun frame_is_visible HiddenFrame = false
  | frame_is_visible _ = true

fun pop_context frame seen_stack pending_stack =
  if frame_is_visible frame then
    (case seen_stack of [] => [] | _ :: rest => rest,
     case pending_stack of [] => [] | _ :: rest => rest)
  else (seen_stack, pending_stack)

fun format_steps index depth frame_stack seen_stack pending_stack steps =
  case steps of
      [] => (index, "")
    | (StepOpen {label = "open_then1", ...}) :: rest =>
        let
          val seen_stack' = mark_current_seen seen_stack
          val pending_stack' = clear_current_pending pending_stack
          val open_depth = depth + 1
          val (count, rest_text) = format_steps (index + 1) (open_depth + 1) (Then1Frame {close_depth = open_depth, after_depth = depth} :: frame_stack) (false :: seen_stack') ("" :: pending_stack') rest
        in (count, line open_depth index "" ">- {" ^ rest_text) end
    | (step as StepOpen {label, ...}) :: rest =>
        if display_step step then
          let
            val prefix = step_prefix seen_stack pending_stack
            val seen_stack' = mark_current_seen seen_stack
            val pending_stack' = clear_current_pending pending_stack
            val (count, rest_text) = format_steps (index + 1) (depth + 1) (VisibleFrame :: frame_stack) (false :: seen_stack') ("" :: pending_stack') rest
          in (count, format_step index depth prefix step ^ rest_text) end
        else format_steps index depth (HiddenFrame :: frame_stack) seen_stack pending_stack rest
    | (step as StepClose _) :: rest =>
        let
          val (frame, frame_stack') = pop_frame frame_stack
          val (seen_stack', pending_stack') = pop_context frame seen_stack pending_stack
          val depth' = if frame_is_visible frame then Int.max(0, depth - 1) else depth
        in
          case frame of
              Then1Frame {close_depth, after_depth} =>
                (case rest of
                     StepOpen {label = "open_then1", ...} :: rest' =>
                       let
                         val (count, rest_text) = format_steps (index + 1) (close_depth + 1) (Then1Frame {close_depth = close_depth, after_depth = after_depth} :: frame_stack') (false :: seen_stack') ("" :: pending_stack') rest'
                       in (count, line close_depth index "" "} >- {" ^ rest_text) end
                   | _ =>
                       let val (count, rest_text) = format_steps (index + 1) after_depth frame_stack' seen_stack' pending_stack' rest
                       in (count, line close_depth index "" "}" ^ rest_text) end)
            | _ =>
                if display_step step then
                  let val (count, rest_text) = format_steps (index + 1) depth' frame_stack' (mark_current_seen seen_stack') (clear_current_pending pending_stack') rest
                  in (count, format_step index depth "" step ^ rest_text) end
                else format_steps index depth' frame_stack' seen_stack' pending_stack' rest
        end
    | (step as StepMid _) :: rest =>
        let val (count, rest_text) = format_steps (index + 1) depth frame_stack (reset_current_seen seen_stack) (clear_current_pending pending_stack) rest
        in (count, format_step index depth "" step ^ rest_text) end
    | step :: rest =>
        let
          val prefix = step_prefix seen_stack pending_stack
          val seen_stack' = mark_current_seen seen_stack
          val pending_stack' = clear_current_pending pending_stack
          val (count, rest_text) = format_steps (index + 1) depth frame_stack seen_stack' pending_stack' rest
        in (count, format_step index depth prefix step ^ rest_text) end

fun plain_steps body =
  [StepPlain {start_pos = 0, end_pos = size body, label = trim_space body}]

fun steps body =
  let
    val tree = parse_tactic body
  in
    (* GoalFrag cannot faithfully decompose proofs shaped as one tactic
       followed by several sibling THEN1/list-THEN1 branches, e.g.

         rpt conj_tac
         >- tac1
         >- tac2
         >- tac3

       or shorter chains where an impl_tac branch changes the remaining goal
       structure.  Plain HOL executes the full Tactical.THEN1 chain and its
       validation as one tactic; GoalFrag open/close branch replay can expose a
       different intermediate goal/validation shape.  Keep these whole-theorem
       tactics plain rather than displaying/executing finer boundaries than the
       runtime can represent.  TRY-containing chains stay decomposed because
       failed-prefix tests rely on their real failure boundary and the known
       unsafe shape does not require this fallback. *)
    if not (expr_contains_try tree) andalso
       (chained_then1_expr tree orelse
        (then1_chain_count tree >= 2 andalso expr_contains_impl_tac body tree)) then
      plain_steps body
    else steps_from_tree body tree
  end
  handle _ => plain_steps body

fun split_plan_line text =
  let
    val n = size text
    fun digits i =
      i + 1 < n andalso Char.isDigit (String.sub(text, i)) andalso Char.isDigit (String.sub(text, i + 1))
    fun find i =
      if i + 2 >= n then NONE
      else if digits i andalso String.sub(text, i + 2) = #" " then SOME (String.extract(text, i + 3, NONE))
      else find (i + 1)
  in find 0 end

fun leading_spaces text =
  let
    val n = size text
    fun loop i = if i < n andalso String.sub(text, i) = #" " then loop (i + 1) else i
  in String.substring(text, 0, loop 0) end

datatype rendered_line = NumberedLine of string | ContinuationLine of string

fun classify_line text =
  case split_plan_line text of
      SOME rest => NumberedLine rest
    | NONE => ContinuationLine text

fun drop_spaces n text =
  if size text >= n then String.extract(text, n, NONE) else text

fun collapse_single_then1 rendered =
  let
    fun go (NumberedLine open_line :: NumberedLine body_line :: NumberedLine close_line :: rest) acc =
          let val ind = leading_spaces open_line
              val body_ind = leading_spaces body_line
          in
            if open_line = ind ^ ">- {" andalso close_line = ind ^ "}" andalso
               String.isPrefix (ind ^ "  ") body_ind then
              go rest (NumberedLine (ind ^ ">- " ^ drop_spaces (size ind + 2) body_line) :: acc)
            else go (NumberedLine body_line :: NumberedLine close_line :: rest) (NumberedLine open_line :: acc)
          end
      | go (x :: rest) acc = go rest (x :: acc)
      | go [] acc = rev acc
  in go rendered [] end

fun combine_then1_lines rendered =
  let
    fun go (NumberedLine ra :: NumberedLine rb :: rest) acc =
          let val ia = leading_spaces ra
              val ib = leading_spaces rb
          in
            if ia = ib andalso ra = ia ^ "}" andalso rb = ib ^ ">- {" then
              go rest (NumberedLine (ia ^ "} >- {") :: acc)
            else go (NumberedLine rb :: rest) (NumberedLine ra :: acc)
          end
      | go (a :: rest) acc = go rest (a :: acc)
      | go [] acc = rev acc
  in go rendered [] end

fun renumber_body rendered =
  let
    fun go [] _ acc = (0, String.concat (rev acc))
      | go (NumberedLine raw :: rest) i acc =
          let val (count, text) = go rest (i + 1) (line 0 i "" raw :: acc)
          in (count + 1, text) end
      | go (ContinuationLine raw :: rest) i acc =
          go rest i (raw ^ "\n" :: acc)
  in go rendered 0 [] end

fun format {theory, theorem, source} plan =
  let
    val (_, body0) = format_steps 0 0 [] [false] [""] plan
    val raw_lines = List.filter (fn s => size s > 0) (String.fields (fn c => c = #"\n") body0)
    val rendered = map classify_line raw_lines
    val compact = collapse_single_then1 rendered
    val combined = combine_then1_lines compact
    val (count, body) = renumber_body combined
  in
    String.concat
      ["holbuild goalfrag plan ", theory, ":", theorem,
       " source=", source,
       " (", Int.toString count, " steps)\n",
       body]
  end

fun format_tactic selector tactic_text = format selector (steps tactic_text)

end
