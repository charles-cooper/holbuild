structure HolbuildCacheBackend =
struct

datatype publish_result = Published | AlreadyPresent | Conflict of string | Skipped

datatype fetch_result = Hit | Miss | Corrupt of string

end

signature HOLBUILD_CACHE_BACKEND =
sig
  type t

  val get_action : t -> string -> string option
  val put_action : t -> {key : string, text : string} -> HolbuildCacheBackend.publish_result

  val has_blob : t -> string -> bool
  val fetch_blob : t -> {hash : string, dst : string} -> HolbuildCacheBackend.fetch_result
  val publish_blob : t -> {hash : string, src : string} -> HolbuildCacheBackend.publish_result
end
