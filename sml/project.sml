structure HolbuildProject =
struct

structure Path = OS.Path
structure FS = OS.FileSys

datatype heap = Heap of {name : string, output : string, objects : string list}

datatype extra_input = ExtraInput of {path : string, absolute_path : string}

datatype action_policy =
  ActionPolicy of
    { logical : string,
      extra_inputs : extra_input list,
      impure : bool,
      cache : bool,
      always_reexecute : bool }

datatype dependency =
  Dependency of
    { name : string,
      path : string option,
      manifest : string option,
      git : string option,
      rev : string option }

datatype override = Override of {name : string, path : string}

datatype package =
  Package of
    { name : string,
      root : string,
      manifest : string,
      members : string list,
      excludes : string list,
      artifact_root : string,
      action_policies : action_policy list }

type t =
  { root : string,
    manifest : string,
    name : string option,
    version : string option,
    members : string list,
    excludes : string list,
    dependencies : dependency list,
    overrides : override list,
    run_heap : string option,
    run_loads : string list,
    heaps : heap list,
    action_policies : action_policy list }

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

fun key_text key = String.concatWith "." key

fun table_keys table = map (fn (name, _) => name) table

fun member value values = List.exists (fn existing => existing = value) values

fun require_known_fields context allowed table =
  let val unknown = List.filter (fn name => not (member name allowed)) (table_keys table)
  in
    case unknown of
        [] => ()
      | name :: _ => die ("unknown field in " ^ context ^ ": " ^ name)
  end

fun string_at table key =
  case lookup table key of
      NONE => NONE
    | SOME (TOML.STRING s) => SOME s
    | SOME _ => die (key_text key ^ " must be a string")

fun int_at table key =
  case lookup table key of
      NONE => NONE
    | SOME (TOML.INTEGER n) => SOME n
    | SOME _ => die (key_text key ^ " must be an integer")

fun bool_at table key =
  case lookup table key of
      NONE => NONE
    | SOME (TOML.BOOL b) => SOME b
    | SOME _ => die (key_text key ^ " must be a boolean")

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
          | NONE => die (key_text key ^ " must be a string array")

fun table_field table key =
  case lookup table key of
      SOME (TOML.TABLE t) => SOME t
    | SOME _ => die (String.concatWith "." key ^ " must be a table")
    | NONE => NONE

fun string_field table name = string_at table [name]
fun string_array_field table name = string_array_at table [name]

fun named_table_entries table key =
  case table_field table key of
      NONE => []
    | SOME entries =>
        let
          fun one (name, value) =
            case value of
                TOML.TABLE t => (name, t)
              | _ => die (String.concatWith "." (key @ [name]) ^ " must be a table")
        in
          map one entries
        end

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

fun validate_schema table =
  case table_field table ["holbuild"] of
      NONE => ()
    | SOME holbuild =>
        (require_known_fields "holbuild" ["schema"] holbuild;
         case int_at holbuild ["schema"] of
             NONE => ()
           | SOME n =>
               if n = IntInf.fromInt 1 then ()
               else die ("unsupported holproject schema: " ^ IntInf.toString n))

fun validate_dependency_table (name, table) =
  require_known_fields ("dependencies." ^ name) ["path", "manifest", "git", "rev"] table

fun validate_action_table (logical, table) =
  require_known_fields ("actions." ^ logical)
    ["extra_inputs", "impure", "cache", "always_reexecute"] table

fun validate_manifest_table table =
  let
    val _ = require_known_fields "holproject.toml"
              ["holbuild", "project", "build", "dependencies", "run", "heap", "actions"] table
    val _ = Option.app (require_known_fields "project" ["name", "version"])
              (table_field table ["project"])
    val _ = Option.app (require_known_fields "build" ["members", "exclude"])
              (table_field table ["build"])
    val _ = Option.app (require_known_fields "run" ["heap", "loads"])
              (table_field table ["run"])
    val _ = List.app validate_dependency_table (named_table_entries table ["dependencies"])
    val _ = List.app validate_action_table (named_table_entries table ["actions"])
    fun validate_heap_entry value =
      case value of
          TOML.TABLE heap => require_known_fields "heap" ["name", "output", "objects"] heap
        | _ => die "heap entries must be tables"
    val _ =
      case lookup table ["heap"] of
          NONE => ()
        | SOME (TOML.ARRAY values) => List.app validate_heap_entry values
        | SOME _ => die "heap must be an array of tables"
  in
    validate_schema table
  end

fun validate_override_table (name, table) =
  require_known_fields ("overrides." ^ name) ["path"] table

fun validate_local_config_table table =
  (require_known_fields ".holconfig.toml" ["overrides"] table;
   List.app validate_override_table (named_table_entries table ["overrides"]))

