structure HolbuildProofIr =
struct

open HOLSourceAST

fun repeat_string s n = if n <= 0 then "" else s ^ repeat_string s (n - 1)
fun indent n = repeat_string "  " n

fun span e = expSpan e
fun span_end (_, stop) = stop

fun trim_space text =
  let
    val n = size text
    fun left i = if i >= n orelse not (Char.isSpace (String.sub(text, i))) then i else left (i + 1)
    fun right i = if i < 0 orelse not (Char.isSpace (String.sub(text, i))) then i else right (i - 1)
    val l = left 0
    val r = right (n - 1)
  in if r < l then "" else String.substring(text, l, r - l + 1) end

fun slice source (start, stop) =
  let
    val n = size source
    val a = Int.max(0, Int.min(start, n))
    val b = Int.max(a, Int.min(stop, n))
  in String.substring(source, a, b - a) end

fun source_text source sp = trim_space (slice source sp)
fun parenthesize s = "(" ^ s ^ ")"

fun ident_name (Ident {id = (_, s), ...}) = SOME s
  | ident_name _ = NONE

fun flatten_app e =
  let
    fun go (App (f, x)) acc = go f (x :: acc)
      | go x acc = x :: acc
  in
    go e []
  end

fun app_name e =
  case flatten_app e of
      f :: args => Option.map (fn s => (s, args)) (ident_name f)
    | [] => NONE

fun list_elems (List {elems = {args, ...}, ...}) = SOME args
  | list_elems _ = NONE

fun tuple_elems (Tuple {elems = {args, ...}, ...}) = SOME args
  | tuple_elems _ = NONE

fun strip_closed_parens (Parens {exp, right = SOME _, ...}) = SOME exp
  | strip_closed_parens _ = NONE

fun precedence (ExpEmpty _) = 10
  | precedence (Parens _) = 10
  | precedence (Tuple _) = 10
  | precedence (List _) = 10
  | precedence (Ident _) = 10
  | precedence (Infix {id = (_, s), ...}) =
      (case Binarymap.peek (HOLSourceParser.initialScope, s) of SOME (p, _) => p | NONE => 0)
  | precedence (App _) = 9
  | precedence _ = 0

datatype tactic =
    TacThen of tactic list
  | TacThenLT of tactic * list_tactic
  | TacThen1 of tactic * tactic
  | TacThenL of tactic * tactic list
  | TacOrelse of tactic list
  | TacTry of tactic
  | TacRepeat of tactic
  | TacReverse of tactic
  | TacSubgoal of int * int
  | TacMapEvery of (int * int) * (int * int) list
  | TacApply of (int * int) * (int * int)
  | TacMapFirst of (int * int) * tactic list
  | TacSufficesBy of (int * int) * tactic
  | TacRepairGroup of (int * int) * tactic
  | TacAtomic of int * (int * int)
and list_tactic =
    LtThenLT of list_tactic list
  | LtThen of list_tactic * tactic list
  | LtTacsToLT of tactic list
  | LtNullOk of list_tactic
  | LtOrelse of list_tactic list
  | LtAllGoals of tactic
  | LtNthGoal of tactic * (int * int)
  | LtLastGoal of tactic
  | LtHeadGoal of tactic
  | LtSplit of (int * int) * list_tactic * list_tactic
  | LtReverse
  | LtTry of list_tactic
  | LtRepeat of list_tactic
  | LtFirstLT of tactic
  | LtSelectThen of tactic * tactic
  | LtSelectGoal of int * int
  | LtSelectGoals of int * int
  | LtRepairGroup of (int * int) * list_tactic
  | LtAtomic of int * (int * int)

datatype step =
    StepTactic of {end_pos : int, label : string, program : string}
  | StepList of {end_pos : int, label : string, program : string}
  | StepChoice of {end_pos : int, label : string, program : string, alternatives : string list}

fun step_end (StepTactic {end_pos, ...}) = end_pos
  | step_end (StepList {end_pos, ...}) = end_pos
  | step_end (StepChoice {end_pos, ...}) = end_pos

fun step_label (StepTactic {label, ...}) = label
  | step_label (StepList {label, ...}) = label
  | step_label (StepChoice {label, ...}) = label

fun step_program (StepTactic {program, ...}) = program
  | step_program (StepList {program, ...}) = program
  | step_program (StepChoice {program, ...}) = program

fun step_kind (StepTactic _) = "tactic"
  | step_kind (StepList _) = "list_tactic"
  | step_kind (StepChoice _) = "choice"

