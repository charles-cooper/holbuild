structure HolbuildCacheRoots =
struct

structure Path = OS.Path

exception Error of string

fun default_root () =
  case OS.Process.getEnv "XDG_CACHE_HOME" of
      SOME base => Path.concat(base, "holbuild")
    | NONE =>
        case OS.Process.getEnv "HOME" of
            SOME home => Path.concat(Path.concat(home, ".cache"), "holbuild")
          | NONE => raise Error "set HOME, XDG_CACHE_HOME, HOLBUILD_CACHE, or HOLBUILD_HOL_CACHE"

fun cache_root () =
  case OS.Process.getEnv "HOLBUILD_CACHE" of
      SOME path => path
    | NONE => default_root ()

fun hol_cache_root () =
  case OS.Process.getEnv "HOLBUILD_HOL_CACHE" of
      SOME path => path
    | NONE => cache_root ()

end