fun parse_dependency (name, table) =
  Dependency
    { name = name,
      path = string_field table "path",
      manifest = string_field table "manifest",
      git = string_field table "git",
      rev = string_field table "rev" }

fun dependencies_at table = map parse_dependency (named_table_entries table ["dependencies"])

fun parse_action_policy root (logical, table) =
  let
    fun extra path =
      if Path.isAbsolute path then
        die ("actions." ^ logical ^ ".extra_inputs must be package-root-relative: " ^ path)
      else ExtraInput {path = path, absolute_path = Path.concat(root, path)}
  in
    ActionPolicy
      { logical = logical,
        extra_inputs = map extra (string_array_field table "extra_inputs"),
        impure = Option.getOpt(bool_at table ["impure"], false),
        cache = Option.getOpt(bool_at table ["cache"], true),
        always_reexecute = Option.getOpt(bool_at table ["always_reexecute"], false) }
  end

fun action_policies_at root table =
  map (parse_action_policy root) (named_table_entries table ["actions"])

fun parse_override (name, table) =
  case string_field table "path" of
      SOME path => Override {name = name, path = path}
    | NONE => die ("[overrides." ^ name ^ "] requires path")

fun overrides_at table = map parse_override (named_table_entries table ["overrides"])

fun parse_local_config root =
  let val config = Path.concat(root, ".holconfig.toml")
  in
    if readable config then
      let val table = TOML.fromFile config
      in validate_local_config_table table; overrides_at table end
    else []
  end

fun parse_at {manifest, root, overrides} =
  let
    val table = TOML.fromFile manifest
    val _ = validate_manifest_table table
    val project = table_field table ["project"]
    val build = table_field table ["build"]
    val run = table_field table ["run"]
    fun from opt f default = case opt of NONE => default | SOME t => f t
  in
    { root = root,
      manifest = manifest,
      name = Option.mapPartial (fn t => string_field t "name") project,
      version = Option.mapPartial (fn t => string_field t "version") project,
      members = from build (fn t => string_array_field t "members") ["."],
      excludes = from build (fn t => string_array_field t "exclude") [],
      dependencies = dependencies_at table,
      overrides = overrides,
      run_heap = Option.mapPartial (fn t => string_field t "heap") run,
      run_loads = from run (fn t => string_array_field t "loads") [],
      heaps = heaps_at table,
      action_policies = action_policies_at root table }
  end

fun parse manifest =
  let
    val root = manifest_root manifest
    val overrides = parse_local_config root
  in
    parse_at {manifest = manifest, root = root, overrides = overrides}
  end

fun discover () =
  case find_manifest_from (original_dir ()) of
      SOME manifest => parse manifest
    | NONE => die "no holproject.toml found in current directory or parents"

fun abs_under root path =
  if Path.isAbsolute path then path else Path.concat(root, path)

fun abs_member ({root, ...} : t) member = abs_under root member
fun abs_run_heap ({root, run_heap, ...} : t) = Option.map (abs_under root) run_heap