fun tactic_end (TacThen []) = 0
  | tactic_end (TacThen xs) = tactic_end (List.last xs)
  | tactic_end (TacThenLT (_, l)) = list_tactic_end l
  | tactic_end (TacThen1 (_, t)) = tactic_end t
  | tactic_end (TacThenL (t, [])) = tactic_end t
  | tactic_end (TacThenL (_, ts)) = tactic_end (List.last ts)
  | tactic_end (TacOrelse []) = 0
  | tactic_end (TacOrelse xs) = tactic_end (List.last xs)
  | tactic_end (TacTry t) = tactic_end t
  | tactic_end (TacRepeat t) = tactic_end t
  | tactic_end (TacReverse t) = tactic_end t
  | tactic_end (TacSubgoal sp) = span_end sp
  | tactic_end (TacApply (_, arg)) = span_end arg
  | tactic_end (TacMapEvery (_, [])) = 0
  | tactic_end (TacMapEvery (_, args)) = span_end (List.last args)
  | tactic_end (TacMapFirst (_, [])) = 0
  | tactic_end (TacMapFirst (_, ts)) = tactic_end (List.last ts)
  | tactic_end (TacSufficesBy (_, t)) = tactic_end t
  | tactic_end (TacRepairGroup (sp, _)) = span_end sp
  | tactic_end (TacAtomic (_, sp)) = span_end sp
and list_tactic_end (LtThenLT []) = 0
  | list_tactic_end (LtThenLT xs) = list_tactic_end (List.last xs)
  | list_tactic_end (LtThen (_, ts)) = tactic_end (List.last ts)
  | list_tactic_end (LtTacsToLT []) = 0
  | list_tactic_end (LtTacsToLT ts) = tactic_end (List.last ts)
  | list_tactic_end (LtNullOk lt) = list_tactic_end lt
  | list_tactic_end (LtOrelse []) = 0
  | list_tactic_end (LtOrelse xs) = list_tactic_end (List.last xs)
  | list_tactic_end (LtAllGoals t) = tactic_end t
  | list_tactic_end (LtNthGoal (_, sp)) = span_end sp
  | list_tactic_end (LtLastGoal t) = tactic_end t
  | list_tactic_end (LtHeadGoal t) = tactic_end t
  | list_tactic_end (LtSplit (sp, _, _)) = span_end sp
  | list_tactic_end LtReverse = 0
  | list_tactic_end (LtTry lt) = list_tactic_end lt
  | list_tactic_end (LtRepeat lt) = list_tactic_end lt
  | list_tactic_end (LtFirstLT t) = tactic_end t
  | list_tactic_end (LtSelectThen (_, t)) = tactic_end t
  | list_tactic_end (LtSelectGoal sp) = span_end sp
  | list_tactic_end (LtSelectGoals sp) = span_end sp
  | list_tactic_end (LtRepairGroup (sp, _)) = span_end sp
  | list_tactic_end (LtAtomic (_, sp)) = span_end sp

fun atomic e = TacAtomic (precedence e, span e)
fun list_atomic e = LtAtomic (precedence e, span e)

fun parse_tactic_ast e =
  case strip_closed_parens e of
      SOME inner => parse_tactic_ast inner
    | NONE =>
        (case e of
             Parens {exp, right = NONE, ...} => TacRepairGroup (span e, parse_tactic_ast exp)
           | ExpEmpty _ => TacAtomic (10, span e)
           | Infix {left, id = (_, opn), right} => parse_tactic_infix left opn right e
           | _ => parse_tactic_app e)
and parse_tactic_app e =
  case app_name e of
      SOME ("sg", [x]) => TacSubgoal (span x)
    | SOME ("subgoal", [x]) => TacSubgoal (span x)
    | SOME ("ALL_TAC", []) => TacThen []
    | SOME ("all_tac", []) => TacThen []
    | SOME ("MAP_EVERY", [f, xs]) => parse_map_every e f xs
    | SOME ("MAP_FIRST", [f, xs]) => parse_map_first e f xs
    | _ => atomic e
and parse_map_every whole f xs =
  (case list_elems xs of
      SOME args => TacThen (map (fn arg => TacApply (span f, span arg)) args)
    | NONE => atomic whole)
and parse_map_first whole f xs =
  (case list_elems xs of
      SOME args => TacMapFirst (span f, map (fn arg => TacApply (span f, span arg)) args)
    | NONE => atomic whole)
