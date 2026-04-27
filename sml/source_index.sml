structure HolbuildSourceIndex =
struct

structure Path = OS.Path
structure FS = OS.FileSys

exception Error of string

datatype kind = TheoryScript | Sml | Sig

type artifacts =
  { generated : string list,
    objects : string list,
    theory_data : string list }

type source =
  { kind : kind,
    logical_name : string,
    source_path : string,
    relative_path : string,
    artifacts : artifacts }

type t = source list

fun has_suffix suffix s =
  let
    val n = size s
    val m = size suffix
  in
    n >= m andalso String.substring(s, n - m, m) = suffix
  end

fun drop_suffix suffix s =
  if has_suffix suffix s then String.substring(s, 0, size s - size suffix)
  else raise Error ("expected suffix " ^ suffix ^ " in " ^ s)

fun join root rel = if rel = "" then root else Path.concat(root, rel)

fun relative_path root path =
  let
    val root' = if has_suffix "/" root then root else root ^ "/"
  in
    if String.isPrefix root' path then String.extract(path, size root', NONE)
    else path
  end

fun dirname rel = #dir (Path.splitDirFile rel)
fun filename rel = #file (Path.splitDirFile rel)

fun obj_path root rel ext =
  let val {base, ...} = Path.splitBaseExt rel
  in join root (join ".hol/obj" (base ^ ext)) end

fun gen_path root rel name ext = join root (join ".hol/gen" (join (dirname rel) (name ^ ext)))
fun theory_obj_path root rel name ext = join root (join ".hol/obj" (join (dirname rel) (name ^ ext)))
fun dat_path root rel name = theory_obj_path root rel name ".dat"

fun theory_artifacts root rel theory =
  { generated = [gen_path root rel theory ".sig", gen_path root rel theory ".sml"],
    objects = [obj_path root rel ".uo", theory_obj_path root rel theory ".ui",
               theory_obj_path root rel theory ".uo"],
    theory_data = [dat_path root rel theory] }

fun sml_artifacts root rel =
  { generated = [], objects = [obj_path root rel ".uo"], theory_data = [] }

fun sig_artifacts root rel =
  { generated = [], objects = [obj_path root rel ".ui"], theory_data = [] }

fun classify root abs_path =
  let
    val rel = relative_path root abs_path
    val file = filename rel
  in
    if has_suffix "Script.sml" file then
      let
        val theory = drop_suffix "Script.sml" file ^ "Theory"
      in
        SOME {kind = TheoryScript,
              logical_name = theory,
              source_path = abs_path,
              relative_path = rel,
              artifacts = theory_artifacts root rel theory}
      end
    else if has_suffix ".sml" file then
      SOME {kind = Sml,
            logical_name = drop_suffix ".sml" file,
            source_path = abs_path,
            relative_path = rel,
            artifacts = sml_artifacts root rel}
    else if has_suffix ".sig" file then
      SOME {kind = Sig,
            logical_name = drop_suffix ".sig" file,
            source_path = abs_path,
            relative_path = rel,
            artifacts = sig_artifacts root rel}
    else NONE
  end

fun is_dir path = FS.isDir path handle OS.SysErr _ => false
fun is_readable path = FS.access(path, [FS.A_READ]) handle OS.SysErr _ => false

fun skip_dir name = name = ".hol" orelse name = ".git" orelse name = "_build"

fun list_dir path =
  let
    val stream = FS.openDir path
    fun loop acc =
      case FS.readDir stream of
          NONE => rev acc before FS.closeDir stream
        | SOME name => loop (name :: acc)
  in
    loop [] handle e => (FS.closeDir stream; raise e)
  end

fun scan_file root path acc =
  case classify root path of
      NONE => acc
    | SOME source => source :: acc

fun scan_dir root path acc =
  let
    fun scan_name (name, acc) =
      let val path' = join path name
      in
        if is_dir path' then
          if skip_dir name then acc else scan_dir root path' acc
        else if is_readable path' then scan_file root path' acc
        else acc
      end
  in
    List.foldl scan_name acc (list_dir path)
  end

fun compare_source (a : source, b : source) =
  String.compare(#relative_path a, #relative_path b)

fun compatible_same_name (a : source) (b : source) =
  case (#kind a, #kind b) of
      (Sml, Sig) => true
    | (Sig, Sml) => true
    | _ => false

fun by_logical sources =
  let
    fun conflicts source other =
      #logical_name source = #logical_name other andalso
      not (compatible_same_name source other)
    fun insert (source, seen) =
      case List.find (conflicts source) seen of
          NONE => source :: seen
        | SOME other =>
            raise Error ("duplicate logical name " ^ #logical_name source ^ ": " ^
                         #relative_path other ^ " and " ^ #relative_path source)
  in
    ignore (List.foldl insert [] sources);
    sources
  end

fun insert_sorted source sources =
  case sources of
      [] => [source]
    | x :: xs =>
        if compare_source(source, x) = LESS then source :: sources
        else x :: insert_sorted source xs

fun sort_sources sources = List.foldl (fn (source, acc) => insert_sorted source acc) [] sources

fun discover (project : HolbuildProject.t) =
  let
    val root = #root project
    val members = map (HolbuildProject.abs_member project) (#members project)
    val sources =
      List.foldl
        (fn (member, acc) =>
            if is_dir member then scan_dir root member acc
            else if is_readable member then scan_file root member acc
            else raise Error ("member does not exist: " ^ member))
        []
        members
  in
    by_logical (sort_sources sources)
  end

fun kind_string kind =
  case kind of
      TheoryScript => "theory"
    | Sml => "sml"
    | Sig => "sig"

fun print_list label values =
  case values of
      [] => ()
    | _ => print ("  " ^ label ^ ": " ^ String.concatWith ", " values ^ "\n")

fun describe_source ({kind, logical_name, relative_path,
                      artifacts = {generated, objects, theory_data}, ...} : source) =
  (print (logical_name ^ " (" ^ kind_string kind ^ ")\n");
   print ("  source: " ^ relative_path ^ "\n");
   print_list "generated" generated;
   print_list "objects" objects;
   print_list "theory_data" theory_data)

fun describe sources = List.app describe_source sources

fun select_targets sources targets =
  case targets of
      [] => sources
    | _ =>
      let
        fun source_named target (source : source) = #logical_name source = target
        fun find target =
          case List.filter (source_named target) sources of
              [] => raise Error ("unknown build target: " ^ target)
            | matches => matches
      in
        List.concat (map find targets)
      end

end