fun override_path overrides name =
  let
    fun matches (Override {name = name', ...}) = name = name'
  in
    case List.find matches overrides of
        SOME (Override {path, ...}) => SOME path
      | NONE => NONE
  end

fun dependency_name (Dependency {name, ...}) = name

fun package_name (Package {name, ...}) = name
fun package_root (Package {root, ...}) = root
fun package_members (Package {members, ...}) = members
fun package_excludes (Package {excludes, ...}) = excludes
fun package_artifact_root (Package {artifact_root, ...}) = artifact_root
fun package_action_policies (Package {action_policies, ...}) = action_policies

fun action_policy_logical (ActionPolicy {logical, ...}) = logical
fun action_extra_inputs (ActionPolicy {extra_inputs, ...}) = extra_inputs
fun action_cache_enabled (ActionPolicy {impure, cache, always_reexecute, ...}) =
  cache andalso not impure andalso not always_reexecute
fun action_always_reexecute (ActionPolicy {impure, always_reexecute, ...}) =
  impure orelse always_reexecute
fun extra_input_path (ExtraInput {path, ...}) = path
fun extra_input_absolute_path (ExtraInput {absolute_path, ...}) = absolute_path

fun default_action_policy logical =
  ActionPolicy {logical = logical, extra_inputs = [], impure = false,
                cache = true, always_reexecute = false}

fun action_policy_for policies logical =
  case List.find (fn policy => action_policy_logical policy = logical) policies of
      SOME policy => policy
    | NONE => default_action_policy logical

fun dependency_local_path ({root, overrides, ...} : t) (Dependency {name, path, ...}) =
  Option.map (abs_under root)
    (case override_path overrides name of
         SOME override => SOME override
       | NONE => path)

fun dependency_manifest (project as {root, ...} : t) dep =
  case dep of
      Dependency {manifest = SOME manifest, ...} => SOME (abs_under root manifest)
    | Dependency {manifest = NONE, ...} =>
        Option.map (fn path => Path.concat(path, "holproject.toml"))
          (dependency_local_path project dep)

fun heap_to_string (Heap {name, output, objects}) =
  name ^ " -> " ^ output ^ " [" ^ String.concatWith ", " objects ^ "]"

fun dependency_to_string project (dep as Dependency {name, path, manifest, git, rev}) =
  let
    fun field label value =
      case value of NONE => [] | SOME s => [label ^ "=" ^ s]
    val override = override_path (#overrides project) name
    val local_path = dependency_local_path project dep
    val resolved_manifest = dependency_manifest project dep
    val fields =
      field "path" path @ field "override" override @ field "local" local_path @
      field "manifest" manifest @ field "resolved-manifest" resolved_manifest @
      field "git" git @ field "rev" rev
  in
    name ^ " [" ^ String.concatWith ", " fields ^ "]"
  end

fun override_to_string (Override {name, path}) = name ^ " -> " ^ path

fun project_package ({root, manifest, name, members, excludes, action_policies, ...} : t) =
  Package {name = Option.getOpt(name, "root"), root = root, manifest = manifest,
           members = members, excludes = excludes,
           artifact_root = Path.concat(root, ".holbuild"),
           action_policies = action_policies}

fun dependency_project (project : t) (dep as Dependency {name, ...}) =
  let
    val dep_root =
      case dependency_local_path project dep of
          SOME path => path
        | NONE => die ("dependency " ^ name ^ " has no local path; add path or .holconfig.toml override")
    val dep_manifest =
      case dependency_manifest project dep of
          SOME manifest => manifest
        | NONE => die ("dependency " ^ name ^ " has no manifest")
    val _ =
      if readable dep_manifest then ()
      else die ("dependency " ^ name ^ " manifest not found: " ^ dep_manifest)
    val dep_project = parse_at {manifest = dep_manifest, root = dep_root, overrides = #overrides project}
    val declared_name = #name dep_project
    val _ =
      case declared_name of
          NONE => ()
        | SOME actual =>
            if actual = name then ()
            else die ("dependency " ^ name ^ " manifest declares project.name = " ^ actual)
  in
    dep_project
  end

fun dependency_package artifact_parent project (dep as Dependency {name, ...}) =
  let
    val dep_project = dependency_project project dep
    val dep_root = valOf (dependency_local_path project dep)
    val dep_manifest = valOf (dependency_manifest project dep)
    val artifact_root = Path.concat(Path.concat(artifact_parent, ".holbuild/deps"), name)
  in
    (Package {name = name, root = dep_root, manifest = dep_manifest,
              members = #members dep_project, excludes = #excludes dep_project,
              artifact_root = artifact_root,
              action_policies = #action_policies dep_project},
     dep_project)
  end

fun packages (project : t) =
  let
    val artifact_parent = #root project
    fun seen name names = List.exists (fn n => n = name) names
    fun add_dependency parent_project (dep, (names, packages)) =
      let val name = dependency_name dep
      in
        if seen name names then (names, packages)
        else
          let
            val (package, dep_project) = dependency_package artifact_parent parent_project dep
            val (names', packages') = add_project dep_project (name :: names, package :: packages)
          in
            (names', packages')
          end
      end
    and add_project current_project state =
      List.foldl (add_dependency current_project) state (#dependencies current_project)
    val root_package = project_package project
    val (_, packages) = add_project project ([package_name root_package], [root_package])
  in
    rev packages
  end

fun describe (project : t) =
  let
    val {root, manifest, name, version, members, excludes, dependencies,
         overrides, run_heap, run_loads, heaps, action_policies} = project
    fun opt label value =
      case value of NONE => () | SOME s => print (label ^ s ^ "\n")
  in
    print ("manifest: " ^ manifest ^ "\n");
    print ("root: " ^ root ^ "\n");
    opt "name: " name;
    opt "version: " version;
    print ("members: " ^ String.concatWith ", " members ^ "\n");
    print ("exclude: " ^ String.concatWith ", " excludes ^ "\n");
    List.app (fn dep => print ("dependency: " ^ dependency_to_string project dep ^ "\n")) dependencies;
    List.app (fn override => print ("override: " ^ override_to_string override ^ "\n")) overrides;
    opt "run.heap: " run_heap;
    print ("run.loads: " ^ String.concatWith ", " run_loads ^ "\n");
    List.app (fn heap => print ("heap: " ^ heap_to_string heap ^ "\n")) heaps;
    List.app (fn policy => print ("action: " ^ action_policy_logical policy ^ "\n")) action_policies
  end

end
