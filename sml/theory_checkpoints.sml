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
                   context_path : string, end_of_proof_path : string}

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

fun save_line output =
  "val _ = PolyML.SaveState.saveChild(" ^
  HolbuildToolchain.sml_string output ^
  ", length (PolyML.SaveState.showHierarchy()));\n"

fun begin_theorem_line ({name, tactic_text, end_of_proof_path, has_proof_attrs, ...} : checkpoint) =
  String.concat
    ["val _ = holbuild_begin_theorem(",
     HolbuildToolchain.sml_string name, ", ",
     HolbuildToolchain.sml_string tactic_text, ", ",
     HolbuildToolchain.sml_string end_of_proof_path, ", ",
     if has_proof_attrs then "true" else "false",
     ");\n"]

fun runtime_prelude [] = ""
  | runtime_prelude _ =
    String.concat
    ["load \"HOLSourceParser\";\n",
     "load \"TacticParse\";\n",
     "load \"smlExecute\";\n",
     "val holbuild_theorem_info = ref NONE : (string * string * string * bool) option ref;\n",
     "fun holbuild_begin_theorem info = holbuild_theorem_info := SOME info;\n",
     "fun holbuild_parse_tactic s = let\n",
     "  val fed = ref false\n",
     "  fun read _ = if !fed then \"\" else (fed := true; s)\n",
     "  val result = HOLSourceParser.parseSML \"<holbuild tactic>\" read (fn _ => fn _ => fn msg => raise Fail msg) HOLSourceParser.initialScope\n",
     "in case #parseDec result () of\n",
     "     SOME (HOLSourceAST.DecExp e) => TacticParse.parseTacticBlock e\n",
     "   | NONE => TacticParse.parseTacticBlock (HOLSourceAST.ExpEmpty 0)\n",
     "   | _ => raise Fail \"expected tactic expression\"\n",
     "end;\n",
     "fun holbuild_flatten_frags frags = let\n",
     "  fun go [] acc = rev acc\n",
     "    | go (TacticParse.FFOpen opn :: rest) acc = go rest (TacticParse.FFOpen opn :: acc)\n",
     "    | go (TacticParse.FFMid mid :: rest) acc = go rest (TacticParse.FFMid mid :: acc)\n",
     "    | go (TacticParse.FFClose cls :: rest) acc = go rest (TacticParse.FFClose cls :: acc)\n",
     "    | go (TacticParse.FAtom a :: rest) acc = go rest (TacticParse.FAtom a :: acc)\n",
     "    | go (TacticParse.FGroup (_, inner) :: rest) acc = go rest (rev (holbuild_flatten_frags inner) @ acc)\n",
     "    | go (TacticParse.FBracket (opn, inner, cls, _) :: rest) acc = let val flat = TacticParse.FFOpen opn :: holbuild_flatten_frags inner @ [TacticParse.FFClose cls] in go rest (rev flat @ acc) end\n",
     "    | go (TacticParse.FMBracket (opn, mid, cls, [], _) :: rest) acc = go rest (TacticParse.FFClose cls :: TacticParse.FFOpen opn :: acc)\n",
     "    | go (TacticParse.FMBracket (opn, mid, cls, arms, _) :: rest) acc = let\n",
     "        fun interleave [] _ = []\n",
     "          | interleave [a] _ = holbuild_flatten_frags a\n",
     "          | interleave (a::as') mid = holbuild_flatten_frags a @ [TacticParse.FFMid mid] @ interleave as' mid\n",
     "        val flat = TacticParse.FFOpen opn :: interleave arms mid @ [TacticParse.FFClose cls]\n",
     "      in go rest (rev flat @ acc) end\n",
     "in go frags [] end;\n",
     "fun holbuild_alt_span (TacticParse.Subgoal (s, e)) = SOME (s, e)\n",
     "  | holbuild_alt_span (TacticParse.LSelectGoal p) = SOME p\n",
     "  | holbuild_alt_span (TacticParse.LSelectGoals p) = SOME p\n",
     "  | holbuild_alt_span _ = NONE;\n",
     "fun holbuild_frag_end (TacticParse.FAtom a) = (case (TacticParse.topSpan a, holbuild_alt_span a) of (SOME (_, r), _) => r | (NONE, SOME (_, r)) => r | _ => 0)\n",
     "  | holbuild_frag_end _ = 0;\n",
     "fun holbuild_open_name TacticParse.FOpen = \"open_paren\"\n",
     "  | holbuild_open_name TacticParse.FOpenThen1 = \"open_then1\"\n",
     "  | holbuild_open_name TacticParse.FOpenFirst = \"open_first\"\n",
     "  | holbuild_open_name TacticParse.FOpenRepeat = \"open_repeat\"\n",
     "  | holbuild_open_name TacticParse.FOpenTacsToLT = \"open_tacs_to_lt\"\n",
     "  | holbuild_open_name TacticParse.FOpenNullOk = \"open_null_ok\"\n",
     "  | holbuild_open_name (TacticParse.FOpenNthGoal (i, _)) = \"open_nth_goal \" ^ Int.toString i\n",
     "  | holbuild_open_name TacticParse.FOpenLastGoal = \"open_last_goal\"\n",
     "  | holbuild_open_name TacticParse.FOpenHeadGoal = \"open_head_goal\"\n",
     "  | holbuild_open_name (TacticParse.FOpenSplit (i, _)) = \"open_split_lt \" ^ Int.toString i\n",
     "  | holbuild_open_name TacticParse.FOpenSelect = \"open_select_lt\"\n",
     "  | holbuild_open_name TacticParse.FOpenFirstLT = \"open_first_lt\";\n",
     "fun holbuild_mid_name TacticParse.FNextFirst = \"next_first\"\n",
     "  | holbuild_mid_name TacticParse.FNextTacsToLT = \"next_tacs_to_lt\"\n",
     "  | holbuild_mid_name TacticParse.FNextSplit = \"next_split_lt\"\n",
     "  | holbuild_mid_name TacticParse.FNextSelect = \"next_select_lt\";\n",
     "fun holbuild_close_name TacticParse.FClose = \"close_paren\"\n",
     "  | holbuild_close_name TacticParse.FCloseFirst = \"close_first\"\n",
     "  | holbuild_close_name TacticParse.FCloseRepeat = \"close_repeat\"\n",
     "  | holbuild_close_name TacticParse.FCloseFirstLT = \"close_first_lt\";\n",
     "fun holbuild_frag_type (TacticParse.FAtom (TacticParse.LSelectGoal _)) = \"select\"\n",
     "  | holbuild_frag_type (TacticParse.FAtom (TacticParse.LSelectGoals _)) = \"selects\"\n",
     "  | holbuild_frag_type (TacticParse.FAtom _) = \"expand\"\n",
     "  | holbuild_frag_type (TacticParse.FFOpen _) = \"open\"\n",
     "  | holbuild_frag_type (TacticParse.FFMid _) = \"mid\"\n",
     "  | holbuild_frag_type (TacticParse.FFClose _) = \"close\"\n",
     "  | holbuild_frag_type _ = \"\";\n",
     "fun holbuild_substring s (a, b) = String.substring(s, a, b - a);\n",
     "fun holbuild_frag_text body (TacticParse.FAtom a) = let val raw = (case (TacticParse.topSpan a, holbuild_alt_span a) of (SOME sp, _) => holbuild_substring body sp | (NONE, SOME sp) => holbuild_substring body sp | _ => \"\") in case a of TacticParse.Subgoal _ => if String.size raw > 0 andalso String.sub(raw, 0) = #\"`\" then \"sg \" ^ raw else raw | _ => raw end\n",
     "  | holbuild_frag_text _ (TacticParse.FFOpen opn) = holbuild_open_name opn\n",
     "  | holbuild_frag_text _ (TacticParse.FFMid mid) = holbuild_mid_name mid\n",
     "  | holbuild_frag_text _ (TacticParse.FFClose cls) = holbuild_close_name cls\n",
     "  | holbuild_frag_text _ _ = \"\";\n",
     "fun holbuild_is_select \"select\" = true | holbuild_is_select \"selects\" = true | holbuild_is_select _ = false;\n",
     "fun holbuild_merge_select_steps [] acc = rev acc\n",
     "  | holbuild_merge_select_steps ((endP, kind, patText) :: rest) acc =\n",
     "      if holbuild_is_select kind then let\n",
     "        fun collect [] sels = (rev sels, [])\n",
     "          | collect ((ep, k, t) :: rest') sels = if holbuild_is_select k then collect rest' (t :: sels) else (rev sels, (ep, k, t) :: rest')\n",
     "        val (sels, afterSels) = collect rest [patText]\n",
     "        fun prefix [] = \"\" | prefix [p] = \"Q.SELECT_GOAL_LT \" ^ p | prefix (p::ps) = \"Q.SELECT_GOAL_LT \" ^ p ^ \" >>~ Q.SELECT_GOALS_LT \" ^ String.concatWith \" >>~ Q.SELECT_GOALS_LT \" ps\n",
     "        val selectPrefix = prefix sels\n",
     "        fun consume ((_, \"open\", \"open_then1\") :: (tacEnd, \"expand\", tacText) :: (_, \"close\", _) :: rest') = SOME (selectPrefix ^ \" >- \" ^ tacText, tacEnd, rest')\n",
     "          | consume ((_, \"open\", \"open_first\") :: (tacEnd, \"expand\", tacText) :: (_, \"close\", _) :: rest') = SOME (selectPrefix ^ \" >- \" ^ tacText, tacEnd, rest')\n",
     "          | consume _ = NONE\n",
     "      in case consume afterSels of SOME (text, tacEnd, rest') => holbuild_merge_select_steps rest' ((tacEnd, \"expand_list\", text) :: acc) | NONE => holbuild_merge_select_steps afterSels acc end\n",
     "      else holbuild_merge_select_steps rest ((endP, kind, patText) :: acc);\n",
     "fun holbuild_steps body = let\n",
     "  val tree = holbuild_parse_tactic body\n",
     "  fun isAtom e = Option.isSome (TacticParse.topSpan e)\n",
     "  val frags = holbuild_flatten_frags (TacticParse.linearize isAtom tree)\n",
     "  fun assign [] _ acc = rev acc\n",
     "    | assign (f::rest) last acc = let val typ = holbuild_frag_type f val txt = holbuild_frag_text body f val (endPos, last') = case f of TacticParse.FAtom _ => let val e = holbuild_frag_end f in (e, e) end | _ => (last, last) in if String.size txt > 0 then assign rest last' ((endPos, typ, txt) :: acc) else assign rest last acc end\n",
     "in holbuild_merge_select_steps (assign frags 0 []) [] end;\n",
     "fun holbuild_step (\"open\", text) = let val ftac = if String.isPrefix \"open_nth_goal \" text then goalFrag.open_nth_goal (Option.valOf (Int.fromString (String.extract(text, 14, NONE)))) else if String.isPrefix \"open_split_lt \" text then goalFrag.open_split_lt (Option.valOf (Int.fromString (String.extract(text, 14, NONE)))) else case text of \"open_paren\" => goalFrag.open_paren | \"open_then1\" => goalFrag.open_then1 | \"open_first\" => goalFrag.open_first | \"open_repeat\" => goalFrag.open_repeat | \"open_tacs_to_lt\" => goalFrag.open_tacs_to_lt | \"open_null_ok\" => goalFrag.open_null_ok | \"open_last_goal\" => goalFrag.open_last_goal | \"open_head_goal\" => goalFrag.open_head_goal | \"open_select_lt\" => goalFrag.open_select_lt | \"open_first_lt\" => goalFrag.open_first_lt | _ => raise Fail (\"unknown open frag: \" ^ text) in proofManagerLib.ef ftac; () end\n",
     "  | holbuild_step (\"mid\", text) = let val ftac = case text of \"next_first\" => goalFrag.next_first | \"next_tacs_to_lt\" => goalFrag.next_tacs_to_lt | \"next_split_lt\" => goalFrag.next_split_lt | \"next_select_lt\" => goalFrag.next_select_lt | _ => raise Fail (\"unknown mid frag: \" ^ text) in proofManagerLib.ef ftac; () end\n",
     "  | holbuild_step (\"close\", text) = let val ftac = case text of \"close_paren\" => goalFrag.close_paren | \"close_first\" => goalFrag.close_first | \"close_repeat\" => goalFrag.close_repeat | \"close_first_lt\" => goalFrag.close_first_lt | _ => raise Fail (\"unknown close frag: \" ^ text) in proofManagerLib.ef ftac; () end\n",
     "  | holbuild_step (\"expand\", text) = if smlExecute.quse_string (\"proofManagerLib.ef(goalFrag.expand(\" ^ text ^ \"));\") then () else raise Fail (\"tactic fragment failed: \" ^ text)\n",
     "  | holbuild_step (\"expand_list\", text) = if smlExecute.quse_string (\"proofManagerLib.ef(goalFrag.expand_list(\" ^ text ^ \"));\") then () else raise Fail (\"list tactic fragment failed: \" ^ text)\n",
     "  | holbuild_step (typ, _) = raise Fail (\"unknown fragment type: \" ^ typ);\n",
     "fun holbuild_run_steps [] = ()\n",
     "  | holbuild_run_steps ((_, typ, text) :: rest) = (holbuild_step (typ, text); holbuild_run_steps rest);\n",
     "fun holbuild_drop_all () = (proofManagerLib.drop_all (); ()) handle _ => ();\n",
     "fun holbuild_goalfrag_prover (g, tac) =\n",
     "  case !holbuild_theorem_info of\n",
     "      NONE => Tactical.TAC_PROOF(g, tac)\n",
     "    | SOME (name, tactic_text, end_path, has_attrs) =>\n",
     "        let\n",
     "          val _ = holbuild_theorem_info := NONE\n",
     "          val _ = proofManagerLib.set_goalfrag g\n",
     "          val _ = if has_attrs orelse tactic_text = \"\" then (proofManagerLib.expand tac; ()) else holbuild_run_steps (holbuild_steps tactic_text)\n",
     "          val th = proofManagerLib.top_thm()\n",
     "          val _ = PolyML.SaveState.saveChild(end_path, length (PolyML.SaveState.showHierarchy()))\n",
     "          val _ = proofManagerLib.drop_all()\n",
     "        in th end\n",
     "        handle e => (holbuild_theorem_info := NONE; holbuild_drop_all(); raise e);\n",
     "val _ = Tactical.set_prover holbuild_goalfrag_prover;\n"]

fun instrument ({source, start_offset, checkpoints} :
                {source : string, start_offset : int, checkpoints : checkpoint list}) =
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
                (save_line context_path ::
                 "\n" ::
                 source_slice theorem_start boundary ::
                 begin_theorem_line checkpoint ::
                 source_slice pos theorem_start ::
                 acc)
  in
    runtime_prelude active_checkpoints ^ loop start_offset checkpoints []
  end

end
