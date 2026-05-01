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

fun runtime_helper_path () =
  case OS.Process.getEnv "HOLBUILD_GOALFRAG_RUNTIME" of
      SOME path => path
    | NONE => OS.Path.concat(HolbuildRuntimePaths.source_root, "sml/goalfrag_runtime.sml")

fun runtime_install_lines {checkpoint_enabled, tactic_timeout, timeout_marker} =
  ["use " ^ HolbuildToolchain.sml_string (runtime_helper_path ()) ^ ";",
   "val _ = HolbuildGoalfragRuntime.install {checkpoint_enabled = " ^
     (if checkpoint_enabled then "true" else "false") ^
     ", tactic_timeout = " ^ option_real_sml tactic_timeout ^
     ", timeout_marker = " ^ option_string_sml timeout_marker ^ "};",
   "val holbuild_begin_theorem = HolbuildGoalfragRuntime.begin_theorem;",
   "val holbuild_save_theorem_context = HolbuildGoalfragRuntime.save_theorem_context;"]


fun runtime_prelude _ [] = ""
  | runtime_prelude config _ = runtime_lines (runtime_load_lines @ runtime_install_lines config)

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
