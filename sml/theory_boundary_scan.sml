structure HolbuildTheoryBoundaryScan =
struct

fun is_ident c = Char.isAlphaNum c orelse c = #"_" orelse c = #"'"

fun starts_with text i needle =
  let val n = size text
      val m = size needle
  in i + m <= n andalso String.substring(text, i, m) = needle end

fun char_at text i = if i < size text then SOME (String.sub(text, i)) else NONE

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
    fun loop j escaped =
      if j >= n then n
      else
        case String.sub(text, j) of
            #"\\" => loop (j + 1) (not escaped)
          | #"\"" => if escaped then loop (j + 1) false else j + 1
          | _ => loop (j + 1) false
  in
    loop (i + 1) false
  end

val unicode_left_quote = "\226\128\152"
val unicode_right_quote = "\226\128\153"
val unicode_left_double_quote = "\226\128\156"
val unicode_right_double_quote = "\226\128\157"

fun skip_until_token text i token =
  let
    val n = size text
    val m = size token
    fun loop j =
      if j >= n then n
      else if j + m <= n andalso String.substring(text, j, m) = token then j + m
      else loop (j + 1)
  in
    loop i
  end

fun skip_until_char text i ch =
  let
    val n = size text
    fun loop j =
      if j >= n then n
      else if String.sub(text, j) = ch then j + 1
      else loop (j + 1)
  in
    loop i
  end

fun skip_quote text i =
  if starts_with text i "``" then SOME (skip_until_token text (i + 2) "``")
  else if char_at text i = SOME #"`" then SOME (skip_until_char text (i + 1) #"`")
  else if starts_with text i unicode_left_quote then
    SOME (skip_until_token text (i + size unicode_left_quote) unicode_right_quote)
  else if starts_with text i unicode_left_double_quote then
    SOME (skip_until_token text (i + size unicode_left_double_quote) unicode_right_double_quote)
  else NONE

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

fun keyword_at text i kw =
  let
    val before_ok = i = 0 orelse not (is_ident (String.sub(text, i - 1)))
    val after = i + size kw
    val after_ok = after >= size text orelse not (is_ident (String.sub(text, after)))
  in
    before_ok andalso after_ok andalso starts_with text i kw
  end

fun find_keyword text kws i =
  let
    val n = size text
    fun at_kw j = List.find (fn kw => keyword_at text j kw) kws
    fun loop j =
      if j >= n then NONE
      else if starts_with text j "(*" then loop (skip_comment text j)
      else
        case skip_quote text j of
            SOME next => loop next
          | NONE =>
              case String.sub(text, j) of
                  #"\"" => loop (skip_string text j)
                | _ =>
                    case at_kw j of
                        SOME kw => SOME (j, kw)
                      | NONE => loop (j + 1)
  in
    loop i
  end

fun find_first_char text chars i =
  let
    val n = size text
    fun wanted c = List.exists (fn ch => ch = c) chars
    fun loop j =
      if j >= n then NONE
      else if starts_with text j "(*" then loop (skip_comment text j)
      else
        case skip_quote text j of
            SOME next => loop next
          | NONE =>
              case String.sub(text, j) of
                  #"\"" => loop (skip_string text j)
                | c => if wanted c then SOME (j, c) else loop (j + 1)
  in
    loop i
  end

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

fun take_name header =
  let
    val clean = trim header
    fun stop i =
      if i >= size clean then i
      else
        case String.sub(clean, i) of
            #"[" => i
          | c => if Char.isSpace c then i else stop (i + 1)
    val n = stop 0
  in
    if n = 0 then "unnamed" else String.substring(clean, 0, n)
  end

fun safe_name name =
  let
    fun safe c = if is_ident c then c else #"_"
    val s = String.map safe name
  in
    if s = "" then "unnamed" else s
  end

fun statement_boundary text i =
  let val j = skip_ws_comments text i
  in if j < size text andalso String.sub(text, j) = #";" then j + 1 else i end

fun skip_attrs text i =
  let
    val j = skip_ws_comments text i
    fun scan k depth =
      if k >= size text then k
      else
        case skip_quote text k of
            SOME next => scan next depth
          | NONE =>
              case String.sub(text, k) of
                  #"[" => scan (k + 1) (depth + 1)
                | #"]" => if depth = 1 then k + 1 else scan (k + 1) (depth - 1)
                | #"\"" => scan (skip_string text k) depth
                | _ => scan (k + 1) depth
  in
    if j < size text andalso String.sub(text, j) = #"[" then
      SOME (skip_ws_comments text (scan j 0))
    else NONE
  end

fun theorem_boundary text theorem_start kw =
  let
    val after_kw = theorem_start + size kw
    val delimiter = find_first_char text [#":", #"=", #";"] after_kw
  in
    case delimiter of
        SOME (colon_i, #":") =>
          (case find_keyword text ["Proof"] (colon_i + 1) of
               NONE => NONE
             | SOME (proof_i, _) =>
                 (case find_keyword text ["QED"] (proof_i + 5) of
                      NONE => NONE
                    | SOME (qed_i, _) =>
                        let
                          val name = take_name (String.substring(text, after_kw, colon_i - after_kw))
                          val attrs_start = skip_attrs text (proof_i + 5)
                          val has_attrs = Option.isSome attrs_start
                          val tactic_start = Option.getOpt(attrs_start, skip_ws_comments text (proof_i + 5))
                          val tactic_end = qed_i
                          val theorem_stop = qed_i + 3
                          val boundary = statement_boundary text theorem_stop
                          val prefix = String.substring(text, 0, boundary)
                        in
                          SOME
                            {name = name, safe_name = safe_name name,
                             theorem_start = theorem_start, theorem_stop = theorem_stop,
                             boundary = boundary, tactic_start = tactic_start,
                             tactic_end = tactic_end,
                             tactic_text = String.substring(text, tactic_start, tactic_end - tactic_start),
                             has_proof_attrs = has_attrs,
                             prefix_hash = HolbuildToolchain.hash_text prefix}
                        end))
      | _ => NONE
  end

fun scan text =
  let
    val n = size text
    fun loop i acc =
      if i >= n then rev acc
      else if starts_with text i "(*" then loop (skip_comment text i) acc
      else
        case skip_quote text i of
            SOME next => loop next acc
          | NONE =>
              case char_at text i of
                  SOME #"\"" => loop (skip_string text i) acc
                | _ =>
                    case List.find (keyword_at text i) ["Theorem", "Triviality"] of
                        NONE => loop (i + 1) acc
                      | SOME kw =>
                          (case theorem_boundary text i kw of
                               NONE => loop (i + size kw) acc
                             | SOME boundary => loop (#boundary boundary) (boundary :: acc))
  in
    loop 0 []
  end

end
