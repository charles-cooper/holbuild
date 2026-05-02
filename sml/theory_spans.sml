structure HolbuildTheorySpans =
struct

fun bool_digit true = "1"
  | bool_digit false = "0"

fun theorem_report_line name theorem_start theorem_stop tactic_start tactic_end has_attrs =
  String.concatWith "\t"
    ["theorem", name, Int.toString theorem_start, Int.toString theorem_stop,
     Int.toString tactic_start, Int.toString tactic_end, bool_digit has_attrs]

fun theorem_report_lines result =
  let
    fun loop acc =
      case #parseDec result () of
          NONE => rev acc
        | SOME (HOLSourceAST.HOLTheoremDecl {theorem_, id = (_, name), proof_, tac, stop, ...}) =>
            let
              val (tactic_start, tactic_end) = HOLSourceAST.expSpan tac
              val has_attrs = case proof_ of SOME {attrs = SOME _, ...} => true | _ => false
              val line = theorem_report_line name theorem_ stop tactic_start tactic_end has_attrs
            in
              loop (line :: acc)
            end
        | SOME _ => loop acc
  in
    loop []
  end

fun parser_reader source_text =
  let val fed = ref false
  in fn _ => if !fed then "" else (fed := true; source_text) end

fun ignore_parse_error _ _ _ = ()

fun scan source_path source_text =
  let
    val result = HOLSourceParser.parseSML source_path (parser_reader source_text)
                   ignore_parse_error HOLSourceParser.initialScope
    val report = String.concatWith "\n" (theorem_report_lines result) ^ "\n"
  in
    HolbuildTheoryCheckpoints.discover_from_report {source = source_text, report = report}
  end

end
