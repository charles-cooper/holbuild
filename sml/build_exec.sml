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

fun hfs_remapped_path path = Path.concat(Path.concat(Path.dir path, ".hol/objs"), Path.file path)

fun write_object_manifest path lines =
  (write_manifest path lines;
   write_manifest (hfs_remapped_path path) lines)

fun dependency_sml dep = one_with_suffix ".sml" (#generated (source_artifacts dep))
fun dependency_sig dep = one_with_suffix ".sig" (#generated (source_artifacts dep))

fun load_theory_line name = "load " ^ HolbuildToolchain.sml_string name ^ ";"

fun use_generated_lines dep =
  ["use " ^ HolbuildToolchain.sml_string (dependency_sig dep) ^ ";",
   "use " ^ HolbuildToolchain.sml_string (dependency_sml dep) ^ ";"]

fun drop_suffix suffix path =
  if has_suffix suffix path then String.substring(path, 0, size path - size suffix)
  else raise Error ("expected suffix " ^ suffix ^ " in " ^ path)

fun object_stem_with_suffix suffix dep =
  drop_suffix suffix (one_with_suffix suffix (#objects (source_artifacts dep)))

fun loadable_project_dep dep =
  case #kind (HolbuildBuildPlan.source_of dep) of
      HolbuildSourceIndex.Sig => false
    | _ => true

fun load_stem dep =
  case #kind (HolbuildBuildPlan.source_of dep) of
      HolbuildSourceIndex.TheoryScript =>
        drop_suffix ".uo" (one_with_suffix (HolbuildBuildPlan.logical_name dep ^ ".uo")
                                          (#objects (source_artifacts dep)))
    | HolbuildSourceIndex.Sml => object_stem_with_suffix ".uo" dep
    | HolbuildSourceIndex.Sig => object_stem_with_suffix ".ui" dep

fun add_unique_string (value, values) =
  if List.exists (fn existing => existing = value) values then values else value :: values

fun unique_strings values = rev (List.foldl add_unique_string [] values)

fun project_load_stems deps =
  unique_strings (map load_stem (List.filter loadable_project_dep deps))

fun fakeload_line name = "Meta.fakeload " ^ HolbuildToolchain.sml_string name ^ ";"

fun load_project_line dep = "load " ^ HolbuildToolchain.sml_string dep ^ ";"

fun project_preload_lines dep =
  case #kind (HolbuildBuildPlan.source_of dep) of
      HolbuildSourceIndex.TheoryScript => use_generated_lines dep @ [fakeload_line (logical_name dep)]
    | HolbuildSourceIndex.Sml => [load_project_line (load_stem dep)]
    | HolbuildSourceIndex.Sig => []

fun save_heap_line output =
  "val _ = PolyML.SaveState.saveChild(" ^
  HolbuildToolchain.sml_string output ^
  ", length (PolyML.SaveState.showHierarchy()));"

fun write_preload plan node deps_loaded path =
  let
    val external_deps = HolbuildBuildPlan.closure_external_theories plan node
    val project_deps = HolbuildBuildPlan.transitive_project_deps plan node
    val lines = map load_theory_line external_deps @
                List.concat (map project_preload_lines project_deps) @
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
  Path.concat(Path.concat(#root project, ".holbuild/stage"), input_key)

fun staged_theory_file stage node ext = Path.concat(Path.concat(stage, ".hol/objs"), logical_name node ^ ext)
fun staged_dat_reference stage node = Path.concat(stage, logical_name node ^ ".dat")

fun checkpoint_base (project : HolbuildProject.t) node =
  Path.concat(Path.concat(Path.concat(#root project, ".holbuild/checkpoints"),
                          HolbuildBuildPlan.package node),
              HolbuildBuildPlan.relative_path node)

fun deps_loaded_path project node = checkpoint_base project node ^ ".deps_loaded.save"
fun final_context_path project node = checkpoint_base project node ^ ".final_context.save"

fun remove_tree path =
  ignore (OS.Process.system ("rm -rf " ^ HolbuildToolchain.quote path))

fun project_lock_path (project : HolbuildProject.t) =
  Path.concat(Path.concat(#root project, ".holbuild/locks"), "project.lock")

fun project_lock_owner_path lock = Path.concat(lock, "owner")

fun env_default name default = Option.getOpt(OS.Process.getEnv name, default)

fun current_pid_text () =
  LargeInt.toString (SysWord.toLargeInt (Posix.Process.pidToWord (Posix.ProcEnv.getpid ())))

fun trim_trailing_newline text =
  if size text > 0 andalso String.sub(text, size text - 1) = #"\n" then
    String.substring(text, 0, size text - 1)
  else text

fun current_host () =
  trim_trailing_newline (read_text "/proc/sys/kernel/hostname")
  handle _ => env_default "HOSTNAME" "unknown"

fun project_lock_owner command =
  String.concatWith "\n"
    ["holbuild-project-lock-v1",
     "command=" ^ command,
     "pid=" ^ current_pid_text (),
     "cwd=" ^ FS.getDir (),
     "host=" ^ current_host (),
     "started=" ^ Time.toString (Time.now ())] ^ "\n"

fun current_lock_owner lock =
  SOME (read_text (project_lock_owner_path lock)) handle _ => NONE

fun owner_lines owner = String.tokens (fn c => c = #"\n") owner

fun owner_value key owner =
  let
    val prefix = key ^ "="
    fun value line =
      if String.isPrefix prefix line then SOME (String.extract(line, size prefix, NONE))
      else NONE
    fun first lines =
      case lines of
          [] => NONE
        | line :: rest =>
            case value line of
                SOME v => SOME v
              | NONE => first rest
  in
    first (owner_lines owner)
  end

fun local_pid_alive pid = FS.access(Path.concat("/proc", pid), []) handle OS.SysErr _ => false

fun stale_project_lock owner =
  case (owner_value "host" owner, owner_value "pid" owner) of
      (SOME host, SOME pid) => host = current_host () andalso not (local_pid_alive pid)
    | _ => false

fun remove_stale_project_lock lock owner =
  (TextIO.output(TextIO.stdErr,
                 "holbuild: warning: removing stale project lock: " ^ lock ^ "\n" ^ owner);
   remove_file (project_lock_owner_path lock);
   FS.rmDir lock handle OS.SysErr _ => ())

fun project_lock_error lock owner =
  Error ("project is already being modified by another holbuild process\n" ^
         "lock: " ^ lock ^ "\n" ^ owner)

fun acquire_fresh_project_lock lock command =
  (FS.mkDir lock;
   write_text (project_lock_owner_path lock) (project_lock_owner command);
   lock)

fun acquire_project_lock project command =
  let
    val lock = project_lock_path project
    fun retry_after_existing () =
      case current_lock_owner lock of
          SOME owner =>
            if stale_project_lock owner then
              (remove_stale_project_lock lock owner;
               acquire_fresh_project_lock lock command)
            else raise project_lock_error lock owner
        | NONE => raise project_lock_error lock "owner unavailable\n"
  in
    ensure_parent lock;
    acquire_fresh_project_lock lock command
    handle OS.SysErr _ => retry_after_existing ()
  end

fun release_project_lock lock =
  (remove_file (project_lock_owner_path lock); FS.rmDir lock handle OS.SysErr _ => ())

fun with_project_lock project command f =
  let val lock = acquire_project_lock project command
  in
    (f () before release_project_lock lock)
    handle e => (release_project_lock lock; raise e)
  end

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

fun cache_manifest_lines text = String.tokens (fn c => c = #"\n") text

fun first_some f values =
  case values of
      [] => NONE
    | x :: xs =>
        case f x of
            SOME y => SOME y
          | NONE => first_some f xs

fun is_hex_digit c =
  (#"0" <= c andalso c <= #"9") orelse
  (#"a" <= c andalso c <= #"f") orelse
  (#"A" <= c andalso c <= #"F")

fun all_chars pred text =
  let
    fun loop i = i >= size text orelse (pred (String.sub(text, i)) andalso loop (i + 1))
  in
    loop 0
  end

fun valid_sha1_text text = size text = 40 andalso all_chars is_hex_digit text

fun require_sha1 role hash =
  if valid_sha1_text hash then hash
  else raise Error ("cache manifest invalid " ^ role ^ " blob hash: " ^ hash)

fun known_blob_role role = role = "sig" orelse role = "sml-template" orelse role = "dat"

fun add_manifest_blob role hash blobs =
  if not (known_blob_role role) then
    raise Error ("cache manifest unknown blob role: " ^ role)
  else if List.exists (fn (role', _) => role' = role) blobs then
    raise Error ("cache manifest duplicate blob role: " ^ role)
  else
    (role, require_sha1 role hash) :: blobs

fun blob_from_manifest role blobs =
  case List.find (fn (role', _) => role' = role) blobs of
      SOME (_, hash) => hash
    | NONE => raise Error ("cache manifest missing blob role: " ^ role)

fun parse_cache_manifest_line input_key line (saw_header, saw_input, saw_kind, blobs) =
  if line = "holbuild-cache-action-v1" then
    if saw_header then raise Error "cache manifest duplicate header"
    else (true, saw_input, saw_kind, blobs)
  else if line = "input_key=" ^ input_key then
    if saw_input then raise Error "cache manifest duplicate input key"
    else (saw_header, true, saw_kind, blobs)
  else if String.isPrefix "input_key=" line then
    raise Error "cache manifest input key mismatch"
  else if line = "kind=theory" then
    if saw_kind then raise Error "cache manifest duplicate kind"
    else (saw_header, saw_input, true, blobs)
  else if String.isPrefix "kind=" line then
    raise Error "cache manifest unsupported kind"
  else
    case String.tokens Char.isSpace line of
        ["blob", role, hash] => (saw_header, saw_input, saw_kind, add_manifest_blob role hash blobs)
      | _ => raise Error ("cache manifest unknown line: " ^ line)

fun cache_manifest_blobs_from_lines input_key lines =
  let
    val (saw_header, saw_input, saw_kind, blobs) =
      List.foldl (fn (line, state) => parse_cache_manifest_line input_key line state)
                 (false, false, false, []) lines
    val _ = if saw_header then () else raise Error "cache manifest missing header"
    val _ = if saw_input then () else raise Error "cache manifest missing input key"
    val _ = if saw_kind then () else raise Error "cache manifest missing kind"
  in
    {sig_hash = blob_from_manifest "sig" blobs,
     sml_hash = blob_from_manifest "sml-template" blobs,
     dat_hash = blob_from_manifest "dat" blobs}
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
    fun skip_locked_publish () = ()
  in
    (HolbuildCache.with_action_publish_lock root input_key publish skip_locked_publish;
     cleanup ())
    handle e => (cleanup (); warn ("could not publish cache entry: " ^ General.exnMessage e))
  end

fun write_local_theory_manifests plan node =
  let
    val {sig_path, sml_path, script_uo, theory_ui, theory_uo, ...} = theory_outputs node
    val deps = HolbuildBuildPlan.direct_project_deps plan node
  in
    write_object_manifest theory_ui [sig_path];
    write_object_manifest theory_uo (project_load_stems deps @ [sml_path]);
    write_object_manifest script_uo [source_file node]
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

fun remove_failed_cache_outputs project node =
  let
    val {sig_path, sml_path, data_path, script_uo, theory_ui, theory_uo} = theory_outputs node
    val paths =
      [data_path, hfs_remapped_path data_path,
       sig_path, hfs_remapped_path sig_path,
       sml_path, hfs_remapped_path sml_path,
       script_uo, hfs_remapped_path script_uo,
       theory_ui, hfs_remapped_path theory_ui,
       theory_uo, hfs_remapped_path theory_uo,
       deps_loaded_path project node,
       final_context_path project node]
  in
    List.app remove_file paths
  end

fun materialize_theory_cache tc project plan input_key node =
  let
    val root = cache_root ()
    val manifest = HolbuildCache.action_manifest root input_key
    val _ = if file_exists manifest then () else raise Error "cache entry not found"
    val _ = FS.setTime (manifest, NONE) handle OS.SysErr _ => ()
    val {sig_hash, sml_hash, dat_hash} = cache_manifest_blobs root input_key
    val {sig_path, sml_path, data_path, ...} = theory_outputs node
    val template = FS.tmpName ()
    fun cleanup () = FS.remove template handle OS.SysErr _ => ()
    fun install () =
      (copy_blob root dat_hash data_path;
       copy_blob root dat_hash (hfs_remapped_path data_path);
       copy_blob root sig_hash sig_path;
       copy_blob root sig_hash (hfs_remapped_path sig_path);
       copy_blob root sml_hash template;
       write_text sml_path (replace_all cache_sml_token data_path (read_text template));
       write_text (hfs_remapped_path sml_path) (read_text sml_path);
       write_local_theory_manifests plan node;
       save_cached_theory_checkpoints tc project plan input_key node;
       print (logical_name node ^ " restored from cache\n");
       true)
  in
    (install () before cleanup ()) handle e => (cleanup (); raise e)
  end
  handle Error "cache entry not found" => false
       | e => (remove_failed_cache_outputs project node;
               warn ("cache entry unusable for " ^ logical_name node ^ ": " ^ General.exnMessage e);
               false)

fun metadata_path (project : HolbuildProject.t) node =
  let
    val source = HolbuildBuildPlan.source_of node
    val base = Path.concat(Path.concat(#root project, ".holbuild/dep"), #package source)
  in
    Path.concat(base, #relative_path source ^ ".key")
  end

fun theorem_context_path project node safe_name =
  checkpoint_base project node ^ "." ^ safe_name ^ "_context.save"

fun theorem_end_of_proof_path project node safe_name =
  checkpoint_base project node ^ "." ^ safe_name ^ "_end_of_proof.save"

fun theorem_discovery_script {source_path, report_path} =
  String.concatWith "\n"
    ["load \"HOLSourceParser\";",
     "fun holbuild_read_all path = let val input = TextIO.openIn path in TextIO.inputAll input before TextIO.closeIn input end;",
     "val holbuild_source_path = " ^ HolbuildToolchain.sml_string source_path ^ ";",
     "val holbuild_report_path = " ^ HolbuildToolchain.sml_string report_path ^ ";",
     "val holbuild_source = holbuild_read_all holbuild_source_path;",
     "val holbuild_out = TextIO.openOut holbuild_report_path;",
     "val holbuild_fed = ref false;",
     "fun holbuild_read _ = if !holbuild_fed then \"\" else (holbuild_fed := true; holbuild_source);",
     "fun holbuild_parse_error _ _ msg = raise Fail (\"HOL source parse error: \" ^ msg);",
     "val holbuild_result = HOLSourceParser.parseSML holbuild_source_path holbuild_read holbuild_parse_error HOLSourceParser.initialScope;",
     "fun holbuild_bool true = \"1\" | holbuild_bool false = \"0\";",
     "fun holbuild_emit_theorem name start stop tac_start tac_end has_attrs = TextIO.output(holbuild_out, String.concatWith \"\\t\" [\"theorem\", name, Int.toString start, Int.toString stop, Int.toString tac_start, Int.toString tac_end, holbuild_bool has_attrs] ^ \"\\n\");",
     "fun holbuild_loop () =",
     "  case #parseDec holbuild_result () of",
     "      NONE => ()",
     "    | SOME (HOLSourceAST.HOLTheoremDecl {theorem_, id = (_, name), proof_, tac, stop, ...}) =>",
     "        let val (tac_start, tac_end) = HOLSourceAST.expSpan tac in holbuild_emit_theorem name theorem_ stop tac_start tac_end (Option.isSome proof_); holbuild_loop () end",
     "    | SOME _ => holbuild_loop ();",
     "val _ = (holbuild_loop (); TextIO.closeOut holbuild_out);",
     ""]

fun discover_theorem_boundaries tc stage source_path source_text =
  let
    val script = Path.concat(stage, "holbuild-discover-theorems.sml")
    val report_path = Path.concat(stage, "holbuild-theorems.tsv")
    val _ = write_text script (theorem_discovery_script {source_path = source_path, report_path = report_path})
    val _ = run_hol_files tc stage (HolbuildToolchain.base_state tc) [script]
              "hol run failed while discovering theorem AST boundaries"
    val report = read_text report_path handle IO.Io _ => ""
  in
    HolbuildTheoryCheckpoints.discover_from_report {source = source_text, report = report}
  end

fun theorem_checkpoint_specs project node boundaries =
  map (fn {name, safe_name, theorem_start, theorem_stop, boundary, tactic_start,
           tactic_end, tactic_text, has_proof_attrs, prefix_hash} =>
          {name = name, safe_name = safe_name, theorem_start = theorem_start,
           theorem_stop = theorem_stop, boundary = boundary,
           tactic_start = tactic_start, tactic_end = tactic_end,
           tactic_text = tactic_text, has_proof_attrs = has_proof_attrs,
           prefix_hash = prefix_hash,
           context_path = theorem_context_path project node safe_name,
           end_of_proof_path = theorem_end_of_proof_path project node safe_name})
      boundaries

fun dependency_context_key toolchain_key plan keys node =
  let
    val project_deps = HolbuildBuildPlan.transitive_project_deps plan node
    val external_deps = HolbuildBuildPlan.closure_external_theories plan node
    val project_lines = map (fn dep => "project " ^ HolbuildBuildPlan.key dep ^ " " ^
                                       HolbuildBuildPlan.input_key_for keys dep)
                            project_deps
    val external_lines = map (fn dep => "external " ^ dep) external_deps
  in
    HolbuildToolchain.hash_text
      (String.concatWith "\n"
         (["holbuild-dependency-context-v1",
           "toolchain_key=" ^ toolchain_key] @ project_lines @ external_lines) ^ "\n")
  end

fun metadata_lines text = String.tokens (fn c => c = #"\n") text

fun metadata_value key lines =
  let val prefix = key ^ "="
  in
    first_some (fn line =>
                  if String.isPrefix prefix line then
                    SOME (String.extract(line, size prefix, NONE))
                  else NONE)
               lines
  end

fun old_theorem_boundary line =
  case String.tokens Char.isSpace line of
      ["theorem_boundary", safe_name, prefix_hash, path] =>
        SOME {safe_name = safe_name, prefix_hash = prefix_hash,
              context_path = path, end_of_proof_path = ""}
    | ["theorem_boundary", safe_name, prefix_hash, context_path, end_of_proof_path] =>
        SOME {safe_name = safe_name, prefix_hash = prefix_hash,
              context_path = context_path, end_of_proof_path = end_of_proof_path}
    | _ => NONE

fun same_boundary old {safe_name, prefix_hash, ...} =
  #safe_name old = safe_name andalso #prefix_hash old = prefix_hash

fun replay_candidates old_boundaries checkpoints =
  List.mapPartial
    (fn checkpoint =>
        case List.find (fn old => same_boundary old checkpoint) old_boundaries of
            SOME old =>
              if file_exists (#context_path old) then
                SOME {boundary = #boundary checkpoint, path = #context_path old,
                      safe_name = #safe_name checkpoint}
              else NONE
          | NONE => NONE)
    checkpoints

fun later_candidate (a, b) = if #boundary a >= #boundary b then a else b

fun best_replay_candidate project plan keys toolchain_key node checkpoints =
  case current_metadata (metadata_path project node) of
      NONE => NONE
    | SOME text =>
        let
          val lines = metadata_lines text
          val current_context = dependency_context_key toolchain_key plan keys node
          val old_context = metadata_value "dependency_context_key" lines
          val old_boundaries = List.mapPartial old_theorem_boundary lines
          val candidates = replay_candidates old_boundaries checkpoints
        in
          if old_context <> SOME current_context orelse null candidates then NONE
          else SOME (List.foldl later_candidate (hd candidates) (tl candidates))
        end

fun instrumented_source source_text start_offset checkpoints =
  HolbuildTheoryCheckpoints.instrument
    {source = source_text, start_offset = start_offset, checkpoints = checkpoints}

fun write_theory_script tc project plan keys toolchain_key node source_text checkpoints staged_script preload =
  case best_replay_candidate project plan keys toolchain_key node checkpoints of
      SOME {boundary, path, safe_name} =>
        let
          val _ = write_text staged_script (instrumented_source source_text boundary checkpoints)
          val _ = print (logical_name node ^ " replaying from checkpoint " ^ safe_name ^ "\n")
        in
          {holstate = path, files = [staged_script]}
        end
    | NONE =>
        (write_preload plan node (deps_loaded_path project node) preload;
         write_text staged_script (instrumented_source source_text 0 checkpoints);
         {holstate = HolbuildToolchain.base_state tc, files = [preload, staged_script]})

fun build_theory tc project plan keys toolchain_key node source_text theorem_checkpoints =
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
    val _ = ensure_parent deps_loaded
    val _ = ensure_parent final_context
    val _ = List.app (fn {context_path, end_of_proof_path, ...} =>
                         (ensure_parent context_path; ensure_parent end_of_proof_path))
                     theorem_checkpoints
    val _ = write_final_context_loader
              {sig_path = staged_sig, sml_path = staged_sml,
               output = final_context, path = final_loader}
    val run_spec = write_theory_script tc project plan keys toolchain_key node
                                    source_text theorem_checkpoints staged_script preload
    val _ = run_hol_files tc stage (#holstate run_spec)
              (#files run_spec @ [final_loader])
              "hol run failed while building theory script"
    val _ = copy_binary staged_dat data_path
    val _ = copy_binary staged_dat (hfs_remapped_path data_path)
    val _ = copy_binary staged_sig sig_path
    val _ = copy_binary staged_sig (hfs_remapped_path sig_path)
    val _ = copy_rewriting_path {src = staged_sml, dst = sml_path,
                                 old_path = staged_dat_reference stage node,
                                 new_path = data_path}
    val _ = copy_binary sml_path (hfs_remapped_path sml_path)
    val _ = publish_theory_cache input_key (staged_dat_reference stage node) staged_sig staged_sml staged_dat
  in
    write_local_theory_manifests plan node;
    remove_tree stage
  end

fun same_package_logical a b =
  HolbuildBuildPlan.package a = HolbuildBuildPlan.package b andalso
  HolbuildBuildPlan.logical_name a = HolbuildBuildPlan.logical_name b

fun has_signature_companion plan node =
  List.exists
    (fn candidate => same_package_logical candidate node andalso
                     #kind (HolbuildBuildPlan.source_of candidate) = HolbuildSourceIndex.Sig)
    plan

fun write_empty_ui_if_needed plan node =
  if has_signature_companion plan node then ()
  else write_object_manifest (one_with_suffix ".ui" (#objects (source_artifacts node))) []

fun build_sml_like plan node output_suffix =
  let
    val output = one_with_suffix output_suffix (#objects (source_artifacts node))
    val deps = HolbuildBuildPlan.direct_project_deps plan node
  in
    write_object_manifest output (project_load_stems deps @ [source_file node]);
    if output_suffix = ".uo" then write_empty_ui_if_needed plan node else ()
  end

fun output_paths project node =
  let val artifacts = source_artifacts node
      val generated_paths = #generated artifacts
      val object_paths = #objects artifacts
      val data_paths = #theory_data artifacts
      val base = generated_paths @ map hfs_remapped_path generated_paths @
                 object_paths @ map hfs_remapped_path object_paths @
                 data_paths @ map hfs_remapped_path data_paths
  in
    case #kind (HolbuildBuildPlan.source_of node) of
        HolbuildSourceIndex.TheoryScript =>
          deps_loaded_path project node :: final_context_path project node :: base
      | _ => base
  end

fun output_hash_line path = "output-sha1=" ^ path ^ " " ^ file_hash path

fun checkpoint_lines project node =
  case #kind (HolbuildBuildPlan.source_of node) of
      HolbuildSourceIndex.TheoryScript =>
        ["deps_loaded=" ^ deps_loaded_path project node,
         "final_context=" ^ final_context_path project node]
    | _ => []

fun dependency_context_lines plan keys toolchain_key node =
  case #kind (HolbuildBuildPlan.source_of node) of
      HolbuildSourceIndex.TheoryScript =>
        ["dependency_context_key=" ^ dependency_context_key toolchain_key plan keys node]
    | _ => []

fun theorem_boundary_line {safe_name, prefix_hash, context_path, end_of_proof_path, ...} =
  "theorem_boundary " ^ safe_name ^ " " ^ prefix_hash ^ " " ^
  context_path ^ " " ^ end_of_proof_path

fun theorem_boundary_lines theorem_checkpoints =
  map theorem_boundary_line theorem_checkpoints

fun metadata_text project plan keys input_key toolchain_key node theorem_checkpoints =
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
      dependency_context_lines plan keys toolchain_key node @
      checkpoint_lines project node @
      theorem_boundary_lines theorem_checkpoints @
      map output_hash_line (output_paths project node)
  in
    String.concatWith "\n" lines ^ "\n"
  end

fun up_to_date project plan keys input_key toolchain_key node theorem_checkpoints =
  List.all file_exists (output_paths project node) andalso
  current_metadata (metadata_path project node) =
    SOME (metadata_text project plan keys input_key toolchain_key node theorem_checkpoints)

fun write_metadata project plan keys input_key toolchain_key node theorem_checkpoints =
  write_text (metadata_path project node)
             (metadata_text project plan keys input_key toolchain_key node theorem_checkpoints)

fun theory_checkpoints_for_node tc project node input_key source_text =
  let
    val stage = stage_dir project input_key
    val _ = ensure_dir stage
    val boundaries = discover_theorem_boundaries tc stage (source_file node) source_text
  in
    theorem_checkpoint_specs project node boundaries
  end

fun build_theory_node tc project plan keys toolchain_key node input_key =
  let
    val source_text = read_text (source_file node)
    val theorem_checkpoints = theory_checkpoints_for_node tc project node input_key source_text
    val stage = stage_dir project input_key
  in
    if up_to_date project plan keys input_key toolchain_key node theorem_checkpoints then
      (remove_tree stage;
       print (HolbuildBuildPlan.logical_name node ^ " is up to date\n"))
    else if materialize_theory_cache tc project plan input_key node then
      (remove_tree stage;
       write_metadata project plan keys input_key toolchain_key node theorem_checkpoints)
    else
      (build_theory tc project plan keys toolchain_key node source_text theorem_checkpoints;
       write_metadata project plan keys input_key toolchain_key node theorem_checkpoints)
  end

fun build_node tc project plan keys toolchain_key node =
  let val input_key = HolbuildBuildPlan.input_key_for keys node
  in
    case #kind (HolbuildBuildPlan.source_of node) of
        HolbuildSourceIndex.TheoryScript =>
          build_theory_node tc project plan keys toolchain_key node input_key
      | HolbuildSourceIndex.Sml =>
          if up_to_date project plan keys input_key toolchain_key node [] then
            print (HolbuildBuildPlan.logical_name node ^ " is up to date\n")
          else (build_sml_like plan node ".uo";
                write_metadata project plan keys input_key toolchain_key node [])
      | HolbuildSourceIndex.Sig =>
          if up_to_date project plan keys input_key toolchain_key node [] then
            print (HolbuildBuildPlan.logical_name node ^ " is up to date\n")
          else (build_sml_like plan node ".ui";
                write_metadata project plan keys input_key toolchain_key node [])
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
    val stage = Path.concat(Path.concat(#root project, ".holbuild/stage"), "heap")
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
