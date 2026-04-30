structure HolbuildBuildPlan =
struct

structure Path = OS.Path
structure FS = OS.FileSys

exception Error of string

type node =
  { source : HolbuildSourceIndex.source,
    deps : HolbuildDependencies.t option ref,
    source_hash : string option ref,
    external_dirs : string list }

type t = node list

type keyed_node = {node : node, input_key : string}

fun source_of ({source, ...} : node) = source

fun source_hash_of ({source, source_hash, ...} : node) =
  case !source_hash of
      SOME hash => hash
    | NONE =>
        let val hash = HolbuildHash.file_sha1 (#source_path source)
        in source_hash := SOME hash; hash end

fun dependency_cache_path source =
  case #objects (#artifacts source) of
      object :: _ => object ^ ".deps"
    | [] => #source_path source ^ ".holbuild-deps"

fun deps_of (node as {source, deps, ...} : node) =
  case !deps of
      SOME value => value
    | NONE =>
      let
        val value = HolbuildDependencies.extract_cached_with_hash
                      {cache_path = dependency_cache_path source,
                       source_path = #source_path source,
                       source_hash = source_hash_of node}
      in deps := SOME value; value end
fun external_dirs_of ({external_dirs, ...} : node) = external_dirs
fun logical_name node = #logical_name (source_of node)
fun package node = #package (source_of node)
fun relative_path node = #relative_path (source_of node)
fun key node = package node ^ "\000" ^ relative_path node ^ "\000" ^ logical_name node

fun member value values = List.exists (fn x => x = value) values

fun add_unique (value, values) = if member value values then values else value :: values

fun unique_strings values = rev (List.foldl add_unique [] values)

fun normalize_path path = Path.mkCanonical path handle Path.InvalidArc => path

fun has_logical_name name node = logical_name node = name

fun nodes_named nodes name = List.filter (has_logical_name name) nodes

type name_index = (string * node list) Vector.vector

fun split_pairs xs =
  let
    fun loop left right rest =
      case rest of
          [] => (left, right)
        | [x] => (x :: left, right)
        | x :: y :: zs => loop (x :: left) (y :: right) zs
  in
    loop [] [] xs
  end

fun merge_pairs compare left right =
  case (left, right) of
      ([], _) => right
    | (_, []) => left
    | (l :: ls, r :: rs) =>
        if compare (l, r) <> GREATER then
          l :: merge_pairs compare ls right
        else
          r :: merge_pairs compare left rs

fun sort_pairs compare pairs =
  case pairs of
      [] => []
    | [_] => pairs
    | _ =>
      let val (left, right) = split_pairs pairs
      in merge_pairs compare (sort_pairs compare left) (sort_pairs compare right) end

fun compare_pair_key ((left, _), (right, _)) = String.compare(left, right)

fun build_name_index nodes =
  let
    val pairs = sort_pairs compare_pair_key (map (fn node => (logical_name node, node)) nodes)
    fun collect name acc rest =
      case rest of
          (name', node) :: more =>
            if name' = name then collect name (node :: acc) more
            else (name, rev acc) :: group rest
        | [] => [(name, rev acc)]
    and group rest =
      case rest of
          [] => []
        | (name, node) :: more => collect name [node] more
  in
    Vector.fromList (group pairs)
  end

fun indexed_nodes_named index name =
  let
    fun search lo hi =
      if lo > hi then []
      else
        let
          val mid = (lo + hi) div 2
          val (candidate, nodes) = Vector.sub(index, mid)
        in
          case String.compare(name, candidate) of
              LESS => search lo (mid - 1)
            | GREATER => search (mid + 1) hi
            | EQUAL => nodes
        end
  in
    search 0 (Vector.length index - 1)
  end

type key_index = (string * int) Vector.vector

fun build_key_index nodes =
  let
    fun enumerate _ [] = []
      | enumerate i (node :: rest) = (key node, i) :: enumerate (i + 1) rest
  in
    Vector.fromList (sort_pairs compare_pair_key (enumerate 0 nodes))
  end

fun indexed_key_id index node_key =
  let
    fun search lo hi =
      if lo > hi then raise Error ("internal missing node key: " ^ node_key)
      else
        let
          val mid = (lo + hi) div 2
          val (candidate, id) = Vector.sub(index, mid)
        in
          case String.compare(node_key, candidate) of
              LESS => search lo (mid - 1)
            | GREATER => search (mid + 1) hi
            | EQUAL => id
        end
  in
    search 0 (Vector.length index - 1)
  end

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

fun unique_nodes nodes =
  let
    fun add (node, kept) =
      if member (key node) (map key kept) then kept else node :: kept
  in
    rev (List.foldl add [] nodes)
  end

fun direct_holdep_project_deps_with lookup node =
  let
    val mentions = #holdep_mentions (deps_of node)
    fun not_self candidate = key candidate <> key node
  in
    unique_nodes (List.filter not_self (List.concat (map lookup mentions)))
  end

fun direct_holdep_project_deps nodes node =
  direct_holdep_project_deps_with (nodes_named nodes) node

fun readable_path path = FS.access(path, [FS.A_READ]) handle OS.SysErr _ => false

fun external_load_available node name =
  List.exists
    (fn dir => readable_path (Path.concat(dir, name ^ ".uo")) orelse
               readable_path (Path.concat(dir, name ^ ".ui")))
    (external_dirs_of node)

fun holdep_external_names_with lookup node =
  let
    fun known name = not (null (lookup name))
    fun external name = not (known name) andalso external_load_available node name
  in
    unique_strings (List.filter external (#holdep_mentions (deps_of node)))
  end

fun holdep_external_names nodes node =
  holdep_external_names_with (nodes_named nodes) node

fun raw_external_load_names_with lookup node =
  let
    fun known name = not (null (lookup name))
    fun external name = not (known name) andalso not (theory_name name) andalso
                        external_load_available node name
  in
    List.filter external (#loads (deps_of node))
  end

fun raw_external_load_names nodes node =
  raw_external_load_names_with (nodes_named nodes) node

fun signature_companion_deps_with lookup node =
  case #kind (source_of node) of
      HolbuildSourceIndex.Sml =>
        List.filter
          (fn candidate =>
              package candidate = package node andalso
              #kind (source_of candidate) = HolbuildSourceIndex.Sig)
          (lookup (logical_name node))
    | _ => []

fun signature_companion_deps nodes node =
  signature_companion_deps_with (nodes_named nodes) node

fun direct_project_deps_with lookup nodes node =
  let
    fun not_self candidate = key candidate <> key node
    val named_deps = List.concat (map lookup (direct_dependency_names node))
  in
    unique_nodes (List.filter not_self
                    (signature_companion_deps_with lookup node @ named_deps @
                     direct_holdep_project_deps_with lookup node))
  end

fun direct_project_deps nodes node =
  direct_project_deps_with (nodes_named nodes) nodes node

fun direct_external_theories_with lookup node =
  let
    fun known name = not (null (lookup name))
    val holdep_theories = List.filter theory_name (holdep_external_names_with lookup node)
    val loaded_theories = List.filter theory_name (#loads (deps_of node))
  in
    unique_strings (List.filter (fn name => not (known name))
                      (loaded_theories @ holdep_theories))
  end

fun direct_external_theories nodes node =
  direct_external_theories_with (nodes_named nodes) node

fun direct_external_libs_with lookup node =
  let
    fun known name = not (null (lookup name))
    val holdep_libs = List.filter (fn name => not (theory_name name)) (holdep_external_names_with lookup node)
  in
    unique_strings
      (List.filter (fn name => not (known name))
         (declared_load_names node @ holdep_libs @ raw_external_load_names_with lookup node))
  end

fun direct_external_libs nodes node =
  direct_external_libs_with (nodes_named nodes) node

fun direct_unresolved_loads_with lookup node =
  let
    fun known name = not (null (lookup name))
    fun unresolved name = not (known name) andalso not (theory_name name) andalso
                          not (external_load_available node name)
  in
    List.filter unresolved (#loads (deps_of node))
  end

fun direct_unresolved_loads nodes node =
  direct_unresolved_loads_with (nodes_named nodes) node

fun direct_unresolved_declared_deps_with lookup node =
  let
    fun known name = not (null (lookup name))
  in
    List.filter (fn name => not (known name)) (declared_dependency_names node)
  end

fun direct_unresolved_declared_deps nodes node =
  direct_unresolved_declared_deps_with (nodes_named nodes) node

fun reject_unresolved_loads_with lookup plan =
  let
    fun check_loads node =
      case direct_unresolved_loads_with lookup node of
          [] => ()
        | load :: _ =>
            raise Error ("unresolved load " ^ load ^ " in " ^
                         package node ^ ":" ^ relative_path node)
    fun check_declared_deps node =
      case direct_unresolved_declared_deps_with lookup node of
          [] => ()
        | dep :: _ =>
            raise Error ("unresolved action dependency " ^ dep ^ " in " ^
                         package node ^ ":" ^ relative_path node)
  in
    List.app (fn node => (check_loads node; check_declared_deps node)) plan
  end

fun reject_unresolved_loads nodes plan =
  reject_unresolved_loads_with (nodes_named nodes) plan

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

fun topo_sort_with lookup nodes roots =
  let
    val key_index = build_key_index nodes
    val visited = Array.array (length nodes, false)
    val active = Array.array (length nodes, false)
    fun node_id node = indexed_key_id key_index (key node)
    fun visit active_path node order =
      let val id = node_id node
      in
        if Array.sub(visited, id) then order
        else if Array.sub(active, id) then raise Error (cycle_message active_path node)
        else
          let
            val _ = Array.update(active, id, true)
            val deps = direct_project_deps_with lookup nodes node
            val order' = List.foldl (fn (dep, acc) => visit (node :: active_path) dep acc) order deps
            val _ = Array.update(active, id, false)
            val _ = Array.update(visited, id, true)
          in
            node :: order'
          end
      end
    val order = List.foldl (fn (root, acc) => visit [] root acc) [] roots
    val plan = rev order
  in
    reject_unresolved_loads_with lookup plan;
    reject_source_uses plan;
    plan
  end

fun topo_sort nodes roots =
  topo_sort_with (nodes_named nodes) nodes roots

fun transitive_project_deps nodes node = topo_sort nodes (direct_project_deps nodes node)

fun closure_external_theories nodes node =
  unique_strings
    (List.concat (map (direct_external_theories nodes)
       (transitive_project_deps nodes node @ [node])))

fun closure_external_libs nodes node =
  unique_strings
    (List.concat (map (direct_external_libs nodes)
       (transitive_project_deps nodes node @ [node])))

fun make_node external_dirs source =
  {source = source,
   deps = ref NONE,
   source_hash = ref NONE,
   external_dirs = external_dirs}

fun plan holdir sources targets =
  let
    val external_dirs = [normalize_path (Path.concat(holdir, "sigobj"))]
    val nodes = map (make_node external_dirs) sources
    val index = build_name_index nodes
    val lookup = indexed_nodes_named index
    val roots =
      case targets of
          [] => nodes
        | _ => List.concat (map (fn target =>
                   case lookup target of
                       [] => raise Error ("unknown build target: " ^ target)
                     | matches => matches)
                 targets)
  in
    topo_sort_with lookup nodes roots
  end

fun kind_name source = HolbuildSourceIndex.kind_string (#kind source)

fun readable path = OS.FileSys.access(path, [OS.FileSys.A_READ]) handle OS.SysErr _ => false

fun file_hash path =
  if readable path then HolbuildHash.file_sha1 path
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

fun action_text_with lookup config_lines_for_node toolchain_key nodes keys node =
  let
    val source = source_of node
    val source_hash = source_hash_of node
    val project_deps =
      map (fn dep => package dep ^ ":" ^ logical_name dep ^ "@" ^ lookup_key keys dep)
        (direct_project_deps_with lookup nodes node)
    val external_deps = map (fn name => "HOL:" ^ name ^ "@" ^ toolchain_key) (direct_external_theories_with lookup node)
    val external_libs = map (fn name => "HOLLIB:" ^ name ^ "@" ^ toolchain_key) (direct_external_libs_with lookup node)
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
      config_lines_for_node node @
      declared_dep_lines @
      declared_load_lines @
      extra_input_lines @
      map (fn dep => "dep=" ^ dep) (project_deps @ external_deps @ external_libs)
  in
    String.concatWith "\n" lines ^ "\n"
  end

fun action_text config_lines_for_node toolchain_key nodes keys node =
  action_text_with (nodes_named nodes) config_lines_for_node toolchain_key nodes keys node

fun add_input_key_with lookup config_lines_for_node toolchain_key nodes (node, keys) =
  (key node, hash_text (action_text_with lookup config_lines_for_node toolchain_key nodes keys node)) :: keys

fun add_input_key config_lines_for_node toolchain_key nodes (node, keys) =
  add_input_key_with (nodes_named nodes) config_lines_for_node toolchain_key nodes (node, keys)

fun input_keys_with lookup config_lines_for_node toolchain_key nodes =
  List.foldl (fn (node, keys) => add_input_key_with lookup config_lines_for_node toolchain_key nodes (node, keys)) [] nodes

fun input_keys config_lines_for_node toolchain_key nodes =
  input_keys_with (nodes_named nodes) config_lines_for_node toolchain_key nodes

fun input_key_for keys node = lookup_key keys node

fun print_external_deps_with lookup node =
  case direct_external_theories_with lookup node of
      [] => ()
    | deps => print ("  external theories: " ^ String.concatWith ", " deps ^ "\n")

fun print_external_deps nodes node =
  print_external_deps_with (nodes_named nodes) node

fun print_external_libs_with lookup node =
  case direct_external_libs_with lookup node of
      [] => ()
    | deps => print ("  external libs: " ^ String.concatWith ", " deps ^ "\n")

fun print_external_libs nodes node =
  print_external_libs_with (nodes_named nodes) node

fun print_project_deps_with lookup nodes node =
  case direct_project_deps_with lookup nodes node of
      [] => ()
    | deps => print ("  project deps: " ^
                     String.concatWith ", " (map logical_name deps) ^ "\n")

fun print_project_deps nodes node =
  print_project_deps_with (nodes_named nodes) nodes node

fun describe_node_with lookup nodes keys node =
  (HolbuildSourceIndex.describe_source (source_of node);
   print ("  input_key: " ^ input_key_for keys node ^ "\n");
   print_project_deps_with lookup nodes node;
   print_external_deps_with lookup node;
   print_external_libs_with lookup node)

fun describe_node nodes keys node =
  describe_node_with (nodes_named nodes) nodes keys node

fun describe config_lines_for_node toolchain_key nodes =
  let
    val lookup = indexed_nodes_named (build_name_index nodes)
    val keys = input_keys_with lookup config_lines_for_node toolchain_key nodes
  in
    List.app (describe_node_with lookup nodes keys) nodes
  end

end
