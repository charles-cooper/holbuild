structure HolbuildHash =
struct

fun quote s =
  "'" ^ String.translate (fn #"'" => "'\\''" | c => str c) s ^ "'"

fun is_hex c = Char.isDigit c orelse
               (#"a" <= c andalso c <= #"f") orelse
               (#"A" <= c andalso c <= #"F")

fun valid_sha1 text = size text = 40 andalso List.all is_hex (String.explode text)

fun read_all path =
  let val input = TextIO.openIn path
  in TextIO.inputAll input before TextIO.closeIn input
     handle e => (TextIO.closeIn input; raise e)
  end

fun first_token text =
  case String.tokens Char.isSpace text of
      token :: _ => SOME token
    | [] => NONE

fun remove_quietly path = OS.FileSys.remove path handle OS.SysErr _ => ()

fun external_sha1 path =
  let
    val out = OS.FileSys.tmpName ()
    val command = "sha1sum " ^ quote path ^ " > " ^ quote out
    val status = OS.Process.system command
    val result =
      if OS.Process.isSuccess status then first_token (read_all out)
      else NONE
    val _ = remove_quietly out
  in
    case result of
        SOME hash => if valid_sha1 hash then SOME (String.map Char.toLower hash) else NONE
      | NONE => NONE
  end
  handle _ => NONE

fun large_file path =
  (Position.toInt (OS.FileSys.fileSize path) >= 1048576)
  handle Overflow => true
       | OS.SysErr _ => false

fun file_sha1 path =
  if large_file path then
    case external_sha1 path of
        SOME hash => hash
      | NONE => SHA1_ML.sha1_file {filename = path}
  else SHA1_ML.sha1_file {filename = path}

end
