structure HolbuildProject =
struct

structure Path = OS.Path
structure FS = OS.FileSys

datatype heap = Heap of {name : string, output : string, objects : string list}

type t =
  { root : string,
    manifest : string,
    name : string option,
    version : string option,
    members : string list,
    includes : string list,
    run_heap : string option,
    run_loads : string list,
    heaps : heap list }

exception Error of string

fun die msg = raise Error msg

fun original_dir () =
  case OS.Process.getEnv "HOLBUILD_ORIG_CWD" of
      SOME d => d
    | NONE => FS.getDir ()

fun readable path = FS.access(path, [FS.A_READ]) handle OS.SysErr _ => false

fun parent dir =
  let val p = Path.dir dir
  in if p = "" then dir else p end

fun find_manifest_from dir =
  let
    fun loop d =
      let val candidate = Path.concat(d, "holproject.toml")
      in
        if readable candidate then SOME candidate
        else
          let val p = parent d
          in if p = d then NONE else loop p end
      end
  in
    loop (Path.mkAbsolute {path = dir, relativeTo = FS.getDir ()})
  end

fun manifest_root manifest = Path.dir manifest

fun lookup table key = TOML.lookupInTable table key

fun string_value value =
  case value of
      TOML.STRING s => SOME s
    | _ => NONE

fun string_at table key = Option.mapPartial string_value (lookup table key)

fun string_array_value value =
  case value of
      TOML.ARRAY values =>
        let
          fun one v =
            case v of
                TOML.STRING s => s
              | _ => die "expected string array in holproject.toml"
        in
          SOME (map one values)
        end
    | _ => NONE

fun string_array_at table key =
  case lookup table key of
      NONE => []
    | SOME value =>
        case string_array_value value of
            SOME xs => xs
          | NONE => die "expected string array in holproject.toml"

fun table_field table key =
  case lookup table key of
      SOME (TOML.TABLE t) => SOME t
    | SOME _ => die (String.concatWith "." key ^ " must be a table")
    | NONE => NONE

fun string_field table name = string_at table [name]
fun string_array_field table name = string_array_at table [name]

fun parse_heap value =
  case value of
      TOML.TABLE table =>
        let
          val name =
            case string_field table "name" of
                SOME s => s
              | NONE => die "[[heap]] entry requires name"
          val output =
            case string_field table "output" of
                SOME s => s
              | NONE => die "[[heap]] entry requires output"
          val objects = string_array_field table "objects"
        in
          Heap {name = name, output = output, objects = objects}
        end
    | _ => die "heap entries must be tables"

fun heaps_at table =
  case lookup table ["heap"] of
      NONE => []
    | SOME (TOML.ARRAY values) => map parse_heap values
    | SOME _ => die "heap must be an array of tables"

fun parse manifest =
  let
    val table = TOML.fromFile manifest
    val project = table_field table ["project"]
    val build = table_field table ["build"]
    val paths = table_field table ["paths"]
    val run = table_field table ["run"]
    fun from opt f default = case opt of NONE => default | SOME t => f t
  in
    { root = manifest_root manifest,
      manifest = manifest,
      name = Option.mapPartial (fn t => string_field t "name") project,
      version = Option.mapPartial (fn t => string_field t "version") project,
      members = from build (fn t => string_array_field t "members") ["."],
      includes = from paths (fn t => string_array_field t "includes") [],
      run_heap = Option.mapPartial (fn t => string_field t "heap") run,
      run_loads = from run (fn t => string_array_field t "loads") [],
      heaps = heaps_at table }
  end

fun discover () =
  case find_manifest_from (original_dir ()) of
      SOME manifest => parse manifest
    | NONE => die "no holproject.toml found in current directory or parents"

fun abs_under root path =
  if Path.isAbsolute path then path else Path.concat(root, path)

fun abs_member ({root, ...} : t) member = abs_under root member
fun abs_include ({root, ...} : t) include_path = abs_under root include_path
fun abs_run_heap ({root, run_heap, ...} : t) = Option.map (abs_under root) run_heap

fun heap_to_string (Heap {name, output, objects}) =
  name ^ " -> " ^ output ^ " [" ^ String.concatWith ", " objects ^ "]"

fun describe (project : t) =
  let
    val {root, manifest, name, version, members, includes, run_heap,
         run_loads, heaps} = project
    fun opt label value =
      case value of NONE => () | SOME s => print (label ^ s ^ "\n")
  in
    print ("manifest: " ^ manifest ^ "\n");
    print ("root: " ^ root ^ "\n");
    opt "name: " name;
    opt "version: " version;
    print ("members: " ^ String.concatWith ", " members ^ "\n");
    print ("includes: " ^ String.concatWith ", " includes ^ "\n");
    opt "run.heap: " run_heap;
    print ("run.loads: " ^ String.concatWith ", " run_loads ^ "\n");
    List.app (fn heap => print ("heap: " ^ heap_to_string heap ^ "\n")) heaps
  end

end
