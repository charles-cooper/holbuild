structure HolbuildTheoryCheckpoints =
struct

exception Error of string

type boundary = {name : string, safe_name : string, theorem_start : int,
                 theorem_stop : int, boundary : int, tactic_start : int,
                 tactic_end : int, tactic_text : string,
                 has_proof_attrs : bool, prefix_hash : string}
type checkpoint = {name : string, safe_name : string, theorem_start : int,
                   theorem_stop : int, boundary : int, tactic_start : int,
                   tactic_end : int, tactic_text : string,
                   has_proof_attrs : bool, prefix_hash : string,
                   context_path : string, context_ok : string,
                   end_of_proof_path : string, end_of_proof_ok : string,
                   deps_key : string, checkpoint_key : string}

fun is_ident c = Char.isAlphaNum c orelse c = #"_" orelse c = #"'"

fun starts_with text i needle =
  let val n = size text
      val m = size needle
  in i + m <= n andalso String.substring(text, i, m) = needle end

fun skip_comment text i =
  let
    val n = size text
    fun loop j depth =
      if j >= n then n
      else if starts_with text j "(*" then loop (j + 2) (depth + 1)
      else if starts_with text j "*)" then
        if depth = 1 then j + 2 else loop (j + 2) (depth - 1)
      else loop (j + 1) depth
  in
    loop (i + 2) 1
  end

fun skip_ws_comments text i =
  let
    val n = size text
    fun loop j =
      if j >= n then n
      else if Char.isSpace (String.sub(text, j)) then loop (j + 1)
      else if starts_with text j "(*" then loop (skip_comment text j)
      else j
  in
    loop i
  end

fun statement_boundary text i =
  let val j = skip_ws_comments text i
  in if j < size text andalso String.sub(text, j) = #";" then j + 1 else i end

fun safe_name name =
  let
    fun safe c = if is_ident c then c else #"_"
    val s = String.map safe name
  in
    if s = "" then "unnamed" else s
  end

fun prefix_hash text boundary =
  HolbuildToolchain.hash_text (String.substring(text, 0, boundary))

fun parse_int field value =
  case Int.fromString value of
      SOME n => n
    | NONE => raise Error ("bad AST theorem report integer for " ^ field ^ ": " ^ value)

fun slice text start stop =
  if start < 0 orelse stop < start orelse stop > size text then
    raise Error "AST theorem report span is outside source text"
  else String.substring(text, start, stop - start)

