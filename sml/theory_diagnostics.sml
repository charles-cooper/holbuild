structure HolbuildTheoryDiagnostics =
struct

fun read_text path =
  let
    val input = TextIO.openIn path
    fun close () = TextIO.closeIn input handle _ => ()
    fun loop acc =
      case TextIO.inputLine input of
          NONE => String.concat (rev acc)
        | SOME line => loop (line :: acc)
  in
    (loop [] before close ()) handle e => (close (); raise e)
  end

fun first_some f values =
  case values of
      [] => NONE
    | x :: xs =>
        case f x of
            SOME y => SOME y
          | NONE => first_some f xs

fun find_substring needle haystack =
  let
    val n = size needle
    val h = size haystack
    fun at i = i + n <= h andalso String.substring(haystack, i, n) = needle
    fun loop i = if i + n > h then NONE else if at i then SOME i else loop (i + 1)
  in
    if n = 0 then NONE else loop 0
  end

fun line_number_at text offset =
  let
    val limit = Int.min(offset, size text)
    fun loop i line =
      if i >= limit then line
      else if String.sub(text, i) = #"\n" then loop (i + 1) (line + 1)
      else loop (i + 1) line
  in
    loop 0 1
  end

fun column_number_at text offset =
  let
    val limit = Int.min(offset, size text)
    fun loop i col =
      if i >= limit then col
      else if String.sub(text, i) = #"\n" then loop (i + 1) 1
      else loop (i + 1) (col + 1)
  in
    loop 0 1
  end

