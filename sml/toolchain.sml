structure HolbuildToolchain =
struct

structure Path = OS.Path
structure FS = OS.FileSys

type t = {holdir : string, maxheap : int option}

exception Error of string

fun executable {holdir, ...} parts =
  List.foldl (fn (part, acc) => Path.concat(acc, part)) holdir parts

fun hol tc = executable tc ["bin", "hol"]
fun holmake tc = executable tc ["bin", "Holmake"]
fun base_state tc = executable tc ["bin", "hol.state"]

fun poly_runtime_args ({maxheap, ...} : t) =
  case maxheap of
      NONE => []
    | SOME n => ["--maxheap", Int.toString n]

fun hol_subcommand_argv tc subcommand =
  hol tc :: poly_runtime_args tc @ [subcommand]

fun quote s =
  "'" ^ String.translate (fn #"'" => "'\\''" | c => str c) s ^ "'"

fun command argv = String.concatWith " " (map quote argv)

fun success status = OS.Process.isSuccess status

fun timing_field text =
  String.translate (fn #"\t" => " " | #"\n" => " " | c => str c) text

fun timing_line {kind, argv, output, status, start, finish} =
  let
    val ms = Time.toMilliseconds (Time.-(finish, start))
    val fields =
      ["tool", "kind=" ^ timing_field kind,
       "status=" ^ (if success status then "ok" else "fail"),
       "ms=" ^ LargeInt.toString ms,
       "argc=" ^ Int.toString (length argv),
       "argv0=" ^ timing_field (case argv of [] => "" | first :: _ => first)] @
      (case output of NONE => [] | SOME path => ["output=" ^ timing_field path])
  in
    String.concatWith "\t" fields ^ "\n"
  end

fun append_timing entry =
  case OS.Process.getEnv "HOLBUILD_TIMING_LOG" of
      NONE => ()
    | SOME path =>
        let val out = TextIO.openAppend path
        in TextIO.output(out, entry); TextIO.closeOut out end
        handle _ => ()

fun phase_line {name, status, start, finish} =
  String.concatWith "\t"
    ["phase",
     "name=" ^ timing_field name,
     "status=" ^ timing_field status,
     "ms=" ^ LargeInt.toString (Time.toMilliseconds (Time.-(finish, start)))] ^ "\n"

fun time_phase name f =
  let val start = Time.now ()
  in
    (let
       val result = f ()
       val finish = Time.now ()
       val _ = append_timing (phase_line {name = name, status = "ok", start = start, finish = finish})
     in
       result
     end)
    handle e =>
      let
        val finish = Time.now ()
        val _ = append_timing (phase_line {name = name, status = "fail", start = start, finish = finish})
      in
        raise e
      end
  end

fun timed_system kind argv output run =
  let
    val start = Time.now ()
    val status = run ()
    val finish = Time.now ()
    val _ = append_timing (timing_line {kind = kind, argv = argv, output = output,
                                        status = status, start = start, finish = finish})
  in
    status
  end

fun exit_status_success Posix.Process.W_EXITED = true
  | exit_status_success _ = false

fun process_status exit_status =
  if exit_status_success exit_status then OS.Process.success else OS.Process.failure

fun set_child_process_group pid =
  Posix.ProcEnv.setpgid {pid = SOME pid, pgid = SOME pid} handle OS.SysErr _ => ()

fun set_own_process_group () =
  Posix.ProcEnv.setpgid {pid = NONE, pgid = NONE} handle OS.SysErr _ => ()

fun kill_process_group signal pid =
  Posix.Process.kill (Posix.Process.K_GROUP pid, signal) handle OS.SysErr _ => ()

val active_child_groups = ref ([] : Posix.ProcEnv.pid list)
val active_child_mutex = Mutex.mutex ()

fun with_active_child_lock f =
  let
    val _ = Mutex.lock active_child_mutex
    val result = f () before Mutex.unlock active_child_mutex
  in
    result
  end
  handle e => (Mutex.unlock active_child_mutex; raise e)

fun register_child_group pid =
  with_active_child_lock (fn () => active_child_groups := pid :: !active_child_groups)

fun unregister_child_group pid =
  with_active_child_lock
    (fn () => active_child_groups := List.filter (fn active => active <> pid) (!active_child_groups))

fun active_child_group_snapshot () = with_active_child_lock (fn () => !active_child_groups)

fun kill_group_forcefully pid =
  (kill_process_group Posix.Signal.term pid;
   OS.Process.sleep (Time.fromReal 0.2);
   kill_process_group Posix.Signal.kill pid)

fun kill_active_child_groups () = List.app kill_group_forcefully (active_child_group_snapshot ())

fun cleanup_active_children () = kill_active_child_groups ()

fun wait_child pid = #2 (Posix.Process.waitpid (Posix.Process.W_CHILD pid, []))

fun reap_after_kill pid =
  (kill_group_forcefully pid;
   ignore (wait_child pid) handle OS.SysErr _ => ())

fun pid_text pid = LargeInt.toString (SysWord.toLargeInt (Posix.Process.pidToWord pid))

fun parent_watch_script parent_pid script =
  String.concatWith "\n"
    ["holbuild_parent=" ^ pid_text parent_pid,
     "holbuild_group=$$",
     "( while kill -0 \"$holbuild_parent\" 2>/dev/null; do sleep 0.1; done; kill -TERM -\"$holbuild_group\" 2>/dev/null; sleep 0.2; kill -KILL -\"$holbuild_group\" 2>/dev/null ) &",
     "holbuild_parent_watch=$!",
     "trap 'holbuild_status=$?; kill \"$holbuild_parent_watch\" 2>/dev/null; exit $holbuild_status' EXIT",
     script]

fun exec_shell parent_pid script =
  (set_own_process_group ();
   Posix.Process.exece ("/bin/sh", ["/bin/sh", "-c", parent_watch_script parent_pid script], Posix.ProcEnv.environ()))
  handle _ => OS.Process.exit OS.Process.failure

fun run_tracked_shell script =
  let val parent_pid = Posix.ProcEnv.getpid ()
  in
    case Posix.Process.fork () of
        NONE => exec_shell parent_pid script
      | SOME pid =>
          let
            val _ = set_child_process_group pid
            val _ = register_child_group pid
            fun wait () = process_status (wait_child pid)
          in
            (wait () before unregister_child_group pid)
            handle e => (reap_after_kill pid; unregister_child_group pid; raise e)
          end
  end

fun timed_shell kind argv output script =
  timed_system kind argv output (fn () => run_tracked_shell script)

fun run argv =
  timed_shell "run" argv NONE (command argv)

fun run_interactive argv =
  timed_system "run_interactive" argv NONE (fn () => OS.Process.system (command argv))

fun run_in_dir dir argv =
  timed_shell "run_in_dir" argv NONE ("cd " ^ quote dir ^ " && " ^ command argv)

fun run_in_dir_to_file dir argv output =
  timed_shell "run_in_dir_to_file" argv (SOME output)
    ("cd " ^ quote dir ^ " && " ^ command argv ^ " > " ^ quote output ^ " 2>&1")

fun ensure_dir path =
  if path = "" orelse path = "." then ()
  else if FS.access(path, []) handle OS.SysErr _ => false then ()
  else (ensure_dir (Path.dir path); FS.mkDir path handle OS.SysErr _ => ())

fun ensure_parent path = ensure_dir (Path.dir path)

fun readable path = FS.access(path, [FS.A_READ]) handle OS.SysErr _ => false

fun require_readable path =
  if readable path then () else raise Error ("required toolchain file not readable: " ^ path)

fun hash_text text = HolbuildHash.string_sha1 text

fun file_hash path = (require_readable path; HolbuildHash.file_sha1 path)

fun toolchain_key tc =
  hash_text
    (String.concatWith "\n"
       ["holbuild-toolchain-v1",
        "hol=" ^ file_hash (hol tc),
        "base_state=" ^ file_hash (base_state tc)] ^ "\n")

fun sml_string s =
  "\"" ^ String.translate
    (fn #"\\" => "\\\\"
      | #"\"" => "\\\""
      | #"\n" => "\\n"
      | #"\t" => "\\t"
      | c => str c) s ^ "\""

fun write_run_context (project : HolbuildProject.t) =
  let
    val root = HolbuildProject.artifact_root project
    val hol_dir = Path.concat(root, ".holbuild")
    val context = Path.concat(hol_dir, "holbuild-run-context.sml")
    val _ = ensure_dir hol_dir
    val out = TextIO.openOut context
      handle e => raise Error ("could not write " ^ context ^ ": " ^ General.exnMessage e)
    fun line s = TextIO.output(out, s ^ "\n")
  in
    line "(* generated by holbuild; safe to delete *)";
    line "val _ = ();";
    TextIO.closeOut out;
    context
  end

end