fun boundary_from_report_line source line =
  case String.tokens (fn c => c = #"\t") line of
      ["theorem", name, theorem_start_s, theorem_stop_s,
       tactic_start_s, tactic_end_s, attrs_s] =>
        let
          val theorem_start = parse_int "theorem_start" theorem_start_s
          val theorem_stop = parse_int "theorem_stop" theorem_stop_s
          val tactic_start = parse_int "tactic_start" tactic_start_s
          val tactic_end = parse_int "tactic_end" tactic_end_s
          val boundary = statement_boundary source theorem_stop
        in
          {name = name, safe_name = safe_name name,
           theorem_start = theorem_start, theorem_stop = theorem_stop,
           boundary = boundary, tactic_start = tactic_start, tactic_end = tactic_end,
           tactic_text = slice source tactic_start tactic_end,
           has_proof_attrs = attrs_s = "1",
           prefix_hash = prefix_hash source boundary}
        end
    | [] => raise Error "empty AST theorem report line"
    | _ => raise Error ("bad AST theorem report line: " ^ line)

fun discover_from_report {source, report} : boundary list =
  map (boundary_from_report_line source)
      (List.filter (fn line => line <> "")
                   (String.tokens (fn c => c = #"\n") report))

fun begin_theorem_line ({name, tactic_text, context_path, context_ok,
                         end_of_proof_path, end_of_proof_ok,
                         has_proof_attrs, ...} : checkpoint) =
  String.concat
    ["val _ = holbuild_begin_theorem(",
     HolbuildToolchain.sml_string name, ", ",
     HolbuildToolchain.sml_string tactic_text, ", ",
     HolbuildToolchain.sml_string context_path, ", ",
     HolbuildToolchain.sml_string context_ok, ", ",
     HolbuildToolchain.sml_string end_of_proof_path, ", ",
     HolbuildToolchain.sml_string end_of_proof_ok, ", ",
     if has_proof_attrs then "true" else "false",
     ");\n"]

fun runtime_lines lines =
  String.concat (map (fn line => line ^ "\n") lines)

val runtime_load_lines =
  ["load \"HOLSourceParser\";",
   "load \"TacticParse\";",
   "load \"smlExecute\";",
   "load \"smlTimeout\";"]

fun option_real_sml NONE = "NONE : real option"
  | option_real_sml (SOME r) = "SOME " ^ Real.toString r

fun option_string_sml NONE = "NONE : string option"
  | option_string_sml (SOME s) = "SOME " ^ HolbuildToolchain.sml_string s

fun runtime_theorem_state_lines {checkpoint_enabled, tactic_timeout, timeout_marker} =
  ["val holbuild_checkpoint_enabled = " ^ (if checkpoint_enabled then "true" else "false") ^ ";",
   "val holbuild_tactic_timeout = " ^ option_real_sml tactic_timeout ^ ";",
   "val holbuild_tactic_timeout_marker = " ^ option_string_sml timeout_marker ^ ";",
   "val holbuild_theorem_info = ref NONE : (string * string * string * string * string * string * bool * int) option ref;",
   "val holbuild_context_info = ref NONE : (string * string * int) option ref;",
   "fun holbuild_env_bool name = case OS.Process.getEnv name of SOME \"1\" => SOME true | SOME \"true\" => SOME true | SOME \"yes\" => SOME true | SOME \"0\" => SOME false | SOME \"false\" => SOME false | SOME \"no\" => SOME false | _ => NONE;",
   "fun holbuild_bool_text true = \"true\" | holbuild_bool_text false = \"false\";",
   "fun holbuild_seconds (a, b) = Time.toReal (Time.-(b, a));",
   "fun holbuild_fmt_time t = Real.fmt (StringCvt.FIX (SOME 3)) t;",
   "fun holbuild_delete_file path = OS.FileSys.remove path handle _ => ();",
   "fun holbuild_delete_checkpoint path = (holbuild_delete_file (path ^ \".ok\"); holbuild_delete_file path);",
   "fun holbuild_write_checkpoint_ok path ok_text = let val out = TextIO.openOut (path ^ \".ok\") in TextIO.output(out, ok_text); TextIO.closeOut out end;",
   "fun holbuild_write_timeout_marker label seconds = case holbuild_tactic_timeout_marker of NONE => () | SOME path => let val out = TextIO.openOut path in TextIO.output(out, String.concat [label, \"\\t\", Real.toString seconds, \"\\n\"]); TextIO.closeOut out end;",
   "fun holbuild_timeout_message label seconds = String.concat [\"holbuild tactic timeout after \", Real.toString seconds, \"s: \", label];",
   "fun holbuild_with_tactic_timeout label f x = case holbuild_tactic_timeout of NONE => f x | SOME seconds => (smlTimeout.timeout seconds f x handle smlTimeout.FunctionTimeout => (holbuild_write_timeout_marker label seconds; raise Fail (holbuild_timeout_message label seconds)));",
   "fun holbuild_save_checkpoint label default_share path ok_text depth = if not holbuild_checkpoint_enabled then () else let val share = Option.getOpt(holbuild_env_bool \"HOLBUILD_SHARE_COMMON_DATA\", default_share) val timing = Option.getOpt(holbuild_env_bool \"HOLBUILD_CHECKPOINT_TIMING\", false) val t0 = Time.now() val _ = holbuild_delete_checkpoint path val _ = if share then PolyML.shareCommonData PolyML.rootFunction else () val t1 = Time.now() val _ = PolyML.SaveState.saveChild(path, depth) val t2 = Time.now() val _ = holbuild_write_checkpoint_ok path ok_text val _ = if timing then TextIO.output(TextIO.stdErr, String.concat [\"holbuild checkpoint kind=\", label, \" share=\", holbuild_bool_text share, \" depth=\", Int.toString depth, \" share_s=\", holbuild_fmt_time (holbuild_seconds (t0, t1)), \" save_s=\", holbuild_fmt_time (holbuild_seconds (t1, t2)), \" size=\", Position.toString (OS.FileSys.fileSize path), \" path=\", path, \"\\n\"]) else () in () end;",
   "fun holbuild_begin_theorem (name, tactic_text, context_path, context_ok, end_path, end_ok, has_attrs) = let val depth = length (PolyML.SaveState.showHierarchy()) in if holbuild_checkpoint_enabled then (holbuild_delete_checkpoint context_path; holbuild_delete_checkpoint end_path) else (); holbuild_theorem_info := SOME (name, tactic_text, context_path, context_ok, end_path, end_ok, has_attrs, depth); holbuild_context_info := SOME (context_path, context_ok, depth) end;",
   "fun holbuild_save_theorem_context () = case !holbuild_context_info of NONE => () | SOME (context_path, context_ok, depth) => (holbuild_context_info := NONE; holbuild_save_checkpoint \"theorem_context\" false context_path context_ok depth);",
   "fun holbuild_print_goal_state label = let val proof = proofManagerLib.p() val goals = proofManagerLib.top_goals() in TextIO.output(TextIO.stdErr, String.concat [\"\\nholbuild goal state at failed fragment: \", label, \"\\nholbuild remaining goals: \", Int.toString (length goals), \"\\n\"]); PP.prettyPrint(fn s => TextIO.output(TextIO.stdErr, s), 100) (proofManagerLib.pp_proof proof); TextIO.output(TextIO.stdErr, \"\\n\") end handle e => TextIO.output(TextIO.stdErr, String.concat [\"holbuild failed to print goal state: \", General.exnMessage e, \"\\n\"]);"]

val runtime_tactic_parse_lines =
  ["fun holbuild_parse_tactic s = let",
   "  val fed = ref false",
   "  fun read _ = if !fed then \"\" else (fed := true; s)",
   "  val result = HOLSourceParser.parseSML \"<holbuild tactic>\" read (fn _ => fn _ => fn msg => raise Fail msg) HOLSourceParser.initialScope",
   "in case #parseDec result () of",
   "     SOME (HOLSourceAST.DecExp e) => TacticParse.parseTacticBlock e",
   "   | NONE => TacticParse.parseTacticBlock (HOLSourceAST.ExpEmpty 0)",
   "   | _ => raise Fail \"expected tactic expression\"",
   "end;"]

val runtime_fragment_structure_lines =
  ["fun holbuild_flatten_frags frags = let",
   "  fun go [] acc = rev acc",
   "    | go (TacticParse.FFOpen opn :: rest) acc = go rest (TacticParse.FFOpen opn :: acc)",
   "    | go (TacticParse.FFMid mid :: rest) acc = go rest (TacticParse.FFMid mid :: acc)",
   "    | go (TacticParse.FFClose cls :: rest) acc = go rest (TacticParse.FFClose cls :: acc)",
   "    | go (TacticParse.FAtom a :: rest) acc = go rest (TacticParse.FAtom a :: acc)",
   "    | go (TacticParse.FGroup (_, inner) :: rest) acc = go rest (rev (holbuild_flatten_frags inner) @ acc)",
   "    | go (TacticParse.FBracket (opn, inner, cls, _) :: rest) acc = let val flat = TacticParse.FFOpen opn :: holbuild_flatten_frags inner @ [TacticParse.FFClose cls] in go rest (rev flat @ acc) end",
   "    | go (TacticParse.FMBracket (opn, mid, cls, [], _) :: rest) acc = go rest (TacticParse.FFClose cls :: TacticParse.FFOpen opn :: acc)",
   "    | go (TacticParse.FMBracket (opn, mid, cls, arms, _) :: rest) acc = let",
   "        fun interleave [] _ = []",
   "          | interleave [a] _ = holbuild_flatten_frags a",
   "          | interleave (a::as') mid = holbuild_flatten_frags a @ [TacticParse.FFMid mid] @ interleave as' mid",
   "        val flat = TacticParse.FFOpen opn :: interleave arms mid @ [TacticParse.FFClose cls]",
   "      in go rest (rev flat @ acc) end",
   "in go frags [] end;",
   "fun holbuild_alt_span (TacticParse.Subgoal (s, e)) = SOME (s, e)",
   "  | holbuild_alt_span (TacticParse.LSelectGoal p) = SOME p",
   "  | holbuild_alt_span (TacticParse.LSelectGoals p) = SOME p",
   "  | holbuild_alt_span (TacticParse.LTacsToLT (TacticParse.OOpaque (_, p))) = SOME p",
   "  | holbuild_alt_span _ = NONE;",
   "fun holbuild_frag_end (TacticParse.FAtom a) = (case (TacticParse.topSpan a, holbuild_alt_span a) of (SOME (_, r), _) => r | (NONE, SOME (_, r)) => r | _ => 0)",
   "  | holbuild_frag_end _ = 0;",
   "fun holbuild_is_composable (TacticParse.Then _) = true",
   "  | holbuild_is_composable (TacticParse.ThenLT _) = true",
   "  | holbuild_is_composable (TacticParse.LThen1 _) = true",
   "  | holbuild_is_composable (TacticParse.LThenLT _) = true",
   "  | holbuild_is_composable (TacticParse.Group _) = true",
   "  | holbuild_is_composable _ = false;",
   "fun holbuild_span_text body (a, b) = String.substring(body, a, b - a);",
   "fun holbuild_text_contains_reverse body sp = let val s = holbuild_span_text body sp in String.isSubstring \"REVERSE\" s orelse String.isSubstring \"reverse\" s end;",
   "fun holbuild_text_contains_branch body sp = let val s = holbuild_span_text body sp in String.isSubstring \">-\" s orelse String.isSubstring \"THEN1\" s orelse String.isSubstring \"THENL\" s orelse String.isSubstring \">|\" s orelse String.isSubstring \">~\" s orelse String.isSubstring \">>~\" s orelse String.isSubstring \" by \" s orelse String.isSubstring \"suffices_by\" s end;",
   "fun holbuild_text_contains_multigoal s = String.isSubstring \"Induct_on\" s orelse String.isSubstring \"Induct >>\" s orelse String.isSubstring \"Cases_on\" s orelse String.isSubstring \"rpt conj_tac\" s orelse String.isSubstring \"TRY CONJ_TAC\" s;",
   "fun holbuild_body_requires_atomic body = holbuild_text_contains_multigoal body;",
   "fun holbuild_exprs_contain_reverse body es = List.exists (holbuild_expr_contains_reverse body) es",
   "and holbuild_expr_contains_reverse body e = (case e of",
   "    TacticParse.Then es => holbuild_exprs_contain_reverse body es",
   "  | TacticParse.ThenLT (e, es) => holbuild_expr_contains_reverse body e orelse holbuild_exprs_contain_reverse body es",
   "  | TacticParse.First es => holbuild_exprs_contain_reverse body es",
   "  | TacticParse.Try e => holbuild_expr_contains_reverse body e",
   "  | TacticParse.Repeat e => holbuild_expr_contains_reverse body e",
   "  | TacticParse.MapEvery (sp, es) => holbuild_text_contains_reverse body sp orelse holbuild_exprs_contain_reverse body es",
   "  | TacticParse.MapFirst (sp, es) => holbuild_text_contains_reverse body sp orelse holbuild_exprs_contain_reverse body es",
   "  | TacticParse.Opaque (_, sp) => holbuild_text_contains_reverse body sp",
   "  | TacticParse.LThen (e, es) => holbuild_expr_contains_reverse body e orelse holbuild_exprs_contain_reverse body es",
   "  | TacticParse.LThenLT es => holbuild_exprs_contain_reverse body es",
   "  | TacticParse.LThen1 e => holbuild_expr_contains_reverse body e",
   "  | TacticParse.LTacsToLT e => holbuild_expr_contains_reverse body e",
   "  | TacticParse.LNullOk e => holbuild_expr_contains_reverse body e",
   "  | TacticParse.LFirst es => holbuild_exprs_contain_reverse body es",
   "  | TacticParse.LAllGoals e => holbuild_expr_contains_reverse body e",
   "  | TacticParse.LNthGoal (e, sp) => holbuild_expr_contains_reverse body e orelse holbuild_text_contains_reverse body sp",
   "  | TacticParse.LLastGoal e => holbuild_expr_contains_reverse body e",
   "  | TacticParse.LHeadGoal e => holbuild_expr_contains_reverse body e",
   "  | TacticParse.LSplit (sp, e1, e2) => holbuild_text_contains_reverse body sp orelse holbuild_expr_contains_reverse body e1 orelse holbuild_expr_contains_reverse body e2",
   "  | TacticParse.LReverse => true",
   "  | TacticParse.LTry e => holbuild_expr_contains_reverse body e",
   "  | TacticParse.LRepeat e => holbuild_expr_contains_reverse body e",
   "  | TacticParse.LFirstLT e => holbuild_expr_contains_reverse body e",
   "  | TacticParse.LSelectThen (e1, e2) => holbuild_expr_contains_reverse body e1 orelse holbuild_expr_contains_reverse body e2",
   "  | TacticParse.LOpaque (_, sp) => holbuild_text_contains_reverse body sp",
   "  | TacticParse.List (sp, es) => holbuild_text_contains_reverse body sp orelse holbuild_exprs_contain_reverse body es",
   "  | TacticParse.Group (_, sp, e) => holbuild_text_contains_reverse body sp orelse holbuild_expr_contains_reverse body e",
   "  | TacticParse.RepairGroup (sp, _, e, _) => holbuild_text_contains_reverse body sp orelse holbuild_expr_contains_reverse body e",
   "  | TacticParse.OOpaque (_, sp) => holbuild_text_contains_reverse body sp",
   "  | _ => false);",
   "fun holbuild_reverse_branch_expr body (TacticParse.ThenLT (lhs, [rhs as TacticParse.LNullOk (TacticParse.LTacsToLT _)])) = holbuild_expr_contains_reverse body lhs orelse holbuild_expr_contains_reverse body rhs",
   "  | holbuild_reverse_branch_expr body (TacticParse.ThenLT (lhs, [rhs as TacticParse.LThen1 _])) = holbuild_expr_contains_reverse body lhs orelse holbuild_expr_contains_reverse body rhs",
   "  | holbuild_reverse_branch_expr body (TacticParse.Group (_, _, e)) = holbuild_reverse_branch_expr body e",
   "  | holbuild_reverse_branch_expr _ _ = false;",
   "fun holbuild_group_atom_expr body (TacticParse.FAtom (TacticParse.Group (_, sp, e))) = if holbuild_text_contains_branch body sp orelse holbuild_reverse_branch_expr body e then NONE else if holbuild_is_composable e then SOME e else NONE",
   "  | holbuild_group_atom_expr _ _ = NONE;",
   "fun holbuild_reexpand_group_atoms body frags = let",
   "  fun reexpand e = let val subFrags = TacticParse.linearize (fn x => Option.isSome (TacticParse.topSpan x)) e in holbuild_reexpand_group_atoms body (holbuild_flatten_frags subFrags) end",
   "  fun go [] acc = rev acc",
   "    | go (f::rest) acc = (case holbuild_group_atom_expr body f of SOME e => go rest (rev (reexpand e) @ acc) | NONE => go rest (f :: acc))",
   "in go frags [] end;"]

val runtime_fragment_name_lines =
  ["fun holbuild_open_name TacticParse.FOpen = \"open_paren\"",
   "  | holbuild_open_name TacticParse.FOpenThen1 = \"open_then1\"",
   "  | holbuild_open_name TacticParse.FOpenFirst = \"open_first\"",
   "  | holbuild_open_name TacticParse.FOpenRepeat = \"open_repeat\"",
   "  | holbuild_open_name TacticParse.FOpenTacsToLT = \"open_tacs_to_lt\"",
   "  | holbuild_open_name TacticParse.FOpenNullOk = \"open_null_ok\"",
   "  | holbuild_open_name (TacticParse.FOpenNthGoal (i, _)) = \"open_nth_goal \" ^ Int.toString i",
   "  | holbuild_open_name TacticParse.FOpenLastGoal = \"open_last_goal\"",
   "  | holbuild_open_name TacticParse.FOpenHeadGoal = \"open_head_goal\"",
   "  | holbuild_open_name (TacticParse.FOpenSplit (i, _)) = \"open_split_lt \" ^ Int.toString i",
   "  | holbuild_open_name TacticParse.FOpenSelect = \"open_select_lt\"",
   "  | holbuild_open_name TacticParse.FOpenFirstLT = \"open_first_lt\";",
   "fun holbuild_mid_name TacticParse.FNextFirst = \"next_first\"",
   "  | holbuild_mid_name TacticParse.FNextTacsToLT = \"next_tacs_to_lt\"",
   "  | holbuild_mid_name TacticParse.FNextSplit = \"next_split_lt\"",
   "  | holbuild_mid_name TacticParse.FNextSelect = \"next_select_lt\";",
   "fun holbuild_close_name TacticParse.FClose = \"close_paren\"",
   "  | holbuild_close_name TacticParse.FCloseFirst = \"close_first\"",
   "  | holbuild_close_name TacticParse.FCloseRepeat = \"close_repeat\"",
   "  | holbuild_close_name TacticParse.FCloseFirstLT = \"close_first_lt\";"]

val runtime_step_plan_lines =
  ["fun holbuild_frag_type (TacticParse.FAtom (TacticParse.LSelectGoal _)) = \"select\"",
   "  | holbuild_frag_type (TacticParse.FAtom (TacticParse.LSelectGoals _)) = \"selects\"",
   "  | holbuild_frag_type (TacticParse.FAtom TacticParse.LReverse) = \"expand_list\"",
   "  | holbuild_frag_type (TacticParse.FAtom (TacticParse.LTacsToLT _)) = \"expand_list\"",
   "  | holbuild_frag_type (TacticParse.FAtom _) = \"expand\"",
   "  | holbuild_frag_type (TacticParse.FFOpen _) = \"open\"",
   "  | holbuild_frag_type (TacticParse.FFMid _) = \"mid\"",
   "  | holbuild_frag_type (TacticParse.FFClose _) = \"close\"",
   "  | holbuild_frag_type _ = \"\";",
   "fun holbuild_substring s (a, b) = String.substring(s, a, b - a);",
   "fun holbuild_raw_frag_text body a = (case (TacticParse.topSpan a, holbuild_alt_span a) of (SOME sp, _) => holbuild_substring body sp | (NONE, SOME sp) => holbuild_substring body sp | _ => \"\");",
   "fun holbuild_is_term_quote raw = String.isPrefix \"`\" raw orelse String.isPrefix \"\\226\\128\\152\" raw orelse String.isPrefix \"\\226\\128\\156\" raw;",
   "fun holbuild_frag_text body (TacticParse.FAtom a) = let val raw = holbuild_raw_frag_text body a in case a of TacticParse.LReverse => \"Tactical.REVERSE_LT\" | TacticParse.LTacsToLT _ => if String.size raw = 0 then raw else \"Tactical.TACS_TO_LT (\" ^ raw ^ \")\" | TacticParse.Subgoal _ => if holbuild_is_term_quote raw then \"sg \" ^ raw else raw | _ => raw end",
   "  | holbuild_frag_text _ (TacticParse.FFOpen opn) = holbuild_open_name opn",
   "  | holbuild_frag_text _ (TacticParse.FFMid mid) = holbuild_mid_name mid",
   "  | holbuild_frag_text _ (TacticParse.FFClose cls) = holbuild_close_name cls",
   "  | holbuild_frag_text _ _ = \"\";",
   "fun holbuild_is_select \"select\" = true | holbuild_is_select \"selects\" = true | holbuild_is_select _ = false;",
   "fun holbuild_subgoal_term subgoalText = if String.isPrefix \"sg \" subgoalText then SOME (String.extract(subgoalText, 3, NONE)) else NONE;",
   "fun holbuild_join_tactic [] = \"ALL_TAC\" | holbuild_join_tactic [t] = t | holbuild_join_tactic ts = String.concatWith \" \\\\\\\\ \" ts;",
   "fun holbuild_collect_then1_steps steps = let fun go [] _ _ = NONE | go ((_, \"close\", _) :: rest) acc last = SOME (holbuild_join_tactic (rev acc), last, rest) | go ((endp, \"expand\", text) :: rest) acc _ = go rest (text :: acc) endp | go _ _ _ = NONE in go steps [] 0 end;",
   "fun holbuild_merge_subgoal_then1 connective term bodySteps acc = (case holbuild_collect_then1_steps bodySteps of SOME (tacText, tacEnd, rest) => SOME (holbuild_merge_by_steps rest ((tacEnd, \"expand\", term ^ connective ^ \"(\" ^ tacText ^ \")\") :: acc)) | NONE => NONE)",
   "and holbuild_merge_by_steps [] acc = rev acc",
   "  | holbuild_merge_by_steps ((subEnd, \"expand\", subgoalText) :: (reverseStep as (_, \"expand_list\", \"Tactical.REVERSE_LT\")) :: (openStep as (_, \"open\", \"open_then1\")) :: rest) acc = (case holbuild_subgoal_term subgoalText of SOME term => (case holbuild_merge_subgoal_then1 \" suffices_by \" term rest acc of SOME steps => steps | NONE => holbuild_merge_by_steps (reverseStep :: openStep :: rest) ((subEnd, \"expand\", subgoalText) :: acc)) | NONE => holbuild_merge_by_steps (reverseStep :: openStep :: rest) ((subEnd, \"expand\", subgoalText) :: acc))",
   "  | holbuild_merge_by_steps ((subEnd, \"expand\", subgoalText) :: (openStep as (_, \"open\", \"open_then1\")) :: rest) acc = (case holbuild_subgoal_term subgoalText of SOME term => (case holbuild_merge_subgoal_then1 \" by \" term rest acc of SOME steps => steps | NONE => holbuild_merge_by_steps (openStep :: rest) ((subEnd, \"expand\", subgoalText) :: acc)) | NONE => holbuild_merge_by_steps (openStep :: rest) ((subEnd, \"expand\", subgoalText) :: acc))",
   "  | holbuild_merge_by_steps (step :: rest) acc = holbuild_merge_by_steps rest (step :: acc);",
   "fun holbuild_merge_reverse_steps [] acc = rev acc",
   "  | holbuild_merge_reverse_steps ((_, \"expand_list\", \"Tactical.REVERSE_LT\") :: rest) ((tacEnd, \"expand\", tacText) :: acc) = holbuild_merge_reverse_steps rest ((tacEnd, \"expand\", \"Tactical.REVERSE (\" ^ tacText ^ \")\") :: acc)",
   "  | holbuild_merge_reverse_steps (step :: rest) acc = holbuild_merge_reverse_steps rest (step :: acc);",
   "fun holbuild_join_then_tactic [] = \"ALL_TAC\" | holbuild_join_then_tactic [t] = t | holbuild_join_then_tactic ts = String.concatWith \" >> \" ts;",
   "fun holbuild_is_branch_open \"open_then1\" = true | holbuild_is_branch_open \"open_first\" = true | holbuild_is_branch_open _ = false;",
   "fun holbuild_collect_branch_body steps = let fun go [] _ _ = NONE | go ((_, \"close\", closeText) :: rest) acc last = SOME (holbuild_join_then_tactic (rev acc), last, closeText, rest) | go ((endp, \"expand\", text) :: rest) acc _ = go rest (text :: acc) endp | go _ _ _ = NONE in go steps [] 0 end;",
   "fun holbuild_merge_branch_body_steps [] acc = rev acc",
   "  | holbuild_merge_branch_body_steps ((openStep as (_, \"open\", openText)) :: rest) acc = if holbuild_is_branch_open openText then (case holbuild_collect_branch_body rest of SOME (bodyText, bodyEnd, closeText, after) => if holbuild_body_requires_atomic bodyText then holbuild_merge_branch_body_steps after ((bodyEnd, \"close\", closeText) :: (bodyEnd, \"expand\", bodyText) :: openStep :: acc) else holbuild_merge_branch_body_steps rest (openStep :: acc) | NONE => holbuild_merge_branch_body_steps rest (openStep :: acc)) else holbuild_merge_branch_body_steps rest (openStep :: acc)",
   "  | holbuild_merge_branch_body_steps (step :: rest) acc = holbuild_merge_branch_body_steps rest (step :: acc);",
   "fun holbuild_merge_select_steps [] acc = rev acc",
   "  | holbuild_merge_select_steps ((endP, kind, patText) :: rest) acc =",
   "      if holbuild_is_select kind then let",
   "        fun collect [] sels = (rev sels, [])",
   "          | collect ((ep, k, t) :: rest') sels = if holbuild_is_select k then collect rest' (t :: sels) else (rev sels, (ep, k, t) :: rest')",
   "        val (sels, afterSels) = collect rest [patText]",
   "        fun prefix [] = \"\" | prefix [p] = \"Q.SELECT_GOAL_LT \" ^ p | prefix (p::ps) = \"Q.SELECT_GOAL_LT \" ^ p ^ \" >>~ Q.SELECT_GOALS_LT \" ^ String.concatWith \" >>~ Q.SELECT_GOALS_LT \" ps",
   "        val selectPrefix = prefix sels",
   "        fun consume ((_, \"open\", \"open_then1\") :: (tacEnd, \"expand\", tacText) :: (_, \"close\", _) :: rest') = SOME (selectPrefix ^ \" >- \" ^ tacText, tacEnd, rest')",
   "          | consume ((_, \"open\", \"open_first\") :: (tacEnd, \"expand\", tacText) :: (_, \"close\", _) :: rest') = SOME (selectPrefix ^ \" >- \" ^ tacText, tacEnd, rest')",
   "          | consume _ = NONE",
   "      in case consume afterSels of SOME (text, tacEnd, rest') => holbuild_merge_select_steps rest' ((tacEnd, \"expand_list\", text) :: acc) | NONE => holbuild_merge_select_steps afterSels acc end",
   "      else holbuild_merge_select_steps rest ((endP, kind, patText) :: acc);",
   "fun holbuild_steps body = let",
   "  val tree = holbuild_parse_tactic body",
   "  fun isAtom e = Option.isSome (TacticParse.topSpan e)",
   "  val frags = holbuild_reexpand_group_atoms body (holbuild_flatten_frags (TacticParse.linearize isAtom tree))",
   "  fun assign [] _ acc = rev acc",
   "    | assign (f::rest) last acc = let val typ = holbuild_frag_type f val txt = holbuild_frag_text body f val (endPos, last') = case f of TacticParse.FAtom _ => let val e = holbuild_frag_end f in (e, e) end | _ => (last, last) in if String.size txt > 0 then assign rest last' ((endPos, typ, txt) :: acc) else assign rest last acc end",
   "in holbuild_merge_select_steps (holbuild_merge_branch_body_steps (holbuild_merge_reverse_steps (holbuild_merge_by_steps (assign frags 0 []) []) []) []) [] end;"]

val runtime_fragment_execution_lines =
  ["fun holbuild_report_step_failure label e = (holbuild_print_goal_state label; raise e);",
   "fun holbuild_apply_ftac label ftac = holbuild_with_tactic_timeout label (fn () => (proofManagerLib.ef ftac; ())) () handle e => holbuild_report_step_failure label e;",
   "fun holbuild_eval_step label program fail_msg = holbuild_with_tactic_timeout label (fn () => if smlExecute.quse_string program then () else raise Fail fail_msg) () handle e => holbuild_report_step_failure label e;",
   "fun holbuild_step (\"open\", text) = let val ftac = if String.isPrefix \"open_nth_goal \" text then goalFrag.open_nth_goal (Option.valOf (Int.fromString (String.extract(text, 14, NONE)))) else if String.isPrefix \"open_split_lt \" text then goalFrag.open_split_lt (Option.valOf (Int.fromString (String.extract(text, 14, NONE)))) else case text of \"open_paren\" => goalFrag.open_paren | \"open_then1\" => goalFrag.open_then1 | \"open_first\" => goalFrag.open_first | \"open_repeat\" => goalFrag.open_repeat | \"open_tacs_to_lt\" => goalFrag.open_tacs_to_lt | \"open_null_ok\" => goalFrag.open_null_ok | \"open_last_goal\" => goalFrag.open_last_goal | \"open_head_goal\" => goalFrag.open_head_goal | \"open_select_lt\" => goalFrag.open_select_lt | \"open_first_lt\" => goalFrag.open_first_lt | _ => raise Fail (\"unknown open frag: \" ^ text) in holbuild_apply_ftac text ftac end",
   "  | holbuild_step (\"mid\", text) = let val ftac = case text of \"next_first\" => goalFrag.next_first | \"next_tacs_to_lt\" => goalFrag.next_tacs_to_lt | \"next_split_lt\" => goalFrag.next_split_lt | \"next_select_lt\" => goalFrag.next_select_lt | _ => raise Fail (\"unknown mid frag: \" ^ text) in holbuild_apply_ftac text ftac end",
   "  | holbuild_step (\"close\", text) = let val ftac = case text of \"close_paren\" => goalFrag.close_paren | \"close_first\" => goalFrag.close_first | \"close_repeat\" => goalFrag.close_repeat | \"close_first_lt\" => goalFrag.close_first_lt | _ => raise Fail (\"unknown close frag: \" ^ text) in holbuild_apply_ftac text ftac end",
   "  | holbuild_step (\"expand\", text) = holbuild_eval_step text (\"proofManagerLib.ef(goalFrag.expand((\" ^ text ^ \")));\") (\"tactic fragment failed: \" ^ text)",
   "  | holbuild_step (\"expand_list\", text) = holbuild_eval_step text (\"proofManagerLib.ef(goalFrag.expand_list((\" ^ text ^ \")));\") (\"list tactic fragment failed: \" ^ text)",
   "  | holbuild_step (typ, _) = raise Fail (\"unknown fragment type: \" ^ typ);",
   "fun holbuild_run_steps [] = ()",
   "  | holbuild_run_steps ((_, typ, text) :: rest) = (holbuild_step (typ, text); holbuild_run_steps rest);"]

val runtime_prover_lines =
  ["fun holbuild_drop_all () = (proofManagerLib.drop_all (); ()) handle _ => ();",
   "fun holbuild_atomic_prove label g tac = holbuild_with_tactic_timeout label (fn () => Tactical.TAC_PROOF(g, tac)) () handle e => (proofManagerLib.set_goal g; holbuild_report_step_failure label e);",
   "fun holbuild_goalfrag_prove name end_path end_ok checkpoint_depth g tac tactic_text = let",
   "          val _ = proofManagerLib.set_goalfrag g",
   "          val _ = holbuild_run_steps (holbuild_steps tactic_text)",
   "          val th = proofManagerLib.top_thm() handle e => (holbuild_print_goal_state (name ^ \" finish\"); raise e)",
   "          val _ = holbuild_save_checkpoint \"end_of_proof\" false end_path end_ok checkpoint_depth",
   "          val _ = proofManagerLib.drop_all()",
   "        in th end;",
   "fun holbuild_goalfrag_prover (g, tac) =",
   "  case !holbuild_theorem_info of",
   "      NONE => Tactical.TAC_PROOF(g, tac)",
   "    | SOME (name, tactic_text, _, _, end_path, end_ok, has_attrs, checkpoint_depth) =>",
   "        let",
   "          val _ = holbuild_theorem_info := NONE",
   "          val atomic = has_attrs orelse tactic_text = \"\" orelse holbuild_body_requires_atomic tactic_text",
   "        in if atomic then holbuild_atomic_prove name g tac else holbuild_goalfrag_prove name end_path end_ok checkpoint_depth g tac tactic_text end",
   "        handle e => (holbuild_theorem_info := NONE; holbuild_context_info := NONE; holbuild_drop_all(); raise e);",
   "val _ = Tactical.set_prover holbuild_goalfrag_prover;"]

fun runtime_prelude _ [] = ""
  | runtime_prelude config _ =
      runtime_lines
        (runtime_load_lines @
         runtime_theorem_state_lines config @
         runtime_tactic_parse_lines @
         runtime_fragment_structure_lines @
         runtime_fragment_name_lines @
         runtime_step_plan_lines @
         runtime_fragment_execution_lines @
         runtime_prover_lines)

fun instrument ({source, start_offset, checkpoints, save_checkpoints, tactic_timeout, timeout_marker} :
                {source : string, start_offset : int, checkpoints : checkpoint list,
                 save_checkpoints : bool, tactic_timeout : real option,
                 timeout_marker : string option}) =
  let
    val n = size source
    fun source_slice i j = String.substring(source, i, j - i)
    fun active ({boundary, ...} : checkpoint) = boundary > start_offset
    val active_checkpoints = List.filter active checkpoints
    fun loop pos entries acc =
      case entries of
          [] => String.concat (rev (source_slice pos n :: acc))
        | (checkpoint as {theorem_start, boundary, context_path, ...}) :: rest =>
            if boundary <= start_offset then loop pos rest acc
            else
              loop boundary rest
                ("val _ = holbuild_save_theorem_context();\n" ::
                 "\n" ::
                 source_slice theorem_start boundary ::
                 begin_theorem_line checkpoint ::
                 source_slice pos theorem_start ::
                 acc)
  in
    runtime_prelude {checkpoint_enabled = save_checkpoints,
                     tactic_timeout = tactic_timeout,
                     timeout_marker = timeout_marker}
                    active_checkpoints ^
    loop start_offset checkpoints []
  end

end
