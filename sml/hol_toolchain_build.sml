structure HolbuildHolToolchainBuild =
struct

structure Path = OS.Path
structure FS = OS.FileSys

exception Error of string

fun die msg = raise Error msg

fun quote s = HolbuildHash.quote s

fun path_exists path = FS.access(path, []) handle OS.SysErr _ => false
fun readable path = FS.access(path, [FS.A_READ]) handle OS.SysErr _ => false
fun executable path = FS.access(path, [FS.A_READ, FS.A_EXEC]) handle OS.SysErr _ => false

fun command_output command =
  let
    val tmp = FS.tmpName ()
    val status = OS.Process.system (command ^ " > " ^ quote tmp ^ " 2>&1")
    val input = TextIO.openIn tmp
    val text = TextIO.inputAll input before TextIO.closeIn input
    val _ = FS.remove tmp handle OS.SysErr _ => ()
  in
    if OS.Process.isSuccess status then text
    else die ("command failed: " ^ command ^ "\n" ^ text)
  end
  handle e as Error _ => raise e
       | e => die ("command failed: " ^ command ^ ": " ^ General.exnMessage e)

fun run_in_dir dir command =
  let val status = OS.Process.system ("cd " ^ quote dir ^ " && " ^ command)
  in
    if OS.Process.isSuccess status then ()
    else die ("HOL toolchain build command failed in " ^ dir ^ ": " ^ command)
  end

fun trim text =
  let
    fun ws c = Char.isSpace c
    val n = size text
    fun left i = if i < n andalso ws (String.sub(text, i)) then left (i + 1) else i
    fun right i = if i >= 0 andalso ws (String.sub(text, i)) then right (i - 1) else i
    val l = left 0
    val r = right (n - 1)
  in
    if r < l then "" else String.substring(text, l, r - l + 1)
  end

fun hol_file holdir rel = Path.concat(holdir, rel)

fun is_built holdir =
  executable (hol_file holdir "bin/hol") andalso
  executable (hol_file holdir "bin/build") andalso
  readable (hol_file holdir "bin/hol.state")

fun dirty_status holdir =
  trim (command_output ("git -C " ^ quote holdir ^ " status --porcelain --ignored=no"))

fun require_clean holdir =
  let val status = dirty_status holdir
  in
    if status = "" then ()
    else die ("HOL checkout is dirty: " ^ holdir ^ "\n" ^ status)
  end

fun poly_command () =
  quote (Option.getOpt(OS.Process.getEnv "HOLBUILD_POLY", "poly"))

fun ensure_built holdir =
  let
    val _ = if path_exists holdir then () else die ("HOL checkout not found: " ^ holdir)
    val _ = require_clean holdir
  in
    if is_built holdir then ()
    else
      (run_in_dir holdir (poly_command () ^ " --script tools/smart-configure.sml");
       run_in_dir holdir "bin/build";
       if is_built holdir then ()
       else die ("HOL toolchain build did not produce bin/hol, bin/build, and bin/hol.state in " ^ holdir);
       require_clean holdir)
  end

end