and parse_tactic_infix left opn right whole =
  case opn of
      ">>" => TacThen (flatten_then left @ flatten_then right)
    | "\\\\" => TacThen (flatten_then left @ flatten_then right)
    | "THEN" => TacThen (flatten_then left @ flatten_then right)
    | ">>>" => TacThenLT (parse_tactic_ast left, parse_list_tactic_ast right)
    | "THEN_LT" => TacThenLT (parse_tactic_ast left, parse_list_tactic_ast right)
    | "THENL" => parse_thenl left right whole
    | ">|" => parse_thenl left right whole
    | ">-" => TacThen1 (parse_tactic_ast left, parse_tactic_ast right)
    | "THEN1" => TacThen1 (parse_tactic_ast left, parse_tactic_ast right)
    | "by" => TacThen1 (TacSubgoal (span left), parse_tactic_ast right)
    | "suffices_by" => TacSufficesBy (span left, parse_tactic_ast right)
    | "ORELSE" => TacOrelse (flatten_orelse left @ flatten_orelse right)
    | ">~" => TacThenLT (parse_tactic_ast left, LtSelectGoal (span right))
    | ">>~" => TacThenLT (parse_tactic_ast left, LtSelectGoals (span right))
    | ">>~-" => parse_select_then1 left right whole
    | _ => atomic whole
and parse_thenl left right whole =
  case list_elems right of
      SOME branches => TacThenL (parse_tactic_ast left, map parse_tactic_ast branches)
    | NONE => atomic whole
and parse_select_then1 left right whole =
  case tuple_elems right of
      SOME [pats, body] => TacThenLT (parse_tactic_ast left, LtSelectThen (TacAtomic (10, span pats), parse_tactic_ast body))
    | _ => atomic whole
and flatten_then e =
  case strip_closed_parens e of
      SOME inner => flatten_then inner
    | NONE =>
        (case e of
             Infix {left, id = (_, opn), right} =>
               if opn = ">>" orelse opn = "\\\\" orelse opn = "THEN" then flatten_then left @ flatten_then right
               else [parse_tactic_ast e]
           | _ => [parse_tactic_ast e])
and flatten_orelse e =
  case strip_closed_parens e of
      SOME inner => flatten_orelse inner
    | NONE =>
        (case e of
             Infix {left, id = (_, "ORELSE"), right} => flatten_orelse left @ flatten_orelse right
           | _ => [parse_tactic_ast e])
and parse_list_tactic_ast e =
  case strip_closed_parens e of
      SOME inner => parse_list_tactic_ast inner
    | NONE =>
        (case e of
             Parens {exp, right = NONE, ...} => LtRepairGroup (span e, parse_list_tactic_ast exp)
           | Infix {left, id = (_, opn), right} => parse_list_tactic_infix left opn right e
           | _ => parse_list_tactic_app e)
and parse_list_tactic_app e =
  list_atomic e
and parse_list_tactic_infix left opn right whole =
  case opn of
      ">>>" => LtThenLT (flatten_thenlt left @ flatten_thenlt right)
    | "THEN_LT" => LtThenLT (flatten_thenlt left @ flatten_thenlt right)
    | ">>" => LtThen (parse_list_tactic_ast left, flatten_then right)
    | "\\\\" => LtThen (parse_list_tactic_ast left, flatten_then right)
    | "THEN" => LtThen (parse_list_tactic_ast left, flatten_then right)
    | _ => list_atomic whole
and flatten_thenlt e =
  case strip_closed_parens e of
      SOME inner => flatten_thenlt inner
    | NONE =>
        (case e of
             Infix {left, id = (_, opn), right} =>
               if opn = ">>>" orelse opn = "THEN_LT" then flatten_thenlt left @ flatten_thenlt right
               else [parse_list_tactic_ast e]
           | _ => [parse_list_tactic_ast e])
and flatten_orelse_lt e =
  case strip_closed_parens e of
      SOME inner => flatten_orelse_lt inner
    | NONE =>
        (case e of
             Infix {left, id = (_, "ORELSE_LT"), right} => flatten_orelse_lt left @ flatten_orelse_lt right
           | _ => [parse_list_tactic_ast e])

fun parse_tactic source =
  let
    val fed = ref false
    fun read _ = if !fed then "" else (fed := true; source)
    fun ignore_parse_error _ _ _ = ()
    val result = HOLSourceParser.parseSML "<holbuild proof ir tactic>" read ignore_parse_error HOLSourceParser.initialScope
    val exp =
      case #parseDec result () of
          SOME (DecExp e) => e
        | NONE => ExpEmpty 0
        | _ => raise Fail "expected tactic expression"
  in
    parse_tactic_ast exp
  end

