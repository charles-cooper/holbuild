structure HolbuildFSCacheBackend =
struct

structure Path = OS.Path
structure FS = OS.FileSys

exception Error of string

datatype t = FSCache of {root : string}

fun filesystem root = FSCache {root = root}

fun default () =
  filesystem (HolbuildCacheConfig.cache_root ())
  handle HolbuildCacheConfig.Error msg => raise Error msg

fun root (FSCache {root}) = root

fun path_exists path = FS.access(path, []) handle OS.SysErr _ => false

fun ensure_dir path =
  if path = "" orelse path = "." then ()
  else if path_exists path then ()
  else (ensure_dir (Path.dir path); FS.mkDir path handle OS.SysErr _ => ())

fun actions_dir cache = Path.concat(root cache, "actions")
fun blobs_dir cache = Path.concat(root cache, "blobs")
fun tmp_dir cache = Path.concat(root cache, "tmp")
fun locks_dir cache = Path.concat(root cache, "locks")

fun action_dir cache key = Path.concat(actions_dir cache, key)
fun action_manifest cache key = Path.concat(action_dir cache key, "manifest")
fun blob_path cache hash = Path.concat(blobs_dir cache, hash)

fun ensure_layout cache =
  (ensure_dir (actions_dir cache); ensure_dir (blobs_dir cache); ensure_dir (tmp_dir cache))

fun touch_action cache key = FS.setTime(action_manifest cache key, NONE) handle OS.SysErr _ => ()

fun action_lock cache key = Path.concat(locks_dir cache, "action-" ^ key ^ ".lock")

datatype action_lock_handle = ActionLockHandle of HolbuildFileLock.t

fun try_acquire_action_lock cache key =
  (case HolbuildFileLock.try_acquire_path {path = action_lock cache key, obsolete_kind = SOME "action cache"} of
       SOME lock => SOME (ActionLockHandle lock)
     | NONE => NONE)
  handle HolbuildFileLock.Error _ => NONE

fun release_action_lock (ActionLockHandle lock) = HolbuildFileLock.release lock

fun with_action_publish_lock cache key publish skip =
  case try_acquire_action_lock cache key of
      SOME lock =>
        ((publish () before release_action_lock lock)
         handle e => (release_action_lock lock; raise e))
    | NONE => skip ()

end
