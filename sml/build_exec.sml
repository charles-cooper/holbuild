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

fun temp_near path =
  Path.concat(Path.dir path,
              "." ^ Path.file path ^ "." ^ Path.file (FS.tmpName ()) ^ ".tmp")

fun remove_file path = FS.remove path handle OS.SysErr _ => ()

fun rename_replace {old, new} =
  FS.rename {old = old, new = new}
  handle OS.SysErr _ =>
    (FS.remove new handle OS.SysErr _ => ();
     FS.rename {old = old, new = new})

fun copy_binary src dst =
  let
    val input = BinIO.openIn src
      handle e => raise Error ("could not read " ^ src ^ ": " ^ General.exnMessage e)
    val _ = ensure_parent dst
    val tmp = temp_near dst
    val output = BinIO.openOut tmp
      handle e => (BinIO.closeIn input; raise Error ("could not write " ^ dst ^ ": " ^ General.exnMessage e))
    fun close_input () = BinIO.closeIn input handle _ => ()
    fun close_output () = BinIO.closeOut output handle _ => ()
    fun loop () =
      let val chunk = BinIO.inputN(input, 65536)
      in
        if Word8Vector.length chunk = 0 then ()
        else (BinIO.output(output, chunk); loop ())
      end
  in
    (loop ();
     BinIO.closeIn input;
     BinIO.closeOut output;
     rename_replace {old = tmp, new = dst})
    handle e => (close_input (); close_output (); remove_file tmp; raise e)
  end

fun read_text path =
  let val input = TextIO.openIn path
  in TextIO.inputAll input before TextIO.closeIn input end

fun write_text path text =
  let
    val _ = ensure_parent path
    val tmp = temp_near path
    val output = TextIO.openOut tmp
      handle e => raise Error ("could not write " ^ path ^ ": " ^ General.exnMessage e)
    fun close_output () = TextIO.closeOut output handle _ => ()
  in
    (TextIO.output(output, text);
     TextIO.closeOut output;
     rename_replace {old = tmp, new = path})
    handle e => (close_output (); remove_file tmp; raise e)
  end

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

fun write_preload plan node deps_loaded path =
  let
    val external_deps = HolbuildBuildPlan.closure_external_theories plan node
    val project_deps = HolbuildBuildPlan.transitive_project_deps plan node
    val lines = map load_theory_line external_deps @
                List.concat (map use_generated_lines project_deps) @
                [save_heap_line deps_loaded]
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

fun deps_loaded_path project node = checkpoint_base project node ^ ".deps_loaded.save"
fun final_context_path project node = checkpoint_base project node ^ ".final_context.save"

fun remove_tree path =
  ignore (OS.Process.system ("rm -rf " ^ HolbuildToolchain.quote path))

fun file_exists path = FS.access(path, [FS.A_READ]) handle OS.SysErr _ => false

fun file_hash path = SHA1_ML.sha1_file {filename = path}

fun current_metadata path = SOME (read_text path) handle IO.Io _ => NONE

fun run_hol_files tc stage holstate files error_message =
  let
    val status =
      HolbuildToolchain.run_in_dir stage
        ([HolbuildToolchain.hol tc, "run", "--noconfig", "--holstate", holstate] @ files)
  in
    if HolbuildToolchain.success status then ()
    else raise Error error_message
  end

val cache_sml_token = "__HOLBUILD_THEORY_DAT_LOAD__"

fun warn msg = TextIO.output(TextIO.stdErr, "holbuild: warning: " ^ msg ^ "\n")

fun cache_root () = HolbuildCache.cache_root ()

fun file_hash_matches path hash =
  file_exists path andalso file_hash path = hash
  handle _ => false

fun cache_blob root path =
  let
    val hash = file_hash path
    val blob = HolbuildCache.blob_path root hash
  in
    if file_hash_matches blob hash then () else copy_binary path blob;
    hash
  end

fun cache_manifest_text {input_key, sig_hash, sml_hash, dat_hash} =
  String.concatWith "\n"
    ["holbuild-cache-action-v1",
     "input_key=" ^ input_key,
     "kind=theory",
     "blob sig " ^ sig_hash,
     "blob sml-template " ^ sml_hash,
     "blob dat " ^ dat_hash] ^ "\n"

