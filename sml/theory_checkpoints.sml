structure HolbuildTheoryCheckpoints =
struct

type boundary = {name : string, safe_name : string, call_start : int,
                 boundary : int, prefix_hash : string}
type checkpoint = {name : string, safe_name : string, call_start : int,
                   boundary : int, prefix_hash : string,
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

fun skip_string text i =
  let
    val n = size text
    fun loop j =
      if j >= n then n
      else
        case String.sub(text, j) of
            #"\\" => loop (Int.min(n, j + 2))
          | #"\"" => j + 1
          | _ => loop (j + 1)
  in
    loop (i + 1)
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

fun parse_string text i =
  let
    val n = size text
    fun loop j acc =
      if j >= n then NONE
      else
        case String.sub(text, j) of
            #"\\" =>
              if j + 1 < n then loop (j + 2) (String.str (String.sub(text, j + 1)) :: acc)
              else NONE
          | #"\"" => SOME (String.concat (rev acc), j + 1)
          | c => loop (j + 1) (String.str c :: acc)
  in
    if i < n andalso String.sub(text, i) = #"\"" then loop (i + 1) [] else NONE
  end

fun matching_rparen text open_paren =
  let
    val n = size text
    fun loop i depth =
      if i >= n then NONE
      else if starts_with text i "(*" then loop (skip_comment text i) depth
      else
        case String.sub(text, i) of
            #"\"" => loop (skip_string text i) depth
          | #"(" => loop (i + 1) (depth + 1)
          | #")" => if depth = 1 then SOME (i + 1) else loop (i + 1) (depth - 1)
          | _ => loop (i + 1) depth
  in
    loop (open_paren + 1) 1
  end

fun statement_boundary text i =
  let val j = skip_ws_comments text i
  in if j < size text andalso String.sub(text, j) = #";" then j + 1 else i end

fun identifier_at text i ident =
  let
    val n = size text
    val m = size ident
    val before_ok = i = 0 orelse
                    (not (is_ident (String.sub(text, i - 1))) andalso
                     String.sub(text, i - 1) <> #".")
    val after_ok = i + m >= n orelse not (is_ident (String.sub(text, i + m)))
  in
    before_ok andalso after_ok andalso starts_with text i ident
  end

fun parse_store_thm text i =
  let
    val after_ident = i + size "store_thm"
    val open_i = skip_ws_comments text after_ident
    val first_arg = skip_ws_comments text (open_i + 1)
  in
    if open_i >= size text orelse String.sub(text, open_i) <> #"(" then NONE
    else
      case parse_string text first_arg of
          NONE => NONE
        | SOME (name, _) =>
            case matching_rparen text open_i of
                NONE => NONE
              | SOME close_i => SOME {name = name, call_start = i,
                                       boundary = statement_boundary text close_i}
  end

fun safe_name name =
  let
    fun safe c = if is_ident c then c else #"_"
    val s = String.map safe name
  in
    if s = "" then "unnamed" else s
  end

fun prefix_hash text boundary =
  HolbuildToolchain.hash_text (String.substring(text, 0, boundary))

fun discover text : boundary list =
  let
    val n = size text
    fun scan i acc =
      if i >= n then rev acc
      else if starts_with text i "(*" then scan (skip_comment text i) acc
      else
        case String.sub(text, i) of
            #"\"" => scan (skip_string text i) acc
          | _ =>
              if identifier_at text i "store_thm" then
                case parse_store_thm text i of
                    SOME {name, call_start, boundary} =>
                      scan boundary ({name = name, safe_name = safe_name name,
                                      call_start = call_start, boundary = boundary,
                                      prefix_hash = prefix_hash text boundary} :: acc)
                  | NONE => scan (i + 1) acc
              else scan (i + 1) acc
  in
    scan 0 []
  end

fun save_line output =
  "val _ = PolyML.SaveState.saveChild(" ^
  HolbuildToolchain.sml_string output ^
  ", length (PolyML.SaveState.showHierarchy()));\n"

fun checkpoint_pair {name, end_of_proof_path, ...} =
  "(" ^ HolbuildToolchain.sml_string name ^ ", " ^
  HolbuildToolchain.sml_string end_of_proof_path ^ ")"

fun end_of_proof_prelude checkpoints =
  if null checkpoints then ""
  else
    String.concat
      ["val holbuild_end_of_proof_checkpoints = [",
       String.concatWith ", " (map checkpoint_pair checkpoints),
       "];\n",
       "fun holbuild_save_end_of_proof name =\n",
       "  case List.find (fn (n, _) => n = name) holbuild_end_of_proof_checkpoints of\n",
       "      SOME (_, path) => PolyML.SaveState.saveChild(path, length (PolyML.SaveState.showHierarchy()))\n",
       "    | NONE => ();\n",
       "fun holbuild_store_thm (name, tm, tac) =\n",
       "  let\n",
       "    val th = Tactical.prove(tm, tac)\n",
       "    val _ = holbuild_save_end_of_proof name\n",
       "  in\n",
       "    boolLib.save_thm(name, th)\n",
       "  end;\n"]

fun instrument ({source, start_offset, checkpoints} :
                {source : string, start_offset : int, checkpoints : checkpoint list}) =
  let
    val n = size source
    val store_thm_len = size "store_thm"
    fun slice i j = String.substring(source, i, j - i)
    fun loop pos entries acc =
      case entries of
          [] => String.concat (rev (slice pos n :: acc))
        | ({call_start, boundary, context_path, ...} : checkpoint) :: rest =>
            if boundary <= start_offset then loop pos rest acc
            else
              loop boundary rest
                (save_line context_path ::
                 slice (call_start + store_thm_len) boundary ::
                 "holbuild_store_thm" ::
                 slice pos call_start ::
                 acc)
  in
    end_of_proof_prelude (List.filter (fn {boundary, ...} => boundary > start_offset) checkpoints) ^
    loop start_offset checkpoints []
  end

end
