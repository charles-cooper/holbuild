structure HolbuildBuildExec =
struct

structure Path = OS.Path
structure FS = OS.FileSys

exception Error of string

fun has_suffix suffix s =
  let
    val n = size s
    val m = size suffix
  in
    n >= m andalso String.substring(s, n - m, m) = suffix
  end

fun ensure_dir path =
  if path = "" orelse path = "." then ()
  else if FS.access(path, []) handle OS.SysErr _ => false then ()
  else (ensure_dir (Path.dir path); FS.mkDir path handle OS.SysErr _ => ())

fun ensure_parent path = ensure_dir (Path.dir path)

fun copy_binary src dst =
  let
    val input = BinIO.openIn src
      handle e => raise Error ("could not read " ^ src ^ ": " ^ General.exnMessage e)
    val _ = ensure_parent dst
    val output = BinIO.openOut dst
      handle e => (BinIO.closeIn input; raise Error ("could not write " ^ dst ^ ": " ^ General.exnMessage e))
    fun loop () =
      let val chunk = BinIO.inputN(input, 65536)
      in
        if Word8Vector.length chunk = 0 then ()
        else (BinIO.output(output, chunk); loop ())
      end
  in
    loop ();
    BinIO.closeIn input;
    BinIO.closeOut output
  end

fun read_text path =
  let val input = TextIO.openIn path
  in TextIO.inputAll input before TextIO.closeIn input end

fun write_text path text =
  let
    val _ = ensure_parent path
    val output = TextIO.openOut path
  in TextIO.output(output, text); TextIO.closeOut output end

fun replace_all needle replacement text =
  let
    val needle_len = size needle
    val text_len = size text
    fun loop i acc =
      if i >= text_len then String.concat (rev acc)
      else if i + needle_len <= text_len andalso
              String.substring(text, i, needle_len) = needle then
        loop (i + needle_len) (replacement :: acc)
      else
        loop (i + 1) (String.str (String.sub(text, i)) :: acc)
  in
    if needle = "" then text else loop 0 []
  end

fun copy_rewriting_path {src, dst, old_path, new_path} =
  write_text dst (replace_all old_path new_path (read_text src))

fun source_file node = #source_path (HolbuildBuildPlan.source_of node)
fun source_artifacts node = #artifacts (HolbuildBuildPlan.source_of node)
fun logical_name node = HolbuildBuildPlan.logical_name node

fun one_with_suffix suffix paths =
  case List.filter (has_suffix suffix) paths of
      [path] => path
    | [] => raise Error ("missing expected " ^ suffix ^ " output")
    | _ => raise Error ("multiple " ^ suffix ^ " outputs")

fun script_base node =
  let val name = Path.file (source_file node)
  in HolbuildSourceIndex.drop_suffix ".sml" name end

fun write_manifest path lines = write_text path (String.concatWith "\n" lines ^ "\n")

