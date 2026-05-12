structure HolbuildCache =
struct

structure Path = OS.Path
structure FS = OS.FileSys

exception Error of string

val default_retention_days = 7

fun has_prefix prefix s =
  size s >= size prefix andalso String.substring(s, 0, size prefix) = prefix

fun quote s =
  "'" ^ String.translate (fn #"'" => "'\\''" | c => str c) s ^ "'"

fun path_exists path = FS.access(path, []) handle OS.SysErr _ => false

fun ensure_dir path =
  if path = "" orelse path = "." then ()
  else if path_exists path then ()
  else (ensure_dir (Path.dir path); FS.mkDir path handle OS.SysErr _ => ())

fun cache_root () =
  case OS.Process.getEnv "HOLBUILD_CACHE" of
      SOME path => path
    | NONE =>
      case OS.Process.getEnv "XDG_CACHE_HOME" of
          SOME base => Path.concat(base, "holbuild")
        | NONE =>
          case OS.Process.getEnv "HOME" of
              SOME home => Path.concat(Path.concat(home, ".cache"), "holbuild")
            | NONE => raise Error "set HOME, XDG_CACHE_HOME, or HOLBUILD_CACHE"

fun actions_dir root = Path.concat(root, "actions")
fun blobs_dir root = Path.concat(root, "blobs")
fun tmp_dir root = Path.concat(root, "tmp")
fun action_dir root key = Path.concat(actions_dir root, key)
fun action_manifest root key = Path.concat(action_dir root key, "manifest")
fun blob_path root hash = Path.concat(blobs_dir root, hash)

fun touch path = FS.setTime(path, NONE) handle OS.SysErr _ => ()

fun ensure_layout root =
  (ensure_dir (actions_dir root); ensure_dir (blobs_dir root); ensure_dir (tmp_dir root))

fun children dir =
  if not (path_exists dir) then []
  else
    let
      val stream = FS.openDir dir
      fun loop acc =
        case FS.readDir stream of
            NONE => rev acc
          | SOME name =>
            if name = "." orelse name = ".." then loop acc
            else loop (Path.concat(dir, name) :: acc)
      val result = loop [] handle e => (FS.closeDir stream; raise e)
    in
      FS.closeDir stream;
      result
    end

fun remove_tree path =
  if path = "" orelse path = "." orelse path = "/" then
    raise Error ("refusing to remove unsafe cache path: " ^ path)
  else
    let val status = OS.Process.system ("rm -rf " ^ quote path)
    in
      if OS.Process.isSuccess status then ()
      else raise Error ("failed to remove cache path: " ^ path)
    end

fun stale cutoff path =
  Time.<(FS.modTime path, cutoff) handle OS.SysErr _ => false

fun retention_cutoff days =
  if days < 0 then raise Error "retention days must be non-negative"
  else Time.-(Time.now(), Time.fromSeconds (IntInf.fromInt (days * 86400)))

fun read_lines path =
  let
    val input = TextIO.openIn path
    fun loop acc =
      case TextIO.inputLine input of
          NONE => rev acc
        | SOME line => loop (line :: acc)
      val lines = loop [] handle e => (TextIO.closeIn input; raise e)
  in
    TextIO.closeIn input;
    lines
  end

fun trim_newline s =
  if size s > 0 andalso String.sub(s, size s - 1) = #"\n" then
    String.substring(s, 0, size s - 1)
  else s

fun take_token s =
  let
    fun loop i =
      if i >= size s then i
      else
        case String.sub(s, i) of
            #" " => i
          | #"\t" => i
          | #"\n" => i
          | _ => loop (i + 1)
    val n = loop 0
  in
    String.substring(s, 0, n)
  end

fun blob_ref line =
  let val clean = trim_newline line
  in
    case String.tokens Char.isSpace clean of
        ["blob", _, hash] => SOME hash
      | _ =>
          if has_prefix "blob=" clean then SOME (take_token (String.extract(clean, 5, NONE)))
          else if has_prefix "blob-sha1=" clean then SOME (take_token (String.extract(clean, 10, NONE)))
          else NONE
  end

fun empty_blob_set () = Redblackset.empty String.compare

fun add_blob (blob, blobs) = Redblackset.add(blobs, blob)

fun manifest_path action_dir = Path.concat(action_dir, "manifest")

fun action_live_blobs action_dir =
  let val manifest = manifest_path action_dir
  in
    if path_exists manifest then
      List.foldl
        (fn (line, blobs) =>
            case blob_ref line of
                NONE => blobs
              | SOME blob => add_blob (blob, blobs))
        (empty_blob_set ())
        (read_lines manifest)
    else empty_blob_set ()
  end

fun collect_live_actions cutoff actions_dir =
  let
    fun one (action_dir, (live_blobs, removed)) =
      let val manifest = manifest_path action_dir
      in
        if path_exists manifest then
          if stale cutoff manifest then
            (remove_tree action_dir; (live_blobs, removed + 1))
          else
            (Redblackset.union(live_blobs, action_live_blobs action_dir),
             removed)
        else if stale cutoff action_dir then
          (remove_tree action_dir; (live_blobs, removed + 1))
        else
          (live_blobs, removed)
      end
  in
    List.foldl one (empty_blob_set (), 0) (children actions_dir)
  end

fun remove_stale_children cutoff dir =
  List.foldl
    (fn (path, removed) =>
        if stale cutoff path then (remove_tree path; removed + 1) else removed)
    0
    (children dir)

fun remove_stale_action_locks cutoff dir =
  List.foldl
    (fn (path, removed) =>
        if has_prefix "action-" (Path.file path) andalso stale cutoff path then
          (remove_tree path; removed + 1)
        else removed)
    0
    (children dir)

fun blob_name path = Path.file path

fun sweep_blobs cutoff live_blobs blobs_dir =
  List.foldl
    (fn (path, removed) =>
        if stale cutoff path andalso not (Redblackset.member(live_blobs, blob_name path)) then
          (remove_tree path; removed + 1)
        else removed)
    0
    (children blobs_dir)

fun locks_dir root = Path.concat(root, "locks")
fun gc_lock_path root = Path.concat(locks_dir root, "gc.lock")
fun gc_lock_owner_path lock = lock ^ ".owner"

fun path_is_dir path = FS.isDir path handle OS.SysErr _ => false

fun remove_obsolete_gc_lock_dir lock =
  if path_is_dir lock then
    (HolbuildStatus.message_stderr
       ("holbuild: warning: removing obsolete directory cache gc lock: " ^ lock ^ "\n");
     remove_tree lock)
  else ()

datatype gc_lock = GcLock of {fd : Posix.IO.file_desc, lock : string}

fun gc_lock_owner () =
  String.concatWith "\n"
    ["holbuild-cache-gc-lock-v1",
     "command=cache gc",
     "pid=" ^ HolbuildProjectLock.current_pid_text (),
     "pid_ns=" ^ HolbuildProjectLock.current_pid_namespace (),
     "starttime=" ^ HolbuildProjectLock.proc_starttime "self",
     "boot_id=" ^ HolbuildProjectLock.current_boot_id (),
     "cwd=" ^ FS.getDir (),
     "host=" ^ HolbuildProjectLock.current_host (),
     "started=" ^ Time.toString (Time.now ())] ^ "\n"

fun current_gc_lock_owner lock =
  SOME (HolbuildProjectLock.read_text (gc_lock_owner_path lock)) handle _ => NONE

fun unavailable_gc_lock_owner fd =
  String.concatWith "\n"
    ["holbuild-cache-gc-lock-v1",
     "command=cache gc",
     "pid=" ^ Option.getOpt(HolbuildProjectLock.blocking_lock_owner fd, "unknown"),
     "cwd=unknown"] ^ "\n"

fun cache_gc_lock_error lock owner =
  Error ("cache gc already running\n" ^
         "lock: " ^ lock ^ "\n" ^
         "owner: " ^ HolbuildProjectLock.owner_summary owner)

fun acquire_lock root =
  let
    val lock = gc_lock_path root
  in
    (ensure_dir (locks_dir root);
     remove_obsolete_gc_lock_dir lock;
     let
       val fd = HolbuildProjectLock.open_project_lock_file lock
       val _ = HolbuildProjectLock.set_close_on_exec fd
     in
       if HolbuildProjectLock.try_lock_fd fd then
         ((HolbuildProjectLock.write_text (gc_lock_owner_path lock) (gc_lock_owner ());
           GcLock {fd = fd, lock = lock})
          handle e => (HolbuildProjectLock.close_fd fd; raise e))
       else
         let val owner = Option.getOpt(current_gc_lock_owner lock, unavailable_gc_lock_owner fd)
         in HolbuildProjectLock.close_fd fd; raise cache_gc_lock_error lock owner end
     end)
    handle OS.SysErr (msg, _) =>
      raise Error ("could not acquire cache gc lock: " ^ lock ^ ": " ^ msg)
  end

fun release_gc_lock (GcLock {fd, lock}) =
  (HolbuildProjectLock.remove_file (gc_lock_owner_path lock);
   HolbuildProjectLock.close_fd fd)

fun with_lock root f =
  let val lock = acquire_lock root
  in
    (f () before release_gc_lock lock)
    handle e => (release_gc_lock lock; raise e)
  end

fun release_dir_lock lock = FS.rmDir lock handle OS.SysErr _ => ()

fun action_lock root key = Path.concat(locks_dir root, "action-" ^ key ^ ".lock")

fun try_acquire_action_lock root key =
  let val lock = action_lock root key
  in
    ensure_dir (locks_dir root);
    (FS.mkDir lock; SOME lock) handle OS.SysErr _ => NONE
  end

fun with_action_publish_lock root key publish skip =
  case try_acquire_action_lock root key of
      SOME lock =>
        ((publish () before release_dir_lock lock)
         handle e => (release_dir_lock lock; raise e))
    | NONE => skip ()

fun gc_root root days =
  if not (path_exists root) then
    print ("cache not found: " ^ root ^ "\n")
  else
    let
      val cutoff = retention_cutoff days
      val actions_dir = Path.concat(root, "actions")
      val blobs_dir = Path.concat(root, "blobs")
      val tmp_dir = Path.concat(root, "tmp")
      fun run () =
        let
          val tmp_removed = remove_stale_children cutoff tmp_dir
          val lock_removed = remove_stale_action_locks cutoff (locks_dir root)
          val (live_blobs, actions_removed) = collect_live_actions cutoff actions_dir
          val blobs_removed = sweep_blobs cutoff live_blobs blobs_dir
        in
          print ("cache gc: removed tmp=" ^ Int.toString tmp_removed ^
                 " locks=" ^ Int.toString lock_removed ^
                 " actions=" ^ Int.toString actions_removed ^
                 " blobs=" ^ Int.toString blobs_removed ^ "\n")
        end
    in
      with_lock root run
    end

fun parse_days text =
  case Int.fromString text of
      SOME n => n
    | NONE => raise Error ("invalid retention days: " ^ text)

fun parse_gc_args args =
  let
    fun loop root days rest =
      case rest of
          [] => (root, days)
        | "--cache-dir" :: path :: xs => loop (SOME path) days xs
        | "--retention-days" :: n :: xs => loop root (parse_days n) xs
        | "--days" :: n :: xs => loop root (parse_days n) xs
        | arg :: _ => raise Error ("unknown cache gc option: " ^ arg)
  in
    loop NONE default_retention_days args
  end

fun gc args =
  let val (root, days) = parse_gc_args args
  in gc_root (Option.getOpt(root, cache_root ())) days end

fun dispatch args =
  case args of
      "gc" :: rest => gc rest
    | [] => raise Error "cache command requires subcommand: gc"
    | cmd :: _ => raise Error ("unknown cache command: " ^ cmd)

end
