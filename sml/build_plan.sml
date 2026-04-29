structure HolbuildBuildPlan =
struct

structure Path = OS.Path
structure FS = OS.FileSys

exception Error of string

type node =
  { source : HolbuildSourceIndex.source,
    deps : HolbuildDependencies.t,
    external_dirs : string list }

type t = node list

type keyed_node = {node : node, input_key : string}

fun source_of ({source, ...} : node) = source
fun deps_of ({deps, ...} : node) = deps
fun external_dirs_of ({external_dirs, ...} : node) = external_dirs
fun logical_name node = #logical_name (source_of node)
fun package node = #package (source_of node)
fun relative_path node = #relative_path (source_of node)
fun key node = package node ^ "\000" ^ relative_path node ^ "\000" ^ logical_name node

fun member value values = List.exists (fn x => x = value) values

fun add_unique (value, values) = if member value values then values else value :: values

fun unique_strings values = rev (List.foldl add_unique [] values)

fun normalize_path path = Path.mkCanonical path handle Path.InvalidArc => path

fun source_dir source = normalize_path (Path.dir (#source_path source))

fun readable_dir path = FS.isDir path handle OS.SysErr _ => false

fun dependency_includes holdir sources =
  List.filter readable_dir
    (unique_strings (map source_dir sources @ [normalize_path (Path.concat(holdir, "sigobj"))]))

fun has_logical_name name node = logical_name node = name

fun nodes_named nodes name = List.filter (has_logical_name name) nodes

fun selected_nodes nodes targets =
  case targets of
      [] => nodes
    | _ =>
      let
        fun find target =
          case nodes_named nodes target of
              [] => raise Error ("unknown build target: " ^ target)
            | matches => matches
      in
        List.concat (map find targets)
      end

fun theory_name name =
  let val suffix = "Theory"
      val n = size name
      val m = size suffix
  in
    n > m andalso String.substring(name, n - m, m) = suffix
  end

fun declared_dependency_names node =
  HolbuildProject.action_deps (#policy (source_of node))

fun declared_load_names node =
  HolbuildProject.action_loads (#policy (source_of node))

fun direct_dependency_names node =
  unique_strings
    (#loads (deps_of node) @ declared_dependency_names node @ declared_load_names node)

fun source_object_candidates node =
  let
    val dir = source_dir (source_of node)
    fun in_source_tree ext = normalize_path (Path.concat(dir, logical_name node ^ ext))
  in
    case #kind (source_of node) of
        HolbuildSourceIndex.TheoryScript => [in_source_tree ".uo"]
      | HolbuildSourceIndex.Sml => [in_source_tree ".uo"]
      | HolbuildSourceIndex.Sig => [in_source_tree ".ui"]
  end

fun holdep_project_dep candidate dep = member dep (source_object_candidates candidate)

fun direct_holdep_project_deps nodes node =
  let
    val deps = #holdep_deps (deps_of node)
  in
    List.filter
      (fn candidate => key candidate <> key node andalso
                       List.exists (holdep_project_dep candidate) deps)
      nodes
  end

fun has_path_prefix prefix path =
  let
    val prefix' = normalize_path prefix
    val path' = normalize_path path
    val prefix_with_slash = if String.isSuffix "/" prefix' then prefix' else prefix' ^ "/"
  in
    path' = prefix' orelse String.isPrefix prefix_with_slash path'
  end

fun dep_stem dep =
  let
    val file = Path.file dep
  in
    if String.isSuffix ".uo" file then String.substring(file, 0, size file - 3)
    else if String.isSuffix ".ui" file then String.substring(file, 0, size file - 3)
    else file
  end

fun readable_path path = FS.access(path, [FS.A_READ]) handle OS.SysErr _ => false

fun external_load_available node name =
  List.exists
    (fn dir => readable_path (Path.concat(dir, name ^ ".uo")) orelse
               readable_path (Path.concat(dir, name ^ ".ui")))
    (external_dirs_of node)

fun holdep_external_dep node dep =
  List.exists (fn dir => has_path_prefix dir dep) (external_dirs_of node) orelse
  external_load_available node (dep_stem dep)

fun holdep_external_names node =
  unique_strings (map dep_stem (List.filter (holdep_external_dep node) (#holdep_deps (deps_of node))))

fun raw_external_load_names nodes node =
  let
    fun known name = not (null (nodes_named nodes name))
    fun external name = not (known name) andalso not (theory_name name) andalso
                        external_load_available node name
  in
    List.filter external (#loads (deps_of node))
  end

fun signature_companion_deps nodes node =
  case #kind (source_of node) of
      HolbuildSourceIndex.Sml =>
        List.filter
          (fn candidate =>
              package candidate = package node andalso
              logical_name candidate = logical_name node andalso
              #kind (source_of candidate) = HolbuildSourceIndex.Sig)
          nodes
    | _ => []

fun unique_nodes nodes =
  let
    fun add (node, kept) =
      if member (key node) (map key kept) then kept else node :: kept
  in
    rev (List.foldl add [] nodes)
  end

fun direct_project_deps nodes node =
  let
    fun candidates name = nodes_named nodes name
    fun not_self candidate = key candidate <> key node
    val named_deps = List.concat (map candidates (direct_dependency_names node))
  in
    unique_nodes (List.filter not_self
                    (signature_companion_deps nodes node @ named_deps @
                     direct_holdep_project_deps nodes node))
  end

fun direct_external_theories nodes node =
  let
    fun known name = not (null (nodes_named nodes name))
    val holdep_theories = List.filter theory_name (holdep_external_names node)
    val loaded_theories = List.filter theory_name (#loads (deps_of node))
  in
    unique_strings (List.filter (fn name => not (known name))
                      (loaded_theories @ holdep_theories))
  end

fun direct_external_libs nodes node =
  let
    fun known name = not (null (nodes_named nodes name))
    val holdep_libs = List.filter (fn name => not (theory_name name)) (holdep_external_names node)
  in
    unique_strings
      (List.filter (fn name => not (known name))
         (declared_load_names node @ holdep_libs @ raw_external_load_names nodes node))
  end

fun direct_unresolved_loads nodes node =
  let
    fun known name = not (null (nodes_named nodes name))
    fun unresolved name = not (known name) andalso not (theory_name name) andalso
                          not (external_load_available node name)
  in
    List.filter unresolved (#loads (deps_of node))
  end

fun direct_unresolved_declared_deps nodes node =
  let
    fun known name = not (null (nodes_named nodes name))
  in
    List.filter (fn name => not (known name)) (declared_dependency_names node)
  end

fun holdep_project_dep_any nodes dep =
  List.exists (fn candidate => member dep (source_object_candidates candidate)) nodes

fun unclassified_holdep_deps nodes node =
  List.filter
    (fn dep => not (holdep_project_dep_any nodes dep) andalso
               not (holdep_external_dep node dep))
    (#holdep_deps (deps_of node))

fun reject_unresolved_loads nodes plan =
  let
    fun check_loads node =
      case direct_unresolved_loads nodes node of
          [] => ()
        | load :: _ =>
            raise Error ("unresolved load " ^ load ^ " in " ^
                         package node ^ ":" ^ relative_path node)
    fun check_declared_deps node =
      case direct_unresolved_declared_deps nodes node of
          [] => ()
        | dep :: _ =>
            raise Error ("unresolved action dependency " ^ dep ^ " in " ^
                         package node ^ ":" ^ relative_path node)
    fun check_holdep_deps node =
      case unclassified_holdep_deps nodes node of
          [] => ()
        | dep :: _ =>
            raise Error ("unresolved Holdep dependency " ^ dep ^ " in " ^
                         package node ^ ":" ^ relative_path node ^
                         "; add it to holproject.toml members or a dependency shim")
  in
    List.app (fn node => (check_loads node; check_declared_deps node; check_holdep_deps node)) plan
  end

fun reject_source_uses plan =
  let
    fun check node =
      case #uses (deps_of node) of
          [] => ()
        | used :: _ =>
            raise Error ("unsupported use " ^ used ^ " in " ^
                         package node ^ ":" ^ relative_path node ^
                         "; declare a project module and load it instead")
  in
    List.app check plan
  end

fun cycle_message path node =
  "dependency cycle: " ^
  String.concatWith " -> " (rev (logical_name node :: map logical_name path))

fun topo_sort nodes roots =
  let
    fun visit node (visited, active, order) =
      if member (key node) visited then (visited, active, order)
      else if member (key node) (map key active) then raise Error (cycle_message active node)
      else
        let
          val active' = node :: active
          val deps = direct_project_deps nodes node
          val (visited', _, order') =
            List.foldl (fn (dep, state) => visit dep state) (visited, active', order) deps
        in
          (key node :: visited', active, node :: order')
        end
    val (_, _, order) =
      List.foldl (fn (root, state) => visit root state) ([], [], []) roots
    val plan = rev order
  in
    reject_unresolved_loads nodes plan;
    reject_source_uses plan;
    plan
  end

fun transitive_project_deps nodes node = topo_sort nodes (direct_project_deps nodes node)

fun closure_external_theories nodes node =
  unique_strings
    (List.concat (map (direct_external_theories nodes)
       (transitive_project_deps nodes node @ [node])))

fun closure_external_libs nodes node =
  unique_strings
    (List.concat (map (direct_external_libs nodes)
       (transitive_project_deps nodes node @ [node])))

fun make_node includes external_dirs source =
  {source = source,
   deps = HolbuildDependencies.extract {includes = includes} (#source_path source),
   external_dirs = external_dirs}

fun plan holdir sources targets =
  let
    val external_dirs = [normalize_path (Path.concat(holdir, "sigobj"))]
    val includes = dependency_includes holdir sources
    val nodes = map (make_node includes external_dirs) sources
    val roots = selected_nodes nodes targets
  in
    topo_sort nodes roots
  end

fun kind_name source = HolbuildSourceIndex.kind_string (#kind source)

fun readable path = OS.FileSys.access(path, [OS.FileSys.A_READ]) handle OS.SysErr _ => false

fun file_hash path =
  if readable path then SHA1_ML.sha1_file {filename = path}
  else raise Error ("extra input not found: " ^ path)

fun bool_text true = "true"
  | bool_text false = "false"

fun hash_text text =
  let
    val tmp = OS.FileSys.tmpName ()
    val out = TextIO.openOut tmp
    val _ = TextIO.output(out, text)
    val _ = TextIO.closeOut out
    val hash = SHA1_ML.sha1_file {filename = tmp}
    val _ = OS.FileSys.remove tmp handle OS.SysErr _ => ()
  in
    hash
  end

fun lookup_key keys dep =
  case List.find (fn (dep_key, _) => dep_key = key dep) keys of
      SOME (_, input_key) => input_key
    | NONE => raise Error ("missing action key for dependency: " ^ logical_name dep)

fun action_text config_lines toolchain_key nodes keys node =
  let
    val source = source_of node
    val source_hash = SHA1_ML.sha1_file {filename = #source_path source}
    val project_deps =
      map (fn dep => package dep ^ ":" ^ logical_name dep ^ "@" ^ lookup_key keys dep)
        (direct_project_deps nodes node)
    val external_deps = map (fn name => "HOL:" ^ name ^ "@" ^ toolchain_key) (direct_external_theories nodes node)
    val external_libs = map (fn name => "HOLLIB:" ^ name ^ "@" ^ toolchain_key) (direct_external_libs nodes node)
    val policy = #policy source
    val declared_deps = HolbuildProject.action_deps policy
    val declared_loads = HolbuildProject.action_loads policy
    val declared_dep_lines = map (fn dep => "declared_dep=" ^ dep) declared_deps
    val declared_load_lines = map (fn dep => "declared_load=" ^ dep) declared_loads
    val extra_inputs = HolbuildProject.action_extra_inputs policy
    val extra_input_lines =
      map (fn input =>
             "extra_input=" ^ HolbuildProject.extra_input_path input ^ "@" ^
             file_hash (HolbuildProject.extra_input_absolute_path input))
          extra_inputs
    val lines =
      ["holbuild-action-v1",
       "toolchain=" ^ toolchain_key,
       "kind=" ^ kind_name source,
       "package=" ^ #package source,
       "logical=" ^ #logical_name source,
       "source=" ^ #relative_path source,
       "source-sha1=" ^ source_hash,
       "cache=" ^ bool_text (HolbuildProject.action_cache_enabled policy),
       "always_reexecute=" ^ bool_text (HolbuildProject.action_always_reexecute policy)] @
      config_lines @
      declared_dep_lines @
      declared_load_lines @
      extra_input_lines @
      map (fn dep => "dep=" ^ dep) (project_deps @ external_deps @ external_libs)
  in
    String.concatWith "\n" lines ^ "\n"
  end

fun add_input_key config_lines toolchain_key nodes (node, keys) =
  (key node, hash_text (action_text config_lines toolchain_key nodes keys node)) :: keys

fun input_keys config_lines toolchain_key nodes =
  List.foldl (fn (node, keys) => add_input_key config_lines toolchain_key nodes (node, keys)) [] nodes

fun input_key_for keys node = lookup_key keys node

fun print_external_deps nodes node =
  case direct_external_theories nodes node of
      [] => ()
    | deps => print ("  external theories: " ^ String.concatWith ", " deps ^ "\n")

fun print_external_libs nodes node =
  case direct_external_libs nodes node of
      [] => ()
    | deps => print ("  external libs: " ^ String.concatWith ", " deps ^ "\n")

fun print_project_deps nodes node =
  case direct_project_deps nodes node of
      [] => ()
    | deps => print ("  project deps: " ^
                     String.concatWith ", " (map logical_name deps) ^ "\n")

fun describe_node nodes keys node =
  (HolbuildSourceIndex.describe_source (source_of node);
   print ("  input_key: " ^ input_key_for keys node ^ "\n");
   print_project_deps nodes node;
   print_external_deps nodes node;
   print_external_libs nodes node)

fun describe config_lines toolchain_key nodes =
  let val keys = input_keys config_lines toolchain_key nodes
  in List.app (describe_node nodes keys) nodes end

end
