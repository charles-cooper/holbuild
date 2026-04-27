structure HolbuildBuildPlan =
struct

exception Error of string

type node =
  { source : HolbuildSourceIndex.source,
    deps : HolbuildDependencies.t }

type t = node list

fun source_of ({source, ...} : node) = source
fun deps_of ({deps, ...} : node) = deps
fun logical_name node = #logical_name (source_of node)
fun relative_path node = #relative_path (source_of node)
fun key node = relative_path node ^ "\000" ^ logical_name node

fun member value values = List.exists (fn x => x = value) values

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

fun direct_theory_names node = #theories (deps_of node)

fun direct_project_deps nodes node =
  let
    fun candidates name = nodes_named nodes name
    fun not_self candidate = key candidate <> key node
  in
    List.filter not_self (List.concat (map candidates (direct_theory_names node)))
  end

fun direct_external_theories nodes node =
  let
    fun known name = not (null (nodes_named nodes name))
  in
    List.filter (fn name => not (known name)) (direct_theory_names node)
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
  in
    rev order
  end

fun make_node source =
  {source = source, deps = HolbuildDependencies.extract (#source_path source)}

fun plan sources targets =
  let
    val nodes = map make_node sources
    val roots = selected_nodes nodes targets
  in
    topo_sort nodes roots
  end

fun print_external_deps nodes node =
  case direct_external_theories nodes node of
      [] => ()
    | deps => print ("  external theories: " ^ String.concatWith ", " deps ^ "\n")

fun print_project_deps nodes node =
  case direct_project_deps nodes node of
      [] => ()
    | deps => print ("  project deps: " ^
                     String.concatWith ", " (map logical_name deps) ^ "\n")

fun describe_node nodes node =
  (HolbuildSourceIndex.describe_source (source_of node);
   print_project_deps nodes node;
   print_external_deps nodes node)

fun describe nodes = List.app (describe_node nodes) nodes

end
