structure HolbuildDependencies =
struct

structure Path = OS.Path

exception Error of string

datatype token = Word of string | StringLit of string | Symbol of char

type t =
  { loads : string list,
    uses : string list,
    holdep_deps : string list }

fun has_suffix suffix s =
  let
    val n = size s
    val m = size suffix
  in
    n >= m andalso String.substring(s, n - m, m) = suffix
  end

fun is_word_start c = Char.isAlpha c orelse c = #"_"
fun is_word_char c = Char.isAlphaNum c orelse c = #"_" orelse c = #"'"

fun add_unique item items =
  if List.exists (fn x => x = item) items then items else item :: items

fun insert_sorted item items =
  case items of
      [] => [item]
    | x :: xs =>
        case String.compare(item, x) of
            LESS => item :: items
          | EQUAL => items
          | GREATER => x :: insert_sorted item xs

fun sort_unique items = List.foldl (fn (item, acc) => insert_sorted item acc) [] items

fun normalize_path path = Path.mkCanonical path handle Path.InvalidArc => path

fun absolute_path path = Path.isAbsolute path handle Path.InvalidArc => false

fun normalize_dep_path source_path dep =
  normalize_path
    (if absolute_path dep then dep else Path.concat(Path.dir source_path, dep))

fun holdep_deps includes path =
  let
    val {deps, ...} = Holdep.main {assumes = [], includes = includes,
                                   diag = fn _ => (), fname = path}
  in
    sort_unique (map (normalize_dep_path path) deps)
  end
  handle Holdep.Holdep_Error msg =>
    raise Error ("Holdep failed for " ^ path ^ ": " ^ msg)
       | Holdep_tokens.LEX_ERROR msg =>
    raise Error ("Holdep failed for " ^ path ^ ": " ^ msg)

fun read_all path =
  let
    val input = TextIO.openIn path
      handle e => raise Error ("could not read " ^ path ^ ": " ^ General.exnMessage e)
  in
    TextIO.inputAll input before TextIO.closeIn input
    handle e => (TextIO.closeIn input; raise e)
  end

fun scan_string text start =
  let
    val n = size text
    fun sub i = String.sub(text, i)
    fun loop i acc =
      if i >= n then (String.implode (rev acc), i)
      else
        case sub i of
            #"\"" => (String.implode (rev acc), i + 1)
          | #"\\" =>
              if i + 1 < n then loop (i + 2) (sub (i + 1) :: acc)
              else loop (i + 1) acc
          | c => loop (i + 1) (c :: acc)
  in
    loop start []
  end

fun skip_comment text start =
  let
    val n = size text
    fun sub i = String.sub(text, i)
    fun opens i = i + 1 < n andalso sub i = #"(" andalso sub (i + 1) = #"*"
    fun closes i = i + 1 < n andalso sub i = #"*" andalso sub (i + 1) = #")"
    fun loop depth i =
      if i >= n then i
      else if opens i then loop (depth + 1) (i + 2)
      else if closes i then
        if depth = 1 then i + 2 else loop (depth - 1) (i + 2)
      else loop depth (i + 1)
  in
    loop 1 start
  end

fun scan_word text start =
  let
    val n = size text
    fun loop i =
      if i < n andalso is_word_char (String.sub(text, i)) then loop (i + 1)
      else i
    val stop = loop start
  in
    (String.substring(text, start, stop - start), stop)
  end

fun tokenize text =
  let
    val n = size text
    fun sub i = String.sub(text, i)
    fun opens_comment i = i + 1 < n andalso sub i = #"(" andalso sub (i + 1) = #"*"
    fun loop i acc =
      if i >= n then rev acc
      else if Char.isSpace (sub i) then loop (i + 1) acc
      else if opens_comment i then loop (skip_comment text (i + 2)) acc
      else if sub i = #"\"" then
        let val (s, next) = scan_string text (i + 1)
        in loop next (StringLit s :: acc) end
      else if is_word_start (sub i) then
        let val (word, next) = scan_word text i
        in loop next (Word word :: acc) end
      else loop (i + 1) (Symbol (sub i) :: acc)
  in
    loop 0 []
  end

fun theory_name s = has_suffix "Theory" s andalso size s > size "Theory"

fun extract_string_args keyword tokens =
  let
    fun loop rest acc =
      case rest of
          Word word :: StringLit value :: xs =>
            if word = keyword then loop xs (add_unique value acc)
            else loop (StringLit value :: xs) acc
        | _ :: xs => loop xs acc
        | [] => acc
  in
    loop tokens []
  end

fun extract {includes} path =
  let
    val tokens = tokenize (read_all path)
    val loads = extract_string_args "load" tokens
    val uses = extract_string_args "use" tokens
  in
    {loads = sort_unique loads, uses = sort_unique uses,
     holdep_deps = holdep_deps includes path}
  end

fun describe ({loads, uses, holdep_deps} : t) =
  let
    fun line label values =
      case values of
          [] => ()
        | _ => print ("  " ^ label ^ ": " ^ String.concatWith ", " values ^ "\n")
  in
    line "loads" loads;
    line "uses" uses;
    line "Holdep deps" holdep_deps
  end

end
