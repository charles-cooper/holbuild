structure HolbuildBuildPlan =
struct

exception Error of string

type node =
  { source : HolbuildSourceIndex.source,
    deps : HolbuildDependencies.t }

type t = node list

type keyed_node = {node : node, input_key : string}

fun source_of ({source, ...} : node) = source
fun deps_of ({deps, ...} : node) = deps
fun logical_name node = #logical_name (source_of node)
fun package node = #package (source_of node)
fun relative_path node = #relative_path (source_of node)
fun key node = package node ^ "\000" ^ relative_path node ^ "\000" ^ logical_name node

fun member value values = List.exists (fn x => x = value) values

fun add_unique (value, values) = if member value values then values else value :: values

fun unique_strings values = rev (List.foldl add_unique [] values)

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

fun direct_dependency_names node =
  unique_strings (#theories (deps_of node) @ #loads (deps_of node))

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
    unique_nodes (List.filter not_self (signature_companion_deps nodes node @ named_deps))
  end

fun direct_external_theories nodes node =
  let
    fun known name = not (null (nodes_named nodes name))
  in
    List.filter (fn name => not (known name)) (#theories (deps_of node))
  end

fun direct_unresolved_loads nodes node =
  let
    fun known name = not (null (nodes_named nodes name))
    fun unresolved name = not (known name) andalso not (theory_name name)
  in
    List.filter unresolved (#loads (deps_of node))
  end

fun reject_unresolved_loads nodes plan =
  let
    fun check node =
      case direct_unresolved_loads nodes node of
          [] => ()
        | load :: _ =>
            raise Error ("unresolved load " ^ load ^ " in " ^
                         package node ^ ":" ^ relative_path node)
  in
    List.app check plan
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

fun make_node source =
  {source = source, deps = HolbuildDependencies.extract (#source_path source)}

fun plan sources targets =
  let
    val nodes = map make_node sources
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

fun action_text toolchain_key nodes keys node =
  let
    val source = source_of node
    val source_hash = SHA1_ML.sha1_file {filename = #source_path source}
    val project_deps =
      map (fn dep => package dep ^ ":" ^ logical_name dep ^ "@" ^ lookup_key keys dep)
        (direct_project_deps nodes node)
    val external_deps = map (fn name => "HOL:" ^ name ^ "@" ^ toolchain_key) (direct_external_theories nodes node)
    val policy = #policy source
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
      extra_input_lines @
      map (fn dep => "dep=" ^ dep) (project_deps @ external_deps)
  in
    String.concatWith "\n" lines ^ "\n"
  end

fun add_input_key toolchain_key nodes (node, keys) =
  (key node, hash_text (action_text toolchain_key nodes keys node)) :: keys

fun input_keys toolchain_key nodes =
  List.foldl (fn (node, keys) => add_input_key toolchain_key nodes (node, keys)) [] nodes

fun input_key_for keys node = lookup_key keys node

fun print_external_deps nodes node =
  case direct_external_theories nodes node of
      [] => ()
    | deps => print ("  external theories: " ^ String.concatWith ", " deps ^ "\n")

fun print_project_deps nodes node =
  case direct_project_deps nodes node of
      [] => ()
    | deps => print ("  project deps: " ^
                     String.concatWith ", " (map logical_name deps) ^ "\n")

fun describe_node nodes keys node =
  (HolbuildSourceIndex.describe_source (source_of node);
   print ("  input_key: " ^ input_key_for keys node ^ "\n");
   print_project_deps nodes node;
   print_external_deps nodes node)

fun describe toolchain_key nodes =
  let val keys = input_keys toolchain_key nodes
  in List.app (describe_node nodes keys) nodes end

end
