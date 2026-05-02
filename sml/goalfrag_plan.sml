structure HolbuildGoalfragPlan =
struct

datatype step =
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

fun reverse_branch_expr body (TacticParse.ThenLT (lhs, [rhs as TacticParse.LNullOk (TacticParse.LTacsToLT _)])) =
      expr_contains_reverse body lhs orelse expr_contains_reverse body rhs
  | reverse_branch_expr body (TacticParse.ThenLT (lhs, [rhs as TacticParse.LThen1 _])) =
      expr_contains_reverse body lhs orelse expr_contains_reverse body rhs
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

fun subgoal_term subgoalText =
  if String.isPrefix "sg " subgoalText then SOME (String.extract(subgoalText, 3, NONE)) else NONE

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

fun merge_subgoal_then1 connective term bodySteps acc =
  case collect_then1_steps bodySteps of
      SOME (tacText, tacEnd, rest) =>
        SOME (merge_by_steps rest (StepExpand {end_pos = tacEnd, label = term ^ connective ^ "(" ^ tacText ^ ")"} :: acc))
    | NONE => NONE
and merge_by_steps [] acc = rev acc
  | merge_by_steps ((subgoalStep as StepExpand {end_pos = subEnd, label = subgoalText}) ::
                    (reverseStep as StepExpandList {label = "Tactical.REVERSE_LT", ...}) ::
                    (openStep as StepOpen {label = "open_then1", ...}) :: rest) acc =
      (case subgoal_term subgoalText of
           SOME term =>
             (case merge_subgoal_then1 " suffices_by " term rest acc of
                  SOME steps => steps
                | NONE => merge_by_steps (reverseStep :: openStep :: rest) (subgoalStep :: acc))
         | NONE => merge_by_steps (reverseStep :: openStep :: rest) (subgoalStep :: acc))
  | merge_by_steps ((subgoalStep as StepExpand {label = subgoalText, ...}) ::
                    (openStep as StepOpen {label = "open_then1", ...}) :: rest) acc =
      (case subgoal_term subgoalText of
           SOME term =>
             (case merge_subgoal_then1 " by " term rest acc of
                  SOME steps => steps
                | NONE => merge_by_steps (openStep :: rest) (subgoalStep :: acc))
         | NONE => merge_by_steps (openStep :: rest) (subgoalStep :: acc))
  | merge_by_steps (step :: rest) acc = merge_by_steps rest (step :: acc)

fun merge_reverse_steps [] acc = rev acc
  | merge_reverse_steps (StepExpandList {label = "Tactical.REVERSE_LT", ...} :: rest)
                        (StepExpand {end_pos, label} :: acc) =
      merge_reverse_steps rest (StepExpand {end_pos = end_pos, label = "Tactical.REVERSE (" ^ label ^ ")"} :: acc)
  | merge_reverse_steps (step :: rest) acc = merge_reverse_steps rest (step :: acc)

fun merge_select_then1_steps [] acc = rev acc
  | merge_select_then1_steps (StepOpen {label = "open_select_lt", ...} ::
                              StepExpand {label = pattern, ...} ::
                              StepMid {label = "next_select_lt", ...} ::
                              StepOpen {label = "open_paren", ...} :: rest) acc =
      (case collect_then1_steps rest of
           SOME (tacText, tacEnd, StepClose _ :: rest') =>
             merge_select_then1_steps rest'
               (StepExpandList {end_pos = tacEnd,
                                label = "Q.SELECT_GOALS_LT_THEN1 " ^ pattern ^ " (" ^ tacText ^ ")"} :: acc)
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
          val selectPrefix = String.concatWith " >>~ " (map select_prefix_step sels)
          fun consume (StepOpen {label = "open_then1", ...} :: StepExpand {end_pos, label} :: StepClose _ :: rest') =
                SOME (selectPrefix ^ " >- " ^ label, end_pos, rest')
            | consume (StepOpen {label = "open_first", ...} :: StepExpand {end_pos, label} :: StepClose _ :: rest') =
                SOME (selectPrefix ^ " >- " ^ label, end_pos, rest')
            | consume _ = NONE
        in
          case consume afterSels of
              SOME (text, tacEnd, rest') => merge_select_steps rest' (StepExpandList {end_pos = tacEnd, label = text} :: acc)
            | NONE => merge_select_steps afterSels acc
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
    fun isAtom (TacticParse.Group _) = false
      | isAtom (TacticParse.RepairGroup _) = false
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
  in
    merge_select_then1_steps
      (merge_select_steps
        (merge_reverse_steps (merge_by_steps (assign frags 0 []) []) []) []) []
  end

fun escape_inline label =
  String.translate
    (fn #"\n" => "\\n"
      | #"\t" => "\\t"
      | c => String.str c)
    label

fun pad2 n = if n < 10 then "0" ^ Int.toString n else Int.toString n

fun display_kind (StepExpand _) = "tactic"
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

fun connective 0 = ""
  | connective _ = ">> "

fun format_expand index depth prefix label =
  block_line depth index prefix label

fun format_expand_list index depth prefix label =
  case select_then1_parts label of
      SOME (pattern, body) =>
        line depth index (prefix ^ "list_tac ") ("Q.SELECT_GOALS_LT_THEN1 " ^ pattern ^ " (") ^
        detail_block (depth + 1) "" body ^
        body_margin ^ "   " ^ indent depth ^ ")\n"
    | NONE => block_line depth index (prefix ^ "list_tac ") label

fun format_step index depth step =
  let val d = depth_before step depth
      val prefix = connective index
  in
    case step of
        StepExpand {label, ...} => format_expand index d prefix label
      | StepExpandList {label, ...} => format_expand_list index d prefix label
      | StepOpen {label, ...} => line d index prefix label
      | StepMid {label, ...} => line d index prefix label
      | StepClose {label, ...} => line d index prefix label
      | StepSelect {label, ...} => line d index (prefix ^ "select ") label
      | StepSelects {label, ...} => line d index (prefix ^ "selects ") label
  end

fun display_step (StepOpen {label = "open_paren", ...}) = false
  | display_step (StepClose {label = "close_paren", ...}) = false
  | display_step _ = true

fun pop_visible stack =
  case stack of
      [] => (true, [])
    | visible :: rest => (visible, rest)

fun format_steps index depth stack steps =
  case steps of
      [] => (index, "")
    | (step as StepOpen _) :: rest =>
        if display_step step then
          let val (count, rest_text) = format_steps (index + 1) (depth + 1) (true :: stack) rest
          in (count, format_step index depth step ^ rest_text) end
        else format_steps index depth (false :: stack) rest
    | (step as StepClose _) :: rest =>
        let
          val (visible_open, stack') = pop_visible stack
          val depth' = if visible_open then Int.max(0, depth - 1) else depth
        in
          if display_step step then
            let val (count, rest_text) = format_steps (index + 1) depth' stack' rest
            in (count, format_step index depth step ^ rest_text) end
          else format_steps index depth' stack' rest
        end
    | step :: rest =>
        let val (count, rest_text) = format_steps (index + 1) depth stack rest
        in (count, format_step index depth step ^ rest_text) end

fun format {theory, theorem, source} plan =
  let val (count, body) = format_steps 0 0 [] plan
  in
    String.concat
      ["holbuild goalfrag plan ", theory, ":", theorem,
       " source=", source,
       " (", Int.toString count, " steps)\n",
       body]
  end

fun format_tactic selector tactic_text = format selector (steps tactic_text)

end