fun join_program combinator [] identity = identity
  | join_program _ [x] _ = x
  | join_program combinator (x :: xs) identity =
      List.foldl (fn (rhs, lhs) => combinator ^ "(" ^ lhs ^ ", " ^ rhs ^ ")") x xs

fun tactic_program source tactic =
  case tactic of
      TacThen [] => "Tactical.ALL_TAC"
    | TacThen xs => join_program "Tactical.THEN" (map (tactic_program source) xs) "Tactical.ALL_TAC"
    | TacThenLT (t, lt) => "Tactical.THEN_LT(" ^ tactic_program source t ^ ", " ^ list_tactic_program source lt ^ ")"
    | TacThen1 (a, b) => "Tactical.THEN1(" ^ tactic_program source a ^ ", " ^ tactic_program source b ^ ")"
    | TacThenL (a, bs) => "Tactical.THENL(" ^ tactic_program source a ^ ", [" ^ String.concatWith ", " (map (tactic_program source) bs) ^ "])"
    | TacOrelse xs => join_program "Tactical.ORELSE" (map (tactic_program source) xs) "Tactical.NO_TAC"
    | TacTry t => "Tactical.TRY(" ^ tactic_program source t ^ ")"
    | TacRepeat t => "Tactical.REPEAT(" ^ tactic_program source t ^ ")"
    | TacReverse t => "Tactical.REVERSE(" ^ tactic_program source t ^ ")"
    | TacSubgoal sp => "sg " ^ source_text source sp
    | TacApply (f, arg) => parenthesize (source_text source f) ^ " " ^ source_text source arg
    | TacMapEvery _ => parenthesize (source_text source (tactic_span tactic))
    | TacMapFirst (_, ts) => "Tactical.FIRST [" ^ String.concatWith ", " (map (tactic_program source) ts) ^ "]"
    | TacSufficesBy _ => parenthesize (source_text source (tactic_span tactic))
    | TacRepairGroup (_, t) => tactic_program source t
    | TacAtomic (_, sp) => parenthesize (source_text source sp)
and list_tactic_program source lt =
  case lt of
      LtThenLT [] => "Tactical.ALL_LT"
    | LtThenLT xs => join_program "Tactical.THEN_LT" (map (list_tactic_program source) xs) "Tactical.ALL_LT"
    | LtThen (lt, ts) => join_program "Tactical.THEN" (list_tactic_program source lt :: map (tactic_program source) ts) "Tactical.ALL_LT"
    | LtTacsToLT ts => "Tactical.TACS_TO_LT [" ^ String.concatWith ", " (map (tactic_program source) ts) ^ "]"
    | LtNullOk lt => "Tactical.NULL_OK_LT(" ^ list_tactic_program source lt ^ ")"
    | LtOrelse xs => join_program "Tactical.ORELSE_LT" (map (list_tactic_program source) xs) "Tactical.NO_LT"
    | LtAllGoals t => "Tactical.ALLGOALS(" ^ tactic_program source t ^ ")"
    | LtNthGoal (t, n) => "Tactical.NTH_GOAL (" ^ tactic_program source t ^ ") (" ^ source_text source n ^ ")"
    | LtLastGoal t => "Tactical.LASTGOAL(" ^ tactic_program source t ^ ")"
    | LtHeadGoal t => "Tactical.HEADGOAL(" ^ tactic_program source t ^ ")"
    | LtSplit (n, a, b) => "Tactical.SPLIT_LT (" ^ source_text source n ^ ") (" ^ list_tactic_program source a ^ ", " ^ list_tactic_program source b ^ ")"
    | LtReverse => "Tactical.REVERSE_LT"
    | LtTry lt => "Tactical.TRY_LT(" ^ list_tactic_program source lt ^ ")"
    | LtRepeat lt => "Tactical.REPEAT_LT(" ^ list_tactic_program source lt ^ ")"
    | LtFirstLT t => "Tactical.FIRST_LT(" ^ tactic_program source t ^ ")"
    | LtSelectThen (selector, body) => "Tactical.SELECT_LT_THEN (" ^ tactic_program source selector ^ ") (" ^ tactic_program source body ^ ")"
    | LtSelectGoal sp => "Q.SELECT_GOAL_LT " ^ source_text source sp
    | LtSelectGoals sp => "Q.SELECT_GOALS_LT " ^ source_text source sp
    | LtRepairGroup (_, lt) => list_tactic_program source lt
    | LtAtomic (_, sp) => parenthesize (source_text source sp)