fun source_lines source_text = String.fields (fn c => c = #"\n") source_text

fun nth_line lines n = List.nth(lines, n - 1) handle _ => ""

fun repeat_text text n = String.concat (List.tabulate(Int.max(0, n), fn _ => text))
fun spaces n = repeat_text " " n

fun source_context_text source_text line =
  let
    val lines = source_lines source_text
    val start = Int.max(1, line - 2)
    val stop = Int.min(length lines, line + 2)
    val width = size (Int.toString stop)
    fun padded n = spaces (width - size (Int.toString n)) ^ Int.toString n
    fun row n =
      String.concat [if n = line then "> " else "  ", padded n, " | ", nth_line lines n, "\n"]
    fun loop n acc = if n > stop then rev acc else loop (n + 1) (row n :: acc)
  in
    String.concat (loop start [])
  end

fun source_context_text_span source_text {start_offset, end_offset} =
  let
    val lines = source_lines source_text
    val start_line = line_number_at source_text start_offset
    val start_col = column_number_at source_text start_offset
    val end_line = line_number_at source_text (Int.max(start_offset, end_offset - 1))
    val start = Int.max(1, start_line - 2)
    val stop = Int.min(length lines, end_line + 2)
    val width = size (Int.toString stop)
    fun padded n = spaces (width - size (Int.toString n)) ^ Int.toString n
    fun underline n =
      if start_line <> end_line orelse n <> start_line then ""
      else
        let val caret_count = Int.max(1, end_offset - start_offset)
        in String.concat ["  ", spaces width, " | ", spaces (start_col - 1), repeat_text "^" caret_count, "\n"] end
    fun row n =
      String.concat [if n >= start_line andalso n <= end_line then "> " else "  ",
                     padded n, " | ", nth_line lines n, "\n",
                     underline n]
    fun loop n acc = if n > stop then rev acc else loop (n + 1) (row n :: acc)
  in
    String.concat (loop start [])
  end

fun parse_error source_path source_text _ (start, _) msg =
  let
    val line = line_number_at source_text start
    val col = column_number_at source_text start
  in
    raise Fail
      (String.concat
         ["HOL source parse error: ", msg, "\n",
          "source: ", source_path, ":", Int.toString line, ":", Int.toString col, "\n",
          source_context_text source_text line])
  end

fun take_static_error_block [] acc = rev acc
  | take_static_error_block (line :: rest) acc =
      if String.isPrefix "Uncaught exception" line then rev acc
      else take_static_error_block rest (line :: acc)

fun find_static_error_block [] = NONE
  | find_static_error_block (line :: rest) =
      if Option.isSome (find_substring ": error: " line) then
        SOME (take_static_error_block rest [line])
      else find_static_error_block rest

fun parse_decimal_prefix text start =
  let
    val n = size text
    fun scan i =
      if i < n andalso Char.isDigit (String.sub(text, i)) then scan (i + 1) else i
    val stop = scan start
  in
    if stop = start then NONE
    else Int.fromString (String.substring(text, start, stop - start))
  end

fun marker_line_after marker text =
  case find_substring marker text of
      NONE => NONE
    | SOME i => parse_decimal_prefix text (i + size marker)

fun trim text =
  let
    val n = size text
    fun left i = if i >= n orelse not (Char.isSpace (String.sub(text, i))) then i else left (i + 1)
    fun right i = if i < 0 orelse not (Char.isSpace (String.sub(text, i))) then i else right (i - 1)
    val l = left 0
    val r = right (n - 1)
  in
    if r < l then "" else String.substring(text, l, r - l + 1)
  end

fun find_line_number text wanted =
  let
    val needle = trim wanted
    fun loop _ [] = NONE
      | loop n (line :: rest) =
          if needle <> "" andalso trim line = needle then SOME n else loop (n + 1) rest
  in
    loop 1 (source_lines text)
  end

fun split_first_char ch text =
  case find_substring (String.str ch) text of
      NONE => NONE
    | SOME i => SOME (String.substring(text, 0, i), String.extract(text, i + 1, NONE))

fun parse_static_error_location line =
  case find_substring ": error: " line of
      NONE => NONE
    | SOME marker =>
        let
          val before_error = String.substring(line, 0, marker)
          fun loop path rest last =
            case split_first_char #":" rest of
                NONE => Option.map (fn line_no => {path = path, line = line_no}) last
              | SOME (piece, after) =>
                  loop (path ^ ":" ^ piece) after (Int.fromString after)
        in
          case split_first_char #":" before_error of
              NONE => NONE
            | SOME (path, rest) => loop path rest (Int.fromString rest)
        end

fun source_line_from_staged_error source_text block =
  case block of
      [] => NONE
    | first :: _ =>
        case parse_static_error_location first of
            NONE => NONE
          | SOME {path, line} =>
              (find_line_number source_text (nth_line (source_lines (read_text path)) line)
               handle _ => NONE)

fun source_line_from_loc_marker source_text block =
  case marker_line_after "(*#loc " (String.concatWith "\n" block) of
      SOME line => if line <= length (source_lines source_text) then SOME line else NONE
    | NONE => NONE

fun static_error_source_line source_text block =
  case source_line_from_staged_error source_text block of
      SOME line => SOME line
    | NONE => source_line_from_loc_marker source_text block

fun static_error_summary source_path source_text lines =
  case find_static_error_block lines of
      NONE => NONE
    | SOME block =>
        let
          val source_context =
            case static_error_source_line source_text block of
                NONE => ""
              | SOME line =>
                  String.concat
                    ["source: ", source_path, ":", Int.toString line, "\n",
                     source_context_text source_text line]
        in
          SOME (String.concat
            ["static error:\n",
             String.concat (map (fn line => line ^ "\n") block),
             source_context])
        end

fun drop_prefix prefix text =
  if String.isPrefix prefix text then SOME (String.extract(text, size prefix, NONE)) else NONE

fun strip_trailing_paren text =
  if size text > 0 andalso String.sub(text, size text - 1) = #")" then
    String.substring(text, 0, size text - 1)
  else text

fun select_then1_source_probes label =
  case drop_prefix "Q.SELECT_GOALS_LT_THEN1 " label of
      NONE => []
    | SOME rest =>
        case find_substring "] (" rest of
            NONE => []
          | SOME split =>
              let
                val pattern = String.substring(rest, 0, split + 1)
                val body = strip_trailing_paren (String.extract(rest, split + 3, NONE))
              in
                [pattern, body]
              end

fun wrapped_source_probe prefix label =
  case drop_prefix prefix label of
      NONE => NONE
    | SOME rest => if size rest > 0 andalso String.sub(rest, size rest - 1) = #")" then
                     SOME (String.substring(rest, 0, size rest - 1))
                   else NONE

fun source_location_probes label =
  label ::
  select_then1_source_probes label @
  (case drop_prefix "sg " label of NONE => [] | SOME term => [term]) @
  (case wrapped_source_probe "Tactical.REVERSE (" label of NONE => [] | SOME inner => [inner])

fun proof_unit_label (checkpoint : HolbuildTheoryCheckpoints.checkpoint) =
  if #kind checkpoint = "resume" then "resume" else "theorem"

fun source_span_text source_path source_text start_offset end_offset =
  let
    val start_line = line_number_at source_text start_offset
    val start_col = column_number_at source_text start_offset
    val last_offset = Int.max(start_offset, end_offset - 1)
    val end_line = line_number_at source_text last_offset
    val end_col = column_number_at source_text last_offset + 1
    val range =
      if start_line = end_line then
        String.concat [Int.toString start_line, ":", Int.toString start_col, "-", Int.toString end_col]
      else
        String.concat [Int.toString start_line, ":", Int.toString start_col, "-",
                       Int.toString end_line, ":", Int.toString end_col]
  in
    String.concat ["source: ", source_path, ":", range, "\n",
                   source_context_text_span source_text {start_offset = start_offset, end_offset = end_offset}]
  end

fun checkpoint_source_summary source_path source_text (checkpoint : HolbuildTheoryCheckpoints.checkpoint) label {offset, width} =
  let
    val theorem_line = line_number_at source_text (#theorem_start checkpoint)
    val proof_line = line_number_at source_text (#tactic_start checkpoint)
    val end_offset = Int.min(size source_text, offset + Int.max(1, width))
  in
    String.concat
      [proof_unit_label checkpoint, ": ", #name checkpoint, " (line ", Int.toString theorem_line, ")\n",
       "proof: line ", Int.toString proof_line, "\n",
       "fragment: ", label, "\n",
       source_span_text source_path source_text offset end_offset]
  end

fun failed_fragment_source_summary source_path source_text checkpoints label =
  let
    fun locate_with_probe (checkpoint : HolbuildTheoryCheckpoints.checkpoint) probe =
      Option.map
        (fn relative => {checkpoint = checkpoint,
                         span = {offset = #tactic_start checkpoint + relative,
                                 width = size probe}})
        (find_substring probe (#tactic_text checkpoint))
    fun locate checkpoint = first_some (locate_with_probe checkpoint) (source_location_probes label)
  in
    Option.map
      (fn {checkpoint, span} => checkpoint_source_summary source_path source_text checkpoint label span)
      (first_some locate checkpoints)
  end

fun quoted_after marker line =
  case find_substring marker line of
      NONE => NONE
    | SOME start =>
        let
          val quote_start = start + size marker
          fun scan i =
            if i >= size line then NONE
            else if String.sub(line, i) = #"\"" then
              SOME (String.substring(line, quote_start, i - quote_start))
            else scan (i + 1)
        in
          scan quote_start
        end

val failed_theorem_prefix = "holbuild failed theorem: "

fun failed_theorem_marker line =
  if String.isPrefix failed_theorem_prefix line then
    SOME (String.extract(line, size failed_theorem_prefix, NONE))
  else NONE

fun find_failed_theorem_name lines =
  case first_some failed_theorem_marker lines of
      SOME name => SOME name
    | NONE => first_some (quoted_after "Failed to prove theorem \"") lines

fun failed_theorem_source_summary source_path source_text checkpoints label theorem_name failed_end =
  let
    fun locate_with_probe (checkpoint : HolbuildTheoryCheckpoints.checkpoint) probe =
      Option.map
        (fn relative => {offset = #tactic_start checkpoint + relative, width = size probe})
        (find_substring probe (#tactic_text checkpoint))
    fun locate checkpoint = first_some (locate_with_probe checkpoint) (source_location_probes label)
    fun end_span checkpoint end_pos =
      let
        val relative = Int.max(0, Int.min(size (#tactic_text checkpoint) - 1, end_pos - 1))
      in
        {offset = #tactic_start checkpoint + relative, width = 1}
      end
  in
    case List.find (fn (checkpoint : HolbuildTheoryCheckpoints.checkpoint) => #name checkpoint = theorem_name) checkpoints of
        NONE => NONE
      | SOME checkpoint =>
          SOME (checkpoint_source_summary source_path source_text checkpoint label
                  (case locate checkpoint of
                       SOME span => span
                     | NONE =>
                         case failed_end of
                             SOME end_pos => end_span checkpoint end_pos
                           | NONE => {offset = #tactic_start checkpoint, width = 1}))
  end

val goal_state_limit = 4096
val goal_state_start_marker = "holbuild top goal:"
val goal_state_end_marker = "holbuild end top goal"
val failed_fragment_prefix = "holbuild goal state at failed fragment: "
val failed_fragment_end_prefix = "holbuild failed fragment end: "

fun read_prefix path limit =
  let
    val input = TextIO.openIn path
    fun close () = TextIO.closeIn input handle _ => ()
    fun loop remaining acc =
      if remaining <= 0 then String.concat (rev acc)
      else
        let val chunk = TextIO.inputN(input, Int.min(4096, remaining))
        in
          if size chunk = 0 then String.concat (rev acc)
          else loop (remaining - size chunk) (chunk :: acc)
        end
  in
    (loop limit [] before close ()) handle e => (close (); raise e)
  end

fun skip_line_break text offset =
  if offset < size text andalso String.sub(text, offset) = #"\n" then offset + 1
  else offset

fun top_goal_state_from_text text =
  case find_substring goal_state_start_marker text of
      NONE => NONE
    | SOME start =>
        let val content_start = skip_line_break text (start + size goal_state_start_marker)
        in
          case find_substring goal_state_end_marker (String.extract(text, content_start, NONE)) of
              NONE => NONE
            | SOME rel_end => SOME (String.substring(text, content_start, rel_end))
        end

fun read_top_goal_state path = top_goal_state_from_text (read_prefix path 65536)

fun find_failed_fragment_label lines =
  first_some
    (fn line =>
        if String.isPrefix failed_fragment_prefix line then
          SOME (String.extract(line, size failed_fragment_prefix, NONE))
        else NONE)
    lines

fun find_failed_fragment_end lines =
  first_some
    (fn line =>
        if String.isPrefix failed_fragment_end_prefix line then
          Int.fromString (String.extract(line, size failed_fragment_end_prefix, NONE))
        else NONE)
    lines

fun truncate_goal_state text =
  if size text <= goal_state_limit then (false, text)
  else (true, String.substring(text, 0, goal_state_limit))

fun goal_state_summary text =
  let
    val (truncated, preview) = truncate_goal_state text
    val truncation_line =
      if truncated then
        String.concat ["top goal exceeded 4 KiB; showing first ",
                       Int.toString (size preview), " bytes; full top goal is in the instrumented log above\n"]
      else ""
  in
    String.concat
      ["top goal at failed fragment:\n",
       truncation_line,
       preview,
       if size preview = 0 orelse String.sub(preview, size preview - 1) <> #"\n" then "\n" else ""]
  end

fun summarize_goal_state path =
  Option.map goal_state_summary (read_top_goal_state path)
  handle _ => NONE

fun child_failure_line line =
  String.isPrefix "Couldn't load HOL base-state" line orelse
  String.isPrefix "HOL message:" line orelse
  String.isPrefix "error in " line orelse
  String.isPrefix "Uncaught exception" line orelse
  Option.isSome (find_substring "Exception raised" line)

fun take_n n lines acc =
  if n <= 0 then rev acc
  else
    case lines of
        [] => rev acc
      | line :: rest => take_n (n - 1) rest (line :: acc)

fun child_failure_excerpt lines =
  case lines of
      [] => NONE
    | line :: rest =>
        if child_failure_line line then SOME (take_n 12 (line :: rest) [])
        else child_failure_excerpt rest

fun child_failure_summary path =
  let val lines = String.fields (fn c => c = #"\n") (read_text path)
  in
    case child_failure_excerpt lines of
        NONE => NONE
      | SOME excerpt =>
          SOME ("child failure:\n" ^ String.concat (map (fn line => line ^ "\n") excerpt))
  end
  handle _ => NONE

fun summarize_failed_fragment_source source_path source_text checkpoints path =
  let
    val lines = String.fields (fn c => c = #"\n") (read_text path)
    val label = find_failed_fragment_label lines
    val failed_end = find_failed_fragment_end lines
  in
    case (label, find_failed_theorem_name lines) of
        (SOME label', SOME theorem_name) =>
          (case failed_theorem_source_summary source_path source_text checkpoints label' theorem_name failed_end of
               SOME summary => SOME summary
             | NONE => failed_fragment_source_summary source_path source_text checkpoints label')
      | _ => Option.mapPartial (failed_fragment_source_summary source_path source_text checkpoints) label
  end
  handle _ => NONE

fun field_after key line =
  let
    val needle = key ^ "="
    val n = size line
    val m = size needle
    fun scan i =
      if i + m > n then NONE
      else if String.substring(line, i, m) = needle then
        let
          val start = i + m
          fun stop j = if j >= n orelse Char.isSpace (String.sub(line, j)) then j else stop (j + 1)
        in
          SOME (String.substring(line, start, stop start - start))
        end
      else scan (i + 1)
  in
    scan 0
  end

fun failed_trace_theorem lines =
  case List.filter (fn line => String.isPrefix "holbuild goalfrag after " line andalso
                               String.isSubstring "status=failed" line) lines of
      [] => NONE
    | failed => field_after "theorem" (List.last failed)

fun summarize_goalfrag_trace path =
  let
    val lines = String.fields (fn c => c = #"\n") (read_text path)
    val trace_lines = List.filter (String.isPrefix "holbuild goalfrag ") lines
    val focused =
      case failed_trace_theorem trace_lines of
          NONE => trace_lines
        | SOME theorem => List.filter (fn line => field_after "theorem" line = SOME theorem) trace_lines
  in
    if null focused then NONE
    else SOME ("holbuild goalfrag trace:\n" ^ String.concat (map (fn line => line ^ "\n") focused))
  end
  handle _ => NONE

end
