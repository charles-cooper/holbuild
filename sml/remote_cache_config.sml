structure HolbuildRemoteCacheConfig =
struct

exception Error of string

val override_url : string option ref = ref NONE

fun nonempty label text =
  if text = "" then raise Error (label ^ " must not be empty") else text

fun normalize_url url = nonempty "remote cache URL" url

fun set_url url = override_url := SOME (normalize_url url)

fun env_url () =
  case OS.Process.getEnv "HOLBUILD_REMOTE_CACHE_URL" of
      SOME url => SOME (normalize_url url)
    | NONE => NONE

fun url () =
  case !override_url of
      SOME url => SOME url
    | NONE => env_url ()

fun enabled () = Option.isSome (url ())

end
