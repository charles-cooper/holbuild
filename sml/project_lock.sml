structure HolbuildProjectLock =
struct

structure Path = OS.Path
structure FS = OS.FileSys

exception Error of string

datatype project_lock = ProjectLock of {fd : Posix.IO.file_desc, lock : string}

fun remove_file path = FS.remove path handle OS.SysErr _ => ()

fun ensure_dir path =
  if path = "" orelse path = "." then ()
  else if FS.access(path, []) handle OS.SysErr _ => false then ()
  else (ensure_dir (Path.dir path); FS.mkDir path handle OS.SysErr _ => ())

fun ensure_parent path = ensure_dir (Path.dir path)

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

fun write_text path text =
  let
    val output = TextIO.openOut path
    fun close () = TextIO.closeOut output handle _ => ()
  in
    (TextIO.output(output, text); close ())
    handle e => (close (); raise e)
  end

fun remove_tree path =
  ignore (OS.Process.system ("rm -rf " ^ HolbuildToolchain.quote path))

fun project_lock_path (project : HolbuildProject.t) =
  Path.concat(Path.concat(#root project, ".holbuild/locks"), "project.lock")

fun project_lock_owner_path lock = lock ^ ".owner"

fun env_default name default = Option.getOpt(OS.Process.getEnv name, default)

fun pid_text pid =
  LargeInt.toString (SysWord.toLargeInt (Posix.Process.pidToWord pid))

fun current_pid_text () = pid_text (Posix.ProcEnv.getpid ())

fun trim_trailing_newline text =
  if size text > 0 andalso String.sub(text, size text - 1) = #"\n" then
    String.substring(text, 0, size text - 1)
  else text

fun current_host () =
  trim_trailing_newline (read_text "/proc/sys/kernel/hostname")
  handle _ => env_default "HOSTNAME" "unknown"

fun current_pid_namespace () = FS.readLink "/proc/self/ns/pid" handle _ => "unknown"
fun current_boot_id () = trim_trailing_newline (read_text "/proc/sys/kernel/random/boot_id") handle _ => "unknown"

fun proc_starttime pid =
  let
    val stat = read_text (Path.concat(Path.concat("/proc", pid), "stat"))
    val chars = String.explode stat
    fun after_comm [] = NONE
      | after_comm (#")" :: #" " :: rest) = SOME (String.implode rest)
      | after_comm (_ :: rest) = after_comm rest
    val rest =
      case after_comm chars of
          SOME text => text
        | NONE => raise Error "could not parse proc stat"
    val fields = String.tokens Char.isSpace rest
  in
    List.nth(fields, 19)
  end
  handle _ => "unknown"

fun project_lock_owner command =
  String.concatWith "\n"
    ["holbuild-project-lock-v2",
     "command=" ^ command,
     "pid=" ^ current_pid_text (),
     "pid_ns=" ^ current_pid_namespace (),
     "starttime=" ^ proc_starttime "self",
     "boot_id=" ^ current_boot_id (),
     "cwd=" ^ FS.getDir (),
     "host=" ^ current_host (),
     "started=" ^ Time.toString (Time.now ())] ^ "\n"

fun current_lock_owner lock =
  SOME (read_text (project_lock_owner_path lock)) handle _ => NONE

fun owner_lines owner = String.tokens (fn c => c = #"\n") owner

fun owner_value key owner =
  let
    val prefix = key ^ "="
    fun value line =
      if String.isPrefix prefix line then SOME (String.extract(line, size prefix, NONE))
      else NONE
    fun first lines =
      case lines of
          [] => NONE
        | line :: rest =>
            case value line of
                SOME v => SOME v
              | NONE => first rest
  in
    first (owner_lines owner)
  end

fun owner_summary owner =
  let
    fun field name =
      case owner_value name owner of
          SOME value => name ^ "=" ^ value
        | NONE => name ^ "=unknown"
  in
    String.concatWith " " [field "command", field "pid", field "cwd"]
  end

fun project_lock_error lock owner =
  Error ("project is already being modified by another holbuild process\n" ^
         "lock: " ^ lock ^ "\n" ^
         "owner: " ^ owner_summary owner)

fun project_lock_mode () =
  Posix.FileSys.S.flags [Posix.FileSys.S.irusr, Posix.FileSys.S.iwusr,
                         Posix.FileSys.S.irgrp, Posix.FileSys.S.iwgrp,
                         Posix.FileSys.S.iroth, Posix.FileSys.S.iwoth]

fun open_project_lock_file lock =
  Posix.FileSys.createf(lock, Posix.FileSys.O_RDWR, Posix.FileSys.O.flags [], project_lock_mode ())

fun close_fd fd = Posix.IO.close fd handle OS.SysErr _ => ()

fun set_close_on_exec fd =
  let val flags = Posix.IO.getfd fd
  in Posix.IO.setfd(fd, Posix.IO.FD.flags [flags, Posix.IO.FD.cloexec]) end
  handle OS.SysErr _ => ()

fun whole_file_lock ltype =
  Posix.IO.FLock.flock {ltype = ltype, whence = Posix.IO.SEEK_SET,
                        start = 0, len = 0, pid = NONE}

fun try_lock_fd fd =
  (ignore (Posix.IO.setlk(fd, whole_file_lock Posix.IO.F_WRLCK)); true)
  handle OS.SysErr _ => false

fun blocking_lock_owner fd =
  let val lock = Posix.IO.getlk(fd, whole_file_lock Posix.IO.F_WRLCK)
  in
    case Posix.IO.FLock.pid lock of
        SOME pid => SOME (pid_text pid)
      | NONE => NONE
  end
  handle OS.SysErr _ => NONE

fun unavailable_owner fd =
  String.concatWith "\n"
    ["holbuild-project-lock-v2",
     "command=unknown",
     "pid=" ^ Option.getOpt(blocking_lock_owner fd, "unknown"),
     "cwd=unknown"] ^ "\n"

fun path_is_dir path = FS.isDir path handle OS.SysErr _ => false

fun remove_obsolete_lock_dir lock =
  if path_is_dir lock then
    (HolbuildStatus.message_stderr
       ("holbuild: warning: removing obsolete directory project lock: " ^ lock ^ "\n");
     remove_tree lock)
  else ()

fun acquire project command =
  let
    val lock = project_lock_path project
    val _ = ensure_parent lock
    val _ = remove_obsolete_lock_dir lock
    val fd = open_project_lock_file lock
    val _ = set_close_on_exec fd
  in
    if try_lock_fd fd then
      ((write_text (project_lock_owner_path lock) (project_lock_owner command);
        ProjectLock {fd = fd, lock = lock})
       handle e => (close_fd fd; raise e))
    else
      let val owner = Option.getOpt(current_lock_owner lock, unavailable_owner fd)
      in close_fd fd; raise project_lock_error lock owner end
  end

fun release (ProjectLock {fd, lock}) =
  (remove_file (project_lock_owner_path lock); close_fd fd)

fun with_lock project command f =
  let val lock = acquire project command
  in
    (f () before release lock)
    handle e =>
      (HolbuildToolchain.cleanup_active_children ();
       release lock;
       raise e)
  end

end