fun dependency_sml dep = one_with_suffix ".sml" (#generated (source_artifacts dep))
fun dependency_sig dep = one_with_suffix ".sig" (#generated (source_artifacts dep))

fun load_theory_line name = "load " ^ HolbuildToolchain.sml_string name ^ ";"

fun use_generated_lines dep =
  ["use " ^ HolbuildToolchain.sml_string (dependency_sig dep) ^ ";",
   "use " ^ HolbuildToolchain.sml_string (dependency_sml dep) ^ ";"]

fun save_heap_line output =
  "val _ = PolyML.SaveState.saveChild(" ^
  HolbuildToolchain.sml_string output ^
  ", length (PolyML.SaveState.showHierarchy()));"

fun write_preload plan node path =
  let
    val external_deps = HolbuildBuildPlan.closure_external_theories plan node
    val project_deps = HolbuildBuildPlan.transitive_project_deps plan node
    val lines = map load_theory_line external_deps @
                List.concat (map use_generated_lines project_deps)
  in
    write_text path (String.concatWith "\n" lines ^ "\n")
  end

fun write_final_context_loader {sig_path, sml_path, output, path} =
  let
    val lines =
      ["use " ^ HolbuildToolchain.sml_string sig_path ^ ";",
       "use " ^ HolbuildToolchain.sml_string sml_path ^ ";",
       save_heap_line output]
  in
    write_text path (String.concatWith "\n" lines ^ "\n")
  end

fun generated_outputs node =
  let val generated = #generated (source_artifacts node)
  in {sig_path = one_with_suffix ".sig" generated,
      sml_path = one_with_suffix ".sml" generated}
  end

fun theory_outputs node =
  let
    val {sig_path, sml_path} = generated_outputs node
    val data_path = one_with_suffix ".dat" (#theory_data (source_artifacts node))
    val objects = #objects (source_artifacts node)
  in
    {sig_path = sig_path, sml_path = sml_path, data_path = data_path,
     script_uo = one_with_suffix (script_base node ^ ".uo") objects,
     theory_ui = one_with_suffix ".ui" objects,
     theory_uo = one_with_suffix (logical_name node ^ ".uo") objects}
  end

fun stage_dir (project : HolbuildProject.t) input_key =
  Path.concat(Path.concat(#root project, ".hol/stage"), input_key)

fun staged_theory_file stage node ext = Path.concat(Path.concat(stage, ".hol/objs"), logical_name node ^ ext)
fun staged_dat_reference stage node = Path.concat(stage, logical_name node ^ ".dat")

fun checkpoint_base (project : HolbuildProject.t) node =
  Path.concat(Path.concat(Path.concat(#root project, ".hol/checkpoints"),
                          HolbuildBuildPlan.package node),
              HolbuildBuildPlan.relative_path node)

fun final_context_path project node = checkpoint_base project node ^ ".final_context.save"

fun remove_tree path =
  ignore (OS.Process.system ("rm -rf " ^ HolbuildToolchain.quote path))

fun run_hol_files tc stage holstate files error_message =
  let
    val status =
      HolbuildToolchain.run_in_dir stage
        ([HolbuildToolchain.hol tc, "run", "--noconfig", "--holstate", holstate] @ files)
  in
    if HolbuildToolchain.success status then ()
    else raise Error error_message
  end

fun build_theory tc project plan keys node =
  let
    val input_key = HolbuildBuildPlan.input_key_for keys node
    val stage = stage_dir project input_key
    val staged_script = Path.concat(stage, Path.file (source_file node))
    val preload = Path.concat(stage, "holbuild-preload.sml")
    val final_loader = Path.concat(stage, "holbuild-save-final-context.sml")
    val final_context = final_context_path project node
    val {sig_path, sml_path, data_path, script_uo, theory_ui, theory_uo} = theory_outputs node
    val staged_sig = staged_theory_file stage node ".sig"
    val staged_sml = staged_theory_file stage node ".sml"
    val staged_dat = staged_theory_file stage node ".dat"
    val _ = ensure_dir stage
    val _ = copy_binary (source_file node) staged_script
    val _ = ensure_parent final_context
    val _ = write_preload plan node preload
    val _ = write_final_context_loader
              {sig_path = staged_sig, sml_path = staged_sml,
               output = final_context, path = final_loader}
    val _ = run_hol_files tc stage (HolbuildToolchain.base_state tc)
              [preload, staged_script, final_loader]
              "hol run failed while building theory script"
    val load_data_path = data_path ^ ".load"
    val _ = copy_binary staged_dat data_path
    val _ = copy_binary staged_dat load_data_path
    val _ = copy_binary staged_sig sig_path
    val _ = copy_rewriting_path {src = staged_sml, dst = sml_path,
                                 old_path = staged_dat_reference stage node,
                                 new_path = load_data_path}
    val deps = HolbuildBuildPlan.direct_project_deps plan node
  in
    write_manifest theory_ui [sig_path];
    write_manifest theory_uo (map dependency_sml deps @ [sml_path]);
    write_manifest script_uo [source_file node];
    remove_tree stage
  end

fun build_sml_like node output_suffix =
  let
    val output = one_with_suffix output_suffix (#objects (source_artifacts node))
  in
    write_manifest output [source_file node]
  end

fun metadata_path (project : HolbuildProject.t) node =
  let
    val source = HolbuildBuildPlan.source_of node
    val base = Path.concat(Path.concat(#root project, ".hol/dep"), #package source)
  in
    Path.concat(base, #relative_path source ^ ".key")
  end

fun file_exists path = FS.access(path, [FS.A_READ]) handle OS.SysErr _ => false

fun output_paths project node =
  let val artifacts = source_artifacts node
      val base = #generated artifacts @ #objects artifacts @ #theory_data artifacts
  in
    case #kind (HolbuildBuildPlan.source_of node) of
        HolbuildSourceIndex.TheoryScript =>
          final_context_path project node ::
          (one_with_suffix ".dat" (#theory_data artifacts) ^ ".load") :: base
      | _ => base
  end

fun current_metadata path = SOME (read_text path) handle IO.Io _ => NONE

fun metadata_text input_key = "input_key=" ^ input_key ^ "\n"

fun up_to_date project input_key node =
  current_metadata (metadata_path project node) = SOME (metadata_text input_key) andalso
  List.all file_exists (output_paths project node)

fun write_metadata project input_key node =
  write_text (metadata_path project node) (metadata_text input_key)

fun build_node tc project plan keys node =
  let val input_key = HolbuildBuildPlan.input_key_for keys node
  in
    if up_to_date project input_key node then
      print (HolbuildBuildPlan.logical_name node ^ " is up to date\n")
    else
      (case #kind (HolbuildBuildPlan.source_of node) of
           HolbuildSourceIndex.TheoryScript => build_theory tc project plan keys node
         | HolbuildSourceIndex.Sml => build_sml_like node ".uo"
         | HolbuildSourceIndex.Sig => build_sml_like node ".ui";
       write_metadata project input_key node)
  end

fun build tc project plan toolchain_key =
  let val keys = HolbuildBuildPlan.input_keys toolchain_key plan
  in List.app (build_node tc project plan keys) plan end

end