and tactic_span tactic =
  case tactic of
      TacThen [] => (0, 0)
    | TacThen xs => (#1 (tactic_span (hd xs)), #2 (tactic_span (List.last xs)))
    | TacThenLT (t, lt) => (#1 (tactic_span t), #2 (list_tactic_span lt))
    | TacThen1 (a, b) => (#1 (tactic_span a), #2 (tactic_span b))
    | TacThenL (a, []) => tactic_span a
    | TacThenL (a, bs) => (#1 (tactic_span a), #2 (tactic_span (List.last bs)))
    | TacOrelse [] => (0, 0)
    | TacOrelse xs => (#1 (tactic_span (hd xs)), #2 (tactic_span (List.last xs)))
    | TacTry t => tactic_span t
    | TacRepeat t => tactic_span t
    | TacReverse t => tactic_span t
    | TacSubgoal sp => sp
    | TacApply (f, arg) => (#1 f, #2 arg)
    | TacMapEvery (f, []) => f
    | TacMapEvery (f, xs) => (#1 f, #2 (List.last xs))
    | TacMapFirst (f, []) => f
    | TacMapFirst (f, xs) => (#1 f, #2 (tactic_span (List.last xs)))
    | TacSufficesBy (q, t) => (#1 q, #2 (tactic_span t))
    | TacRepairGroup (sp, _) => sp
    | TacAtomic (_, sp) => sp
and list_tactic_span lt =
  case lt of
      LtThenLT [] => (0, 0)
    | LtThenLT xs => (#1 (list_tactic_span (hd xs)), #2 (list_tactic_span (List.last xs)))
    | LtThen (lt, ts) => (#1 (list_tactic_span lt), #2 (tactic_span (List.last ts)))
    | LtTacsToLT [] => (0, 0)
    | LtTacsToLT ts => (#1 (tactic_span (hd ts)), #2 (tactic_span (List.last ts)))
    | LtNullOk lt => list_tactic_span lt
    | LtOrelse [] => (0, 0)
    | LtOrelse xs => (#1 (list_tactic_span (hd xs)), #2 (list_tactic_span (List.last xs)))
    | LtAllGoals t => tactic_span t
    | LtNthGoal (t, n) => (#1 (tactic_span t), #2 n)
    | LtLastGoal t => tactic_span t
    | LtHeadGoal t => tactic_span t
    | LtSplit (n, _, _) => n
    | LtReverse => (0, 0)
    | LtTry lt => list_tactic_span lt
    | LtRepeat lt => list_tactic_span lt
    | LtFirstLT t => tactic_span t
    | LtSelectThen (a, b) => (#1 (tactic_span a), #2 (tactic_span b))
    | LtSelectGoal sp => sp
    | LtSelectGoals sp => sp
    | LtRepairGroup (sp, _) => sp
    | LtAtomic (_, sp) => sp

fun tactic_label source (TacApply (f, arg)) = source_text source f ^ " " ^ source_text source arg
  | tactic_label source tactic = source_text source (tactic_span tactic)

fun tactic_step source tactic =
  StepTactic {end_pos = tactic_end tactic,
              label = tactic_label source tactic,
              program = tactic_program source tactic}

fun list_step source label_end label program =
  StepList {end_pos = label_end, label = label, program = program}

fun choice_step end_pos label program alternatives =
  StepChoice {end_pos = end_pos, label = label, program = program, alternatives = alternatives}

fun allgoals_step source tactic =
  let val label = ">> " ^ tactic_label source tactic
  in list_step source (tactic_end tactic) label ("Tactical.ALLGOALS(" ^ tactic_program source tactic ^ ")") end

fun suffices_tactic_program source q = "Q_TAC SUFF_TAC " ^ source_text source q

fun suffices_branch_step source rhs =
  list_step source (tactic_end rhs) ("  >- " ^ tactic_label source rhs)
    ("Tactical.NTH_GOAL (Tactical.THEN(" ^ tactic_program source rhs ^ ", Tactical.NO_TAC)) 1")

fun suffix_steps source tactic =
  case tactic of
      TacSufficesBy (q, rhs) =>
        [list_step source (span_end q) (">> " ^ suffices_tactic_program source q)
           ("Tactical.ALLGOALS(" ^ suffices_tactic_program source q ^ ")"),
         suffices_branch_step source rhs]
    | _ => [allgoals_step source tactic]

fun plan_tactic source tactic =
  case tactic of
      TacThen [] => [tactic_step source tactic]
    | TacThen (first :: rest) => plan_tactic source first @ List.concat (map (suffix_steps source) rest)
    | TacThen1 (lhs, rhs) =>
        plan_tactic source lhs @
        [list_step source (tactic_end rhs) (">- " ^ source_text source (tactic_span rhs))
           ("Tactical.NTH_GOAL (Tactical.THEN(" ^ tactic_program source rhs ^ ", Tactical.NO_TAC)) 1")]
    | TacThenL (lhs, branches) =>
        plan_tactic source lhs @
        [list_step source (tactic_end tactic) ">| [...]"
           ("Tactical.NULL_OK_LT (Tactical.TACS_TO_LT [" ^ String.concatWith ", " (map (tactic_program source) branches) ^ "])")]
    | TacThenLT (lhs, lt) => plan_tactic source lhs @ plan_list_tactic source ">>>" lt
    | TacOrelse xs => [choice_step (tactic_end tactic) "ORELSE" (tactic_program source tactic) (map (tactic_label source) xs)]
    | TacMapFirst (_, xs) => [choice_step (tactic_end tactic) "FIRST" (tactic_program source tactic) (map (tactic_label source) xs)]
    | TacSufficesBy (q, rhs) =>
        [StepTactic {end_pos = span_end q, label = suffices_tactic_program source q, program = suffices_tactic_program source q},
         suffices_branch_step source rhs]
    | TacRepairGroup (_, inner) => plan_tactic source inner
    | _ => [tactic_step source tactic]
and plan_list_tactic source prefix lt =
  case lt of
      LtSelectGoal sp => [list_step source (list_tactic_end lt) (">> list_tac Q.SELECT_GOAL_LT " ^ source_text source sp) (list_tactic_program source lt)]
    | LtSelectGoals sp => [list_step source (list_tactic_end lt) (">> list_tac Q.SELECT_GOALS_LT " ^ source_text source sp) (list_tactic_program source lt)]
    | LtSelectThen (TacAtomic (_, pats), body) =>
        [list_step source (list_tactic_end lt)
           (">> list_tac Q.SELECT_GOALS_LT_THEN1 " ^ source_text source pats ^ " (" ^ tactic_label source body ^ ")")
           ("Q.SELECT_GOALS_LT_THEN1 " ^ source_text source pats ^ " (" ^ tactic_program source body ^ ")")]
    | _ => [list_step source (list_tactic_end lt) (prefix ^ " " ^ source_text source (list_tactic_span lt)) (list_tactic_program source lt)]

fun steps source = plan_tactic source (parse_tactic source)

fun display_line_count (StepChoice {alternatives, ...}) = 1 + Int.max(0, 2 * length alternatives - 1)
  | display_line_count _ = 1

fun format_index i = if i < 10 then "0" ^ Int.toString i else Int.toString i

fun format_step (i, step) =
  case step of
      StepChoice {label, alternatives, ...} =>
        let
          fun alt_lines (_, []) = ""
            | alt_lines (j, [alt]) = "  " ^ format_index j ^ "   " ^ alt ^ "\n"
            | alt_lines (j, alt :: rest) =
                "  " ^ format_index j ^ "   " ^ alt ^ "\n" ^
                "  " ^ format_index (j + 1) ^ "   |\n" ^
                alt_lines (j + 2, rest)
        in
          "  " ^ format_index i ^ " " ^ label ^ "\n" ^ alt_lines (i + 1, alternatives)
        end
    | _ => "  " ^ format_index i ^ " " ^ step_label step ^ "\n"

fun format_plan_lines steps =
  let
    fun loop _ [] = ""
      | loop i (step :: rest) = format_step (i, step) ^ loop (i + display_line_count step) rest
  in loop 0 steps end

fun display_step_count plan = List.foldl (fn (step, n) => n + display_line_count step) 0 plan

fun format_tactic {theory, theorem, source} tactic_text =
  let val plan = steps tactic_text
  in
    "holbuild proof-ir plan " ^ theory ^ ":" ^ theorem ^ " source=" ^ source ^
    " (" ^ Int.toString (display_step_count plan) ^ " steps)\n" ^
    format_plan_lines plan
  end

end