fun blob_line role line =
  case String.tokens Char.isSpace line of
      ["blob", role', hash] => if role = role' then SOME hash else NONE
    | _ => NONE

fun first_some f values =
  case values of
      [] => NONE
    | x :: xs =>
        case f x of
            SOME y => SOME y
          | NONE => first_some f xs

fun required_blob role lines =
  case first_some (blob_line role) lines of
      SOME hash => hash
    | NONE => raise Error ("cache manifest missing blob role: " ^ role)

fun cache_manifest_lines text = String.tokens (fn c => c = #"\n") text

fun require_manifest_line expected lines =
  if List.exists (fn line => line = expected) lines then ()
  else raise Error ("cache manifest missing line: " ^ expected)

fun cache_manifest_blobs_from_lines input_key lines =
  let
    val _ = require_manifest_line "holbuild-cache-action-v1" lines
    val _ = require_manifest_line ("input_key=" ^ input_key) lines
    val _ = require_manifest_line "kind=theory" lines
  in
    {sig_hash = required_blob "sig" lines,
     sml_hash = required_blob "sml-template" lines,
     dat_hash = required_blob "dat" lines}
  end

fun cache_manifest_blobs root input_key =
  let val manifest = HolbuildCache.action_manifest root input_key
  in cache_manifest_blobs_from_lines input_key (cache_manifest_lines (read_text manifest)) end

fun cache_entry_usable root input_key text =
  let
    val {sig_hash, sml_hash, dat_hash} =
      cache_manifest_blobs_from_lines input_key (cache_manifest_lines text)
  in
    file_hash_matches (HolbuildCache.blob_path root sig_hash) sig_hash andalso
    file_hash_matches (HolbuildCache.blob_path root sml_hash) sml_hash andalso
    file_hash_matches (HolbuildCache.blob_path root dat_hash) dat_hash
  end
  handle _ => false

fun copy_blob root hash dst =
  let val blob = HolbuildCache.blob_path root hash
  in
    if file_hash_matches blob hash then
      (copy_binary blob dst;
       if file_hash_matches dst hash then ()
       else raise Error ("cache materialization hash mismatch: " ^ hash))
    else raise Error ("cache blob missing or corrupt: " ^ hash)
  end

fun publish_theory_cache input_key staged_dat_ref staged_sig staged_sml staged_dat =
  let
    val root = cache_root ()
    val _ = HolbuildCache.ensure_layout root
    val template = FS.tmpName ()
    fun cleanup () = FS.remove template handle OS.SysErr _ => ()
    fun publish () =
      let
        val _ = write_text template (replace_all staged_dat_ref cache_sml_token (read_text staged_sml))
        val sig_hash = cache_blob root staged_sig
        val sml_hash = cache_blob root template
        val dat_hash = cache_blob root staged_dat
        val manifest = cache_manifest_text {input_key = input_key, sig_hash = sig_hash,
                                            sml_hash = sml_hash, dat_hash = dat_hash}
        val manifest_path = HolbuildCache.action_manifest root input_key
        val existing = current_metadata manifest_path
      in
        case existing of
            SOME old =>
              if old = manifest then ()
              else if cache_entry_usable root input_key old then
                warn ("cache entry already exists with different outputs: " ^ input_key)
              else
                write_text manifest_path manifest
          | NONE => write_text manifest_path manifest
      end
  in
    (publish (); cleanup ())
    handle e => (cleanup (); warn ("could not publish cache entry: " ^ General.exnMessage e))
  end

fun write_local_theory_manifests plan node =
  let
    val {sig_path, sml_path, script_uo, theory_ui, theory_uo, ...} = theory_outputs node
    val deps = HolbuildBuildPlan.direct_project_deps plan node
  in
    write_manifest theory_ui [sig_path];
    write_manifest theory_uo (map dependency_sml deps @ [sml_path]);
    write_manifest script_uo [source_file node]
  end

fun save_cached_theory_checkpoints tc project plan input_key node =
  let
    val stage = stage_dir project input_key
    val preload = Path.concat(stage, "holbuild-cache-preload.sml")
    val final_loader = Path.concat(stage, "holbuild-cache-save-final-context.sml")
    val deps_loaded = deps_loaded_path project node
    val final_context = final_context_path project node
    val {sig_path, sml_path, ...} = theory_outputs node
  in
    ensure_dir stage;
    ensure_parent deps_loaded;
    ensure_parent final_context;
    write_preload plan node deps_loaded preload;
    write_final_context_loader {sig_path = sig_path, sml_path = sml_path,
                                output = final_context, path = final_loader};
    run_hol_files tc stage (HolbuildToolchain.base_state tc) [preload, final_loader]
      "hol run failed while saving cached theory checkpoints";
    remove_tree stage
  end

fun materialize_theory_cache tc project plan input_key node =
  let
    val root = cache_root ()
    val manifest = HolbuildCache.action_manifest root input_key
    val _ = if file_exists manifest then () else raise Error "cache entry not found"
    val _ = FS.setTime (manifest, NONE) handle OS.SysErr _ => ()
    val {sig_hash, sml_hash, dat_hash} = cache_manifest_blobs root input_key
    val {sig_path, sml_path, data_path, ...} = theory_outputs node
    val load_data_path = data_path ^ ".load"
    val template = FS.tmpName ()
    fun cleanup () = FS.remove template handle OS.SysErr _ => ()
    fun install () =
      (copy_blob root dat_hash data_path;
       copy_blob root dat_hash load_data_path;
       copy_blob root sig_hash sig_path;
       copy_blob root sml_hash template;
       write_text sml_path (replace_all cache_sml_token load_data_path (read_text template));
       write_local_theory_manifests plan node;
       save_cached_theory_checkpoints tc project plan input_key node;
       print (logical_name node ^ " restored from cache\n");
       true)
  in
    (install () before cleanup ()) handle e => (cleanup (); raise e)
  end
  handle Error "cache entry not found" => false
       | e => (warn ("cache entry unusable for " ^ logical_name node ^ ": " ^ General.exnMessage e); false)

fun build_theory tc project plan keys node =
  let
    val input_key = HolbuildBuildPlan.input_key_for keys node
    val stage = stage_dir project input_key
    val staged_script = Path.concat(stage, Path.file (source_file node))
    val preload = Path.concat(stage, "holbuild-preload.sml")
    val final_loader = Path.concat(stage, "holbuild-save-final-context.sml")
    val deps_loaded = deps_loaded_path project node
    val final_context = final_context_path project node
    val {sig_path, sml_path, data_path, script_uo, theory_ui, theory_uo} = theory_outputs node
    val staged_sig = staged_theory_file stage node ".sig"
    val staged_sml = staged_theory_file stage node ".sml"
    val staged_dat = staged_theory_file stage node ".dat"
    val _ = ensure_dir stage
    val _ = copy_binary (source_file node) staged_script
    val _ = ensure_parent deps_loaded
    val _ = ensure_parent final_context
    val _ = write_preload plan node deps_loaded preload
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
    val _ = publish_theory_cache input_key (staged_dat_reference stage node) staged_sig staged_sml staged_dat
  in
    write_local_theory_manifests plan node;
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

fun output_paths project node =
  let val artifacts = source_artifacts node
      val base = #generated artifacts @ #objects artifacts @ #theory_data artifacts
  in
    case #kind (HolbuildBuildPlan.source_of node) of
        HolbuildSourceIndex.TheoryScript =>
          deps_loaded_path project node :: final_context_path project node ::
          (one_with_suffix ".dat" (#theory_data artifacts) ^ ".load") :: base
      | _ => base
  end

fun output_hash_line path = "output-sha1=" ^ path ^ " " ^ file_hash path

fun checkpoint_lines project node =
  case #kind (HolbuildBuildPlan.source_of node) of
      HolbuildSourceIndex.TheoryScript =>
        ["deps_loaded=" ^ deps_loaded_path project node,
         "final_context=" ^ final_context_path project node]
    | _ => []

fun metadata_text project input_key toolchain_key node =
  let
    val source = HolbuildBuildPlan.source_of node
    val lines =
      ["holbuild-action-metadata-v1",
       "input_key=" ^ input_key,
       "toolchain_key=" ^ toolchain_key,
       "kind=" ^ HolbuildSourceIndex.kind_string (#kind source),
       "package=" ^ #package source,
       "logical=" ^ #logical_name source,
       "source=" ^ #relative_path source] @
      checkpoint_lines project node @
      map output_hash_line (output_paths project node)
  in
    String.concatWith "\n" lines ^ "\n"
  end

fun up_to_date project input_key toolchain_key node =
  List.all file_exists (output_paths project node) andalso
  current_metadata (metadata_path project node) =
    SOME (metadata_text project input_key toolchain_key node)

fun write_metadata project input_key toolchain_key node =
  write_text (metadata_path project node) (metadata_text project input_key toolchain_key node)

fun build_node tc project plan keys toolchain_key node =
  let val input_key = HolbuildBuildPlan.input_key_for keys node
  in
    if up_to_date project input_key toolchain_key node then
      print (HolbuildBuildPlan.logical_name node ^ " is up to date\n")
    else
      (case #kind (HolbuildBuildPlan.source_of node) of
           HolbuildSourceIndex.TheoryScript =>
             if materialize_theory_cache tc project plan input_key node then ()
             else build_theory tc project plan keys node
         | HolbuildSourceIndex.Sml => build_sml_like node ".uo"
         | HolbuildSourceIndex.Sig => build_sml_like node ".ui";
       write_metadata project input_key toolchain_key node)
  end

fun build_serial tc project plan keys toolchain_key =
  List.app (build_node tc project plan keys toolchain_key) plan

fun node_done done node = List.exists (fn k => k = HolbuildBuildPlan.key node) done

fun deps_done plan done node =
  List.all (node_done done) (HolbuildBuildPlan.direct_project_deps plan node)

fun find_ready plan done pending =
  let
    fun loop prefix rest =
      case rest of
          [] => NONE
        | node :: suffix =>
            if deps_done plan done node then SOME (node, rev prefix @ suffix)
            else loop (node :: prefix) suffix
  in
    loop [] pending
  end

fun build_error_message e =
  case e of
      Error msg => msg
    | _ => General.exnMessage e

fun build_parallel tc project plan keys toolchain_key jobs =
  let
    val mutex = Thread.Mutex.mutex ()
    val cv = Thread.ConditionVar.conditionVar ()
    val pending = ref plan
    val running = ref 0
    val active = ref jobs
    val done = ref ([] : string list)
    val failure = ref (NONE : string option)

    fun signal () = Thread.ConditionVar.broadcast cv
    fun lock () = Thread.Mutex.lock mutex
    fun unlock () = Thread.Mutex.unlock mutex

    fun next_work_locked () =
      case !failure of
          SOME _ => NONE
        | NONE =>
            case find_ready plan (!done) (!pending) of
                SOME (node, rest) =>
                  (pending := rest; running := !running + 1; SOME node)
              | NONE =>
                  if null (!pending) andalso !running = 0 then NONE
                  else (Thread.ConditionVar.wait (cv, mutex); next_work_locked ())

    fun with_lock f =
      (lock (); f () before unlock ())
      handle e => (unlock (); raise e)

    fun next_work () = with_lock next_work_locked

    fun finish_success node =
      with_lock
        (fn () =>
            (running := !running - 1;
             done := HolbuildBuildPlan.key node :: !done;
             signal ()))

    fun finish_failure msg =
      with_lock
        (fn () =>
            (running := !running - 1;
             case !failure of
                 SOME _ => ()
               | NONE => failure := SOME msg;
             signal ()))

    fun worker_exit () =
      with_lock (fn () => (active := !active - 1; signal ()))

    fun worker () =
      let
        fun loop () =
          case next_work () of
              NONE => worker_exit ()
            | SOME node =>
                ((build_node tc project plan keys toolchain_key node;
                  finish_success node;
                  loop ())
                 handle e => (finish_failure (build_error_message e); worker_exit ()))
      in
        loop ()
      end

    fun wait_workers_locked () =
      if !active = 0 then ()
      else (Thread.ConditionVar.wait (cv, mutex); wait_workers_locked ())

    fun wait_workers () =
      let
        val result =
          (lock (); wait_workers_locked (); !failure before unlock ())
          handle e => (unlock (); raise e)
      in
        case result of
            NONE => ()
          | SOME msg => raise Error msg
      end
  in
    List.app (fn _ => ignore (Thread.Thread.fork (worker, [])))
             (List.tabulate (jobs, fn i => i));
    wait_workers ()
  end

fun build tc project plan toolchain_key jobs =
  let val keys = HolbuildBuildPlan.input_keys toolchain_key plan
  in
    if jobs <= 1 then build_serial tc project plan keys toolchain_key
    else build_parallel tc project plan keys toolchain_key jobs
  end

fun add_unique_string (value, values) =
  if List.exists (fn existing => existing = value) values then values else value :: values

fun unique_strings values = rev (List.foldl add_unique_string [] values)

fun heap_external_theories plan =
  unique_strings (List.concat (map (HolbuildBuildPlan.closure_external_theories plan) plan))

fun heap_theory_load_lines node =
  case #kind (HolbuildBuildPlan.source_of node) of
      HolbuildSourceIndex.TheoryScript => use_generated_lines node
    | _ =>
      raise Error ("heap objects currently must be theory targets: " ^
                   HolbuildBuildPlan.logical_name node)

fun write_heap_loader plan output path =
  let
    val lines =
      map load_theory_line (heap_external_theories plan) @
      List.concat (map heap_theory_load_lines plan) @
      [save_heap_line output]
  in
    write_text path (String.concatWith "\n" lines ^ "\n")
  end

fun export_heap tc (project : HolbuildProject.t) plan output =
  let
    val stage = Path.concat(Path.concat(#root project, ".hol/stage"), "heap")
    val loader = Path.concat(stage, "holbuild-save-heap.sml")
  in
    ensure_dir stage;
    ensure_parent output;
    write_heap_loader plan output loader;
    run_hol_files tc stage (HolbuildToolchain.base_state tc) [loader]
      ("hol run failed while exporting heap: " ^ output);
    remove_tree stage
  end

end
