structure HolbuildCacheKey =
struct

structure Path = OS.Path
structure FS = OS.FileSys

exception Error of string

val format = "holbuild-cache-key-v1"

fun die msg = raise Error msg

fun hash_text text = HolbuildHash.string_sha1 text

fun readable path = FS.access(path, [FS.A_READ]) handle OS.SysErr _ => false

fun file_hash label path =
  if readable path then HolbuildHash.file_sha1 path
  else die (label ^ " not found: " ^ path)

fun insert_sorted value values =
  case values of
      [] => [value]
    | x :: xs => if String.<=(value, x) then value :: values else x :: insert_sorted value xs

fun sorted strings = List.foldl (fn (value, values) => insert_sorted value values) [] strings

fun unique_sorted strings =
  let
    fun add (value, kept) = if List.exists (fn existing => existing = value) kept then kept else value :: kept
  in
    sorted (List.foldl add [] strings)
  end

fun command_arg_line arg = "command_arg_sha1=" ^ hash_text arg

fun generator_input_line root generator rel =
  let val path = HolbuildProject.abs_under root rel
  in "input=" ^ rel ^ "@" ^ file_hash ("generator " ^ HolbuildProject.generator_name generator ^ " input") path end

fun generator_dep_line dep_keys dep =
  case List.find (fn (name, _) => name = dep) dep_keys of
      SOME (_, key) => "dep=" ^ dep ^ "@" ^ key
    | NONE => die ("internal missing generator dependency key: " ^ dep)

fun generator_key package dep_keys generator =
  let
    val root = HolbuildProject.package_root package
    val lines =
      ["holbuild-cache-key-generate-v1",
       "package=" ^ HolbuildProject.package_name package,
       "name=" ^ HolbuildProject.generator_name generator] @
      map command_arg_line (HolbuildProject.generator_command generator) @
      map (generator_input_line root generator) (HolbuildProject.generator_inputs generator) @
      map (generator_dep_line dep_keys) (HolbuildProject.generator_deps generator)
  in
    hash_text (String.concatWith "\n" lines ^ "\n")
  end

fun package_generator_keys package =
  let
    fun one (generator, keys) =
      (HolbuildProject.generator_name generator, generator_key package keys generator) :: keys
  in
    rev (List.foldl one [] (HolbuildGenerators.topo_sort (HolbuildProject.package_generators package)))
  end

fun generator_lines package =
  map (fn (name, key) => "generate=" ^ HolbuildProject.package_name package ^ ":" ^ name ^ "@" ^ key)
      (package_generator_keys package)

fun dependency_source_line (HolbuildProject.Dependency {name, source}) =
  case source of
      HolbuildProject.GitSource {git, rev} => "dependency=" ^ name ^ ":git:" ^ git ^ "@" ^ rev
    | HolbuildProject.FromSource {from, path, manifest} =>
        "dependency=" ^ name ^ ":from:" ^ from ^ ":" ^ path ^ ":" ^ manifest

fun dependency_lines (project : HolbuildProject.t) =
  unique_sorted (map dependency_source_line (#dependencies project))

fun root_sources_without_generators project =
  let
    val package = HolbuildProject.project_package project
    val source_root = HolbuildProject.package_root package
    val artifact_root = HolbuildProject.package_artifact_root package
    val policies = HolbuildProject.package_action_policies package
    val excludes = HolbuildProject.package_excludes package
    val exclude_globs = HolbuildProject.package_exclude_globs package
    val members = map (HolbuildProject.abs_under source_root) (HolbuildProject.package_members package)
  in
    HolbuildSourceIndex.sort_sources
      (List.foldl
         (HolbuildSourceIndex.scan_member (HolbuildProject.package_name package)
                                           source_root artifact_root policies excludes exclude_globs)
         []
         members)
  end

fun target_name source = #package source ^ ":" ^ #logical_name source

fun source_matches_target target source =
  target = #logical_name source orelse target = target_name source

fun roots_for_project_sources project sources =
  HolbuildSourceIndex.roots_for_package sources (HolbuildProject.project_package project)

fun selected_targets project sources requested =
  if null requested then roots_for_project_sources project sources else requested

fun selected_sources project sources requested =
  let
    val targets = selected_targets project sources requested
    fun matches target = List.filter (source_matches_target target) sources
    fun one target =
      case matches target of
          [] => die ("unknown cache-key target: " ^ target)
        | matches => matches
  in
    List.concat (map one targets)
  end

fun source_line source =
  "source=" ^ target_name source ^ ":" ^ #relative_path source ^ "@" ^
  file_hash ("source " ^ target_name source) (#source_path source)

fun source_lines project targets =
  let val sources = root_sources_without_generators project
  in unique_sorted (map source_line (selected_sources project sources targets)) end

fun hol_toolchain_key project =
  case HolbuildProject.hol_dependency project of
      SOME (HolbuildProject.Dependency {source = HolbuildProject.GitSource {git, rev}, ...}) =>
        HolbuildHolSharedCache.key {git = git, rev = rev}
    | _ => die "schema 2 project has no direct dependencies.hol exact git revision"

fun component_lines project targets =
  let
    val root_package = HolbuildProject.project_package project
    val toolchain = hol_toolchain_key project
  in
    ["format=" ^ format,
     "holbuild_version=" ^ HolbuildVersion.version,
     "toolchain=" ^ toolchain] @
    dependency_lines project @
    unique_sorted (generator_lines root_package) @
    source_lines project targets
  end

fun build_key project targets =
  hash_text (String.concatWith "\n" (component_lines project targets) ^ "\n")

fun result project targets =
  let
    val toolchain_key = hol_toolchain_key project
    val components = component_lines project targets
    val build_key = hash_text (String.concatWith "\n" components ^ "\n")
  in
    {format = format, toolchain_key = toolchain_key, build_key = build_key, components = components}
  end

end
