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

fun rewrite_all replacements text =
  List.foldl (fn ((old_text, new_text), current) => replace_all old_text new_text current)
             text replacements

fun copy_rewriting_path {src, dst, replacements} =
  write_text dst (rewrite_all replacements (read_text src))

fun source_file node = #source_path (HolbuildBuildPlan.source_of node)
fun source_artifacts node = #artifacts (HolbuildBuildPlan.source_of node)
fun source_policy node = #policy (HolbuildBuildPlan.source_of node)
fun logical_name node = HolbuildBuildPlan.logical_name node
fun cache_enabled node = HolbuildProject.action_cache_enabled (source_policy node)
fun always_reexecute node = HolbuildProject.action_always_reexecute (source_policy node)

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

fun theory_project_dep dep =
  #kind (HolbuildBuildPlan.source_of dep) = HolbuildSourceIndex.TheoryScript

fun project_theory_load_stems deps =
  unique_strings (map load_stem (List.filter theory_project_dep deps))

fun fakeload_line name = "Meta.fakeload " ^ HolbuildToolchain.sml_string name ^ ";"

fun load_project_line dep = "load " ^ HolbuildToolchain.sml_string dep ^ ";"

fun project_preload_lines dep =
  case #kind (HolbuildBuildPlan.source_of dep) of
      HolbuildSourceIndex.TheoryScript => [load_project_line (load_stem dep)]
    | HolbuildSourceIndex.Sml => [load_project_line (load_stem dep)]
    | HolbuildSourceIndex.Sig => []

fun checkpoint_ok_path path = path ^ ".ok"

fun remove_checkpoint path =
  (remove_file (checkpoint_ok_path path); remove_file path)

fun checkpoint_ok_v1 () = "holbuild-checkpoint-ok-v1\n"

fun checkpoint_ok_text kind fields =
  String.concatWith "\n"
    ("holbuild-checkpoint-ok-v2" :: ("kind=" ^ kind) ::
     map (fn (key, value) => key ^ "=" ^ value) fields) ^ "\n"

fun save_heap_line {label, share_common_data, output, ok_text} =
  let val default_share = if share_common_data then "true" else "false"
  in
    String.concatWith "\n"
      ["val _ = let",
       "  val holbuild_checkpoint_path = " ^ HolbuildToolchain.sml_string output,
       "  val holbuild_checkpoint_label = " ^ HolbuildToolchain.sml_string label,
       "  val holbuild_checkpoint_default_share = " ^ default_share,
       "  val holbuild_checkpoint_ok_text = " ^ HolbuildToolchain.sml_string ok_text,
       "  fun holbuild_checkpoint_bool name = case OS.Process.getEnv name of SOME \"1\" => SOME true | SOME \"true\" => SOME true | SOME \"yes\" => SOME true | SOME \"0\" => SOME false | SOME \"false\" => SOME false | SOME \"no\" => SOME false | _ => NONE",
       "  fun holbuild_checkpoint_remove path = OS.FileSys.remove path handle _ => ()",
       "  fun holbuild_checkpoint_write_ok path = let val out = TextIO.openOut path in TextIO.output(out, holbuild_checkpoint_ok_text); TextIO.closeOut out end",
       "  fun holbuild_checkpoint_seconds (a, b) = Time.toReal (Time.-(b, a))",
       "  fun holbuild_checkpoint_fmt t = Real.fmt (StringCvt.FIX (SOME 3)) t",
       "  fun holbuild_checkpoint_bool_text true = \"true\" | holbuild_checkpoint_bool_text false = \"false\"",
       "  val holbuild_checkpoint_share = Option.getOpt(holbuild_checkpoint_bool \"HOLBUILD_SHARE_COMMON_DATA\", holbuild_checkpoint_default_share)",
       "  val holbuild_checkpoint_timing = Option.getOpt(holbuild_checkpoint_bool \"HOLBUILD_CHECKPOINT_TIMING\", false)",
       "  val holbuild_checkpoint_ok = holbuild_checkpoint_path ^ \".ok\"",
       "  val holbuild_checkpoint_depth = length (PolyML.SaveState.showHierarchy())",
       "  val holbuild_checkpoint_t0 = Time.now()",
       "  val _ = holbuild_checkpoint_remove holbuild_checkpoint_ok",
       "  val _ = holbuild_checkpoint_remove holbuild_checkpoint_path",
       "  val _ = if holbuild_checkpoint_share then PolyML.shareCommonData PolyML.rootFunction else ()",
       "  val holbuild_checkpoint_t1 = Time.now()",
       "  val _ = PolyML.SaveState.saveChild(holbuild_checkpoint_path, holbuild_checkpoint_depth)",
       "  val holbuild_checkpoint_t2 = Time.now()",
       "  val _ = holbuild_checkpoint_write_ok holbuild_checkpoint_ok",
       "  val _ = if holbuild_checkpoint_timing then TextIO.output(TextIO.stdErr, String.concat [\"holbuild checkpoint kind=\", holbuild_checkpoint_label, \" share=\", holbuild_checkpoint_bool_text holbuild_checkpoint_share, \" depth=\", Int.toString holbuild_checkpoint_depth, \" share_s=\", holbuild_checkpoint_fmt (holbuild_checkpoint_seconds (holbuild_checkpoint_t0, holbuild_checkpoint_t1)), \" save_s=\", holbuild_checkpoint_fmt (holbuild_checkpoint_seconds (holbuild_checkpoint_t1, holbuild_checkpoint_t2)), \" size=\", Position.toString (OS.FileSys.fileSize holbuild_checkpoint_path), \" path=\", holbuild_checkpoint_path, \"\\n\"]) else ()",
       "in () end;"]
  end

fun direct_external_loads plan node =
  unique_strings
    (HolbuildBuildPlan.direct_external_theories plan node @
     HolbuildBuildPlan.direct_external_libs plan node)

fun preload_lines plan node =
  let
    val external_deps = HolbuildBuildPlan.direct_external_theories plan node
    val external_libs = HolbuildBuildPlan.direct_external_libs plan node
    val project_deps = HolbuildBuildPlan.direct_project_deps plan node
  in
    map load_theory_line external_deps @
    map load_project_line external_libs @
    List.concat (map project_preload_lines project_deps)
  end

fun write_preload plan node deps_loaded deps_ok path =
  let
    val lines = preload_lines plan node @
                [save_heap_line {label = "deps_loaded", share_common_data = true,
                                 output = deps_loaded, ok_text = deps_ok}]
  in
    write_text path (String.concatWith "\n" lines ^ "\n")
  end

fun write_plain_preload plan node path =
  write_text path (String.concatWith "\n" (preload_lines plan node) ^ "\n")

fun mldep_report_lines NONE = []
  | mldep_report_lines (SOME report_path) =
      ["val holbuild_mldeps_out = TextIO.openOut " ^ HolbuildToolchain.sml_string report_path ^ ";",
       "val _ = (List.app (fn s => TextIO.output(holbuild_mldeps_out, s ^ \"\\n\")) (Theory.current_ML_deps()); TextIO.closeOut holbuild_mldeps_out);"]

fun export_theory_if_needed_line sig_path =
  "val _ = if OS.FileSys.access(" ^ HolbuildToolchain.sml_string sig_path ^
  ", [OS.FileSys.A_READ]) then () else export_theory();"

fun final_context_loader_lines {sig_path, sml_path, mldeps_report} =
  export_theory_if_needed_line sig_path ::
  mldep_report_lines mldeps_report @
  ["use " ^ HolbuildToolchain.sml_string sig_path ^ ";",
   "use " ^ HolbuildToolchain.sml_string sml_path ^ ";"]

fun write_final_context_loader {sig_path, sml_path, output, path, mldeps_report} =
  let
    val lines = final_context_loader_lines {sig_path = sig_path, sml_path = sml_path,
                                            mldeps_report = mldeps_report} @
                [save_heap_line {label = "final_context", share_common_data = true,
                                 output = output, ok_text = checkpoint_ok_v1 ()}]
  in
    write_text path (String.concatWith "\n" lines ^ "\n")
  end

fun write_plain_final_context_loader {sig_path, sml_path, path, mldeps_report} =
  write_text path (String.concatWith "\n"
                     (final_context_loader_lines {sig_path = sig_path, sml_path = sml_path,
                                                  mldeps_report = mldeps_report}) ^ "\n")

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

fun log_dir (project : HolbuildProject.t) = Path.concat(#root project, ".holbuild/logs")

fun retained_checkpoint_failure_log project node input_key =
  Path.concat(log_dir project, input_key ^ "-" ^ logical_name node ^ "-instrumented-failure.log")

fun staged_theory_file stage node ext = Path.concat(Path.concat(stage, ".hol/objs"), logical_name node ^ ext)
fun staged_dat_reference stage node = Path.concat(stage, logical_name node ^ ".dat")

fun canonical_path path = Path.mkCanonical path handle Path.InvalidArc => path

fun drop_trailing_newline text =
  if size text > 0 andalso String.sub(text, size text - 1) = #"\n" then
    String.substring(text, 0, size text - 1)
  else text

fun has_space text =
  let
    fun loop i = i < size text andalso (Char.isSpace (String.sub(text, i)) orelse loop (i + 1))
  in
    loop 0
  end

fun read_holpath_name dir =
  let
    val path = Path.concat(dir, ".holpath")
    val text = read_text path
    val trimmed = drop_trailing_newline text
  in
    if trimmed = "" orelse has_space trimmed then NONE else SOME trimmed
  end
  handle _ => NONE

fun path_under_dir path dir =
  path <> dir andalso String.isPrefix (dir ^ "/") path

fun holpath_reference path dir name =
  if path_under_dir path dir then
    SOME ("$(" ^ name ^ ")/" ^ String.extract(path, size dir + 1, NONE))
  else NONE

fun holpath_stage_references path =
  let
    val canonical = canonical_path path
    fun loop dir refs =
      let
        val dir' = canonical_path dir
        val refs' =
          case read_holpath_name dir' of
              SOME name =>
                (case holpath_reference canonical dir' name of
                     SOME path_ref => path_ref :: refs
                   | NONE => refs)
            | NONE => refs
        val parent = Path.dir dir'
      in
        if parent = dir' then refs' else loop parent refs'
      end
  in
    loop (Path.dir canonical) []
  end

fun stage_dat_references stage node =
  let val path = staged_dat_reference stage node
  in unique_strings (path :: holpath_stage_references path) end

fun stage_dat_replacements stage node final_dat =
  map (fn path_ref => (path_ref, final_dat)) (stage_dat_references stage node)

fun checkpoint_base (project : HolbuildProject.t) node =
  Path.concat(Path.concat(Path.concat(#root project, ".holbuild/checkpoints"),
                          HolbuildBuildPlan.package node),
              HolbuildBuildPlan.relative_path node)

fun deps_checkpoint_root project node = checkpoint_base project node ^ ".deps"

fun deps_loaded_path project node deps_key =
  Path.concat(Path.concat(deps_checkpoint_root project node, deps_key), "deps_loaded.save")

fun theorem_checkpoint_root project node = checkpoint_base project node ^ ".theorems"

fun theorem_checkpoint_dir project node deps_key prefix_hash =
  Path.concat(Path.concat(theorem_checkpoint_root project node, deps_key), prefix_hash)

fun final_context_path project node = checkpoint_base project node ^ ".final_context.save"

fun remove_legacy_checkpoint_family project node =
  let
    val base = checkpoint_base project node
    val dir = Path.dir base
    val prefix = Path.file base ^ "."
    fun checkpoint_entry name =
      String.isPrefix prefix name andalso
      (has_suffix ".save" name orelse has_suffix ".save.ok" name)
    fun remove_entry name =
      if checkpoint_entry name then remove_file (Path.concat(dir, name)) else ()
    val stream = FS.openDir dir
      handle OS.SysErr _ => raise Fail "holbuild checkpoint directory missing"
    fun close () = FS.closeDir stream handle _ => ()
    fun loop () =
      case FS.readDir stream of
          NONE => ()
        | SOME name => (remove_entry name; loop ())
  in
    (loop (); close ())
    handle e => (close (); raise e)
  end
  handle Fail "holbuild checkpoint directory missing" => ()

fun remove_checkpoint_tree path =
  if FS.access(path, []) handle OS.SysErr _ => false then
    ignore (OS.Process.system ("rm -rf " ^ HolbuildToolchain.quote path))
  else ()

fun remove_checkpoint_family project node =
  (remove_legacy_checkpoint_family project node;
   remove_checkpoint_tree (deps_checkpoint_root project node);
   remove_checkpoint_tree (theorem_checkpoint_root project node))

fun path_exists path = FS.access(path, []) handle OS.SysErr _ => false

fun remove_tree path =
  ignore (OS.Process.system ("rm -rf " ^ HolbuildToolchain.quote path))

fun remove_tree_if_exists path =
  if path_exists path then remove_tree path else ()

fun project_lock_path (project : HolbuildProject.t) =
  Path.concat(Path.concat(#root project, ".holbuild/locks"), "project.lock")

fun project_lock_owner_path lock = Path.concat(lock, "owner")

fun env_default name default = Option.getOpt(OS.Process.getEnv name, default)

fun env_bool name default =
  case OS.Process.getEnv name of
      SOME "1" => true
    | SOME "true" => true
    | SOME "yes" => true
    | SOME "0" => false
    | SOME "false" => false
    | SOME "no" => false
    | _ => default

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

fun owner_summary owner =
  let
    fun field name =
      case owner_value name owner of
          SOME value => name ^ "=" ^ value
        | NONE => name ^ "=unknown"
  in
    String.concatWith " " [field "command", field "pid", field "cwd"]
  end

fun remove_stale_project_lock lock owner =
  (TextIO.output(TextIO.stdErr,
                 "holbuild: warning: removing stale project lock: " ^ lock ^
                 " (" ^ owner_summary owner ^ ")\n");
   remove_file (project_lock_owner_path lock);
   FS.rmDir lock handle OS.SysErr _ => ())

fun project_lock_error lock owner =
  Error ("project is already being modified by another holbuild process\n" ^
         "lock: " ^ lock ^ "\n" ^
         "owner: " ^ owner_summary owner)

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

fun checkpoint_exists path = file_exists path andalso file_exists (checkpoint_ok_path path)

fun file_hash path = HolbuildHash.file_sha1 path

fun current_metadata path = SOME (read_text path) handle IO.Io _ => NONE

datatype hol_context = HolState of string

fun hol_context_args (HolState path) = ["--holstate", path]

fun tail_text path =
  let
    val tmp = FS.tmpName ()
    val _ = OS.Process.system ("tail -n 80 " ^ HolbuildToolchain.quote path ^
                               " > " ^ HolbuildToolchain.quote tmp)
    val text = read_text tmp handle _ => ""
    val _ = remove_file tmp
  in
    text
  end

fun echo_child_logs () = env_bool "HOLBUILD_ECHO_CHILD_LOGS" false

fun run_hol_files_to_log tc stage context files log_name error_message =
  let
    val log = Path.concat(stage, log_name)
    val status =
      HolbuildToolchain.run_in_dir_to_file stage
        ([HolbuildToolchain.hol tc, "run", "--noconfig"] @ hol_context_args context @ files)
        log
  in
    if HolbuildToolchain.success status then
      if echo_child_logs () then HolbuildStatus.message TextIO.stdOut (read_text log handle _ => "") else ()
    else
      raise Error (String.concatWith "\n"
        [error_message,
         "child log: " ^ log,
         "--- child log tail ---",
         tail_text log,
         "--- end child log tail ---"])
  end

fun toolchain_base_context tc = HolState (HolbuildToolchain.base_state tc)

val cache_sml_token = "__HOLBUILD_THEORY_DAT_LOAD__"

fun warn msg = HolbuildStatus.message TextIO.stdErr ("holbuild: warning: " ^ msg ^ "\n")

fun nonempty_line line = List.exists (not o Char.isSpace) (String.explode line)

fun last_nonempty_line text =
  List.foldl (fn (line, last) => if nonempty_line line then SOME line else last)
             NONE
             (String.tokens (fn c => c = #"\n") text)

fun truncate_text limit text =
  if size text <= limit then text
  else String.substring(text, 0, limit - 3) ^ "..."

fun summarize_log path =
  Option.map (truncate_text 240) (last_nonempty_line (read_text path))
  handle _ => NONE

fun preserve_checkpoint_failure_log project node input_key stage =
  let
    val src = Path.concat(stage, "holbuild-build.log")
    val dst = retained_checkpoint_failure_log project node input_key
  in
    if file_exists src then
      (ensure_parent dst; copy_binary src dst; SOME dst)
      handle _ => SOME src
    else NONE
  end

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

fun cache_manifest_text {input_key, sig_hash, sml_hash, dat_hash, mldeps} =
  String.concatWith "\n"
    (["holbuild-cache-action-v1",
      "input_key=" ^ input_key,
      "kind=theory",
      "mldeps"] @
     map (fn dep => "mldep " ^ dep) mldeps @
     ["blob sig " ^ sig_hash,
      "blob sml-template " ^ sml_hash,
      "blob dat " ^ dat_hash]) ^ "\n"

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

fun transient_stage_mldep dep = String.isSubstring "/.holbuild/stage/" dep

fun valid_mldep_name dep =
  dep <> "" andalso all_chars (fn c => not (Char.isSpace c)) dep

fun reject_transient_cache_mldeps mldeps =
  case List.find transient_stage_mldep mldeps of
      SOME dep => raise Error ("cache manifest contains transient stage mldep: " ^ dep)
    | NONE => ()

fun add_mldep dep deps =
  if not (valid_mldep_name dep) then
    raise Error ("cache manifest invalid mldep: " ^ dep)
  else if List.exists (fn existing => existing = dep) deps then deps
  else dep :: deps

fun parse_cache_manifest_line input_key line (saw_header, saw_input, saw_kind, saw_mldeps, blobs, mldeps) =
  if line = "holbuild-cache-action-v1" then
    if saw_header then raise Error "cache manifest duplicate header"
    else (true, saw_input, saw_kind, saw_mldeps, blobs, mldeps)
  else if line = "input_key=" ^ input_key then
    if saw_input then raise Error "cache manifest duplicate input key"
    else (saw_header, true, saw_kind, saw_mldeps, blobs, mldeps)
  else if String.isPrefix "input_key=" line then
    raise Error "cache manifest input key mismatch"
  else if line = "kind=theory" then
    if saw_kind then raise Error "cache manifest duplicate kind"
    else (saw_header, saw_input, true, saw_mldeps, blobs, mldeps)
  else if String.isPrefix "kind=" line then
    raise Error "cache manifest unsupported kind"
  else if line = "mldeps" then
    if saw_mldeps then raise Error "cache manifest duplicate mldeps marker"
    else (saw_header, saw_input, saw_kind, true, blobs, mldeps)
  else
    case String.tokens Char.isSpace line of
        ["mldep", dep] => (saw_header, saw_input, saw_kind, saw_mldeps, blobs, add_mldep dep mldeps)
      | ["blob", role, hash] => (saw_header, saw_input, saw_kind, saw_mldeps, add_manifest_blob role hash blobs, mldeps)
      | _ => raise Error ("cache manifest unknown line: " ^ line)

fun cache_manifest_blobs_from_lines input_key lines =
  let
    val (saw_header, saw_input, saw_kind, saw_mldeps, blobs, mldeps) =
      List.foldl (fn (line, state) => parse_cache_manifest_line input_key line state)
                 (false, false, false, false, [], []) lines
    val _ = if saw_header then () else raise Error "cache manifest missing header"
    val _ = if saw_input then () else raise Error "cache manifest missing input key"
    val _ = if saw_kind then () else raise Error "cache manifest missing kind"
    val _ = if saw_mldeps then () else raise Error "cache manifest missing mldeps marker"
  in
    let val stable_mldeps = rev mldeps
        val _ = reject_transient_cache_mldeps stable_mldeps
    in
      {sig_hash = blob_from_manifest "sig" blobs,
       sml_hash = blob_from_manifest "sml-template" blobs,
       dat_hash = blob_from_manifest "dat" blobs,
       mldeps = stable_mldeps}
    end
  end

fun cache_manifest_blobs root input_key =
  let val manifest = HolbuildCache.action_manifest root input_key
  in cache_manifest_blobs_from_lines input_key (cache_manifest_lines (read_text manifest)) end

fun cache_entry_usable root input_key text =
  let
    val {sig_hash, sml_hash, dat_hash, ...} =
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

fun file_strings path =
  let
    val tmp = FS.tmpName ()
    fun cleanup () = remove_file tmp
    fun run () =
      let val status = OS.Process.system ("strings -a " ^ HolbuildToolchain.quote path ^
                                          " > " ^ HolbuildToolchain.quote tmp)
      in
        if OS.Process.isSuccess status then read_text tmp else ""
      end
  in
    (run () before cleanup ()) handle e => (cleanup (); "")
  end

fun dat_mentions_stage_key input_key staged_dat =
  let val text = file_strings staged_dat
  in
    String.isSubstring input_key text andalso
    String.isSubstring ".holbuild" text andalso
    String.isSubstring "stage" text
  end

fun publish_theory_cache input_key dat_replacements staged_sig staged_sml staged_dat mldeps =
  let
    val root = cache_root ()
    val _ = HolbuildCache.ensure_layout root
    val template = FS.tmpName ()
    val cache_mldeps = List.filter (not o transient_stage_mldep) mldeps
    val cacheable = not (List.exists transient_stage_mldep mldeps andalso dat_mentions_stage_key input_key staged_dat)
    val manifest_path = HolbuildCache.action_manifest root input_key
    fun cleanup () = FS.remove template handle OS.SysErr _ => ()
    fun drop_noncacheable () = remove_file manifest_path
    fun publish () =
      let
        val _ = write_text template (rewrite_all dat_replacements (read_text staged_sml))
        val sig_hash = cache_blob root staged_sig
        val sml_hash = cache_blob root template
        val dat_hash = cache_blob root staged_dat
        val manifest = cache_manifest_text {input_key = input_key, sig_hash = sig_hash,
                                            sml_hash = sml_hash, dat_hash = dat_hash,
                                            mldeps = cache_mldeps}
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
    ((if cacheable then
        HolbuildCache.with_action_publish_lock root input_key publish skip_locked_publish
      else
        HolbuildCache.with_action_publish_lock root input_key drop_noncacheable skip_locked_publish);
     cleanup ())
    handle e => (cleanup (); warn ("could not publish cache entry: " ^ General.exnMessage e))
  end

fun project_node_named plan name =
  List.find (fn candidate => HolbuildBuildPlan.logical_name candidate = name) plan

fun mldep_load_stem plan dep =
  case project_node_named plan dep of
      SOME node => load_stem node
    | NONE => dep

fun mldep_load_stems plan mldeps = unique_strings (map (mldep_load_stem plan) mldeps)

fun stable_generated_mldeps mldeps =
  List.filter (not o transient_stage_mldep) mldeps

fun drop_object_suffix path =
  if has_suffix ".uo" path then String.substring(path, 0, size path - 3)
  else if has_suffix ".ui" path then String.substring(path, 0, size path - 3)
  else path

fun same_path a b = Path.mkCanonical a = Path.mkCanonical b handle Path.InvalidArc => a = b

fun generated_holdep_stem plan tc dep =
  let
    val stem = drop_object_suffix dep
    val sigobj = Path.concat(#holdir tc, "sigobj")
    fun same_load_stem node = same_path (load_stem node) stem
  in
    case List.find same_load_stem plan of
        SOME node => HolbuildBuildPlan.logical_name node
      | NONE => if same_path (Path.dir stem) sigobj then Path.file stem else stem
  end

fun holfs_unmapped_theory_artifact path =
  let
    val {dir, file} = Path.splitDirFile path
    val {dir = parent, file = leaf} = Path.splitDirFile dir
  in
    if leaf = "objs" andalso Path.file parent = ".hol" then
      Path.concat(Path.dir parent, file)
    else path
  end

fun generated_holdep_include_dirs tc plan =
  unique_strings (Path.concat(#holdir tc, "sigobj") :: map (Path.dir o load_stem) plan)

fun generated_holdep_mldeps plan tc path =
  let
    val deps = HolbuildDependencies.resolved_holdep_deps
                 (generated_holdep_include_dirs tc plan)
                 (holfs_unmapped_theory_artifact path)
  in
    unique_strings (map (generated_holdep_stem plan tc) deps)
  end

fun read_mldeps_report path =
  let
    val deps = String.tokens (fn c => c = #"\n") (read_text path)
    val _ =
      List.app
        (fn dep => if valid_mldep_name dep then ()
                   else raise Error ("invalid generated theory ML dependency: " ^ dep))
        deps
  in
    unique_strings deps
  end

fun write_local_theory_manifests plan node mldeps =
  let
    val {sig_path, sml_path, script_uo, theory_ui, theory_uo, ...} = theory_outputs node
    val deps = HolbuildBuildPlan.direct_project_deps plan node
    val theory_loads = HolbuildBuildPlan.direct_external_theories plan node @
                       project_theory_load_stems deps @
                       mldep_load_stems plan (stable_generated_mldeps mldeps)
    val script_loads = direct_external_loads plan node @ project_load_stems deps
  in
    write_object_manifest theory_ui [sig_path];
    write_object_manifest theory_uo (theory_loads @ [sml_path]);
    write_object_manifest script_uo (script_loads @ [source_file node])
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
       theory_uo, hfs_remapped_path theory_uo]
  in
    List.app remove_file paths;
    remove_checkpoint_family project node
  end

fun materialize_theory_cache _ project plan input_key node =
  let
    val root = cache_root ()
    val manifest = HolbuildCache.action_manifest root input_key
    val _ = if file_exists manifest then () else raise Error "cache entry not found"
    val _ = FS.setTime (manifest, NONE) handle OS.SysErr _ => ()
    val {sig_hash, sml_hash, dat_hash, mldeps} = cache_manifest_blobs root input_key
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
       write_local_theory_manifests plan node mldeps;
       remove_checkpoint_family project node;
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

fun theorem_context_path project node deps_key prefix_hash safe_name =
  Path.concat(theorem_checkpoint_dir project node deps_key prefix_hash,
              safe_name ^ "_context.save")

fun theorem_end_of_proof_path project node deps_key prefix_hash safe_name =
  Path.concat(theorem_checkpoint_dir project node deps_key prefix_hash,
              safe_name ^ "_end_of_proof.save")

fun bool_digit true = "1"
  | bool_digit false = "0"

fun theorem_report_line name theorem_start theorem_stop tactic_start tactic_end has_attrs =
  String.concatWith "\t"
    ["theorem", name, Int.toString theorem_start, Int.toString theorem_stop,
     Int.toString tactic_start, Int.toString tactic_end, bool_digit has_attrs]

fun theorem_report_lines result =
  let
    fun loop acc =
      case #parseDec result () of
          NONE => rev acc
        | SOME (HOLSourceAST.HOLTheoremDecl {theorem_, id = (_, name), proof_, tac, stop, ...}) =>
            let
              val (tactic_start, tactic_end) = HOLSourceAST.expSpan tac
              val has_attrs = case proof_ of SOME {attrs = SOME _, ...} => true | _ => false
              val line = theorem_report_line name theorem_ stop tactic_start tactic_end has_attrs
            in
              loop (line :: acc)
            end
        | SOME _ => loop acc
  in
    loop []
  end

fun parse_error _ _ msg = raise Error ("HOL source parse error: " ^ msg)

fun parser_reader source_text =
  let val fed = ref false
  in fn _ => if !fed then "" else (fed := true; source_text) end

fun discover_theorem_boundaries source_path source_text =
  let
    val result = HOLSourceParser.parseSML source_path (parser_reader source_text) parse_error
                   HOLSourceParser.initialScope
    val report = String.concatWith "\n" (theorem_report_lines result) ^ "\n"
  in
    HolbuildTheoryCheckpoints.discover_from_report {source = source_text, report = report}
  end

fun theorem_checkpoint_key {name, safe_name, boundary, deps_key, prefix_hash} =
  HolbuildToolchain.hash_text
    (String.concatWith "\n"
       ["holbuild-theorem-checkpoint-key-v1",
        "name=" ^ name,
        "safe_name=" ^ safe_name,
        "boundary=" ^ Int.toString boundary,
        "deps_key=" ^ deps_key,
        "prefix_key=" ^ prefix_hash] ^ "\n")

fun theorem_checkpoint_ok kind deps_key prefix_hash checkpoint_key =
  checkpoint_ok_text kind
    [("deps_key", deps_key),
     ("prefix_key", prefix_hash),
     ("checkpoint_key", checkpoint_key)]

fun theorem_checkpoint_specs project node deps_key boundaries =
  map (fn {name, safe_name, theorem_start, theorem_stop, boundary, tactic_start,
           tactic_end, tactic_text, has_proof_attrs, prefix_hash} =>
          let
            val checkpoint_key = theorem_checkpoint_key {name = name, safe_name = safe_name,
                                                         boundary = boundary, deps_key = deps_key,
                                                         prefix_hash = prefix_hash}
          in
            {name = name, safe_name = safe_name, theorem_start = theorem_start,
             theorem_stop = theorem_stop, boundary = boundary,
             tactic_start = tactic_start, tactic_end = tactic_end,
             tactic_text = tactic_text, has_proof_attrs = has_proof_attrs,
             prefix_hash = prefix_hash,
             context_path = theorem_context_path project node deps_key prefix_hash safe_name,
             context_ok = theorem_checkpoint_ok "theorem_context" deps_key prefix_hash checkpoint_key,
             end_of_proof_path = theorem_end_of_proof_path project node deps_key prefix_hash safe_name,
             end_of_proof_ok = theorem_checkpoint_ok "end_of_proof" deps_key prefix_hash checkpoint_key,
             deps_key = deps_key,
             checkpoint_key = checkpoint_key}
          end)
      boundaries

fun dependency_context_key toolchain_key plan keys node =
  let
    val project_deps = HolbuildBuildPlan.transitive_project_deps plan node
    val external_theories = HolbuildBuildPlan.direct_external_theories plan node
    val external_libs = HolbuildBuildPlan.direct_external_libs plan node
    val project_lines = map (fn dep => "project " ^ HolbuildBuildPlan.key dep ^ " " ^
                                       HolbuildBuildPlan.input_key_for keys dep)
                            project_deps
    val theory_lines = map (fn dep => "external_theory " ^ dep) external_theories
    val lib_lines = map (fn dep => "external_lib " ^ dep) external_libs
  in
    HolbuildToolchain.hash_text
      (String.concatWith "\n"
         (["holbuild-dependency-context-v1",
           "toolchain_key=" ^ toolchain_key] @ project_lines @ theory_lines @ lib_lines) ^ "\n")
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

fun checkpoint_ok_matches path fields =
  file_exists path andalso
  case current_metadata (checkpoint_ok_path path) of
      SOME text =>
        let val lines = metadata_lines text
        in
          List.exists (fn line => line = "holbuild-checkpoint-ok-v2") lines andalso
          List.all (fn (key, value) => metadata_value key lines = SOME value) fields
        end
    | NONE => false

fun deps_checkpoint_ok_text deps_key =
  checkpoint_ok_text "deps_loaded" [("deps_key", deps_key)]

fun deps_checkpoint_exists path deps_key =
  checkpoint_ok_matches path [("kind", "deps_loaded"), ("deps_key", deps_key)]

fun theorem_context_checkpoint_exists project node checkpoint =
  let val deps_loaded = deps_loaded_path project node (#deps_key checkpoint)
  in
    deps_checkpoint_exists deps_loaded (#deps_key checkpoint) andalso
    checkpoint_ok_matches (#context_path checkpoint)
      [("kind", "theorem_context"),
       ("deps_key", #deps_key checkpoint),
       ("prefix_key", #prefix_hash checkpoint),
       ("checkpoint_key", #checkpoint_key checkpoint)]
  end

fun replay_candidates project node checkpoints =
  List.mapPartial
    (fn checkpoint =>
        if theorem_context_checkpoint_exists project node checkpoint then
          SOME {boundary = #boundary checkpoint, path = #context_path checkpoint,
                safe_name = #safe_name checkpoint}
        else NONE)
    checkpoints

fun later_candidate (a, b) = if #boundary a >= #boundary b then a else b

fun best_replay_candidate project node checkpoints =
  case replay_candidates project node checkpoints of
      [] => NONE
    | first :: rest => SOME (List.foldl later_candidate first rest)

type build_options = {use_cache : bool, skip_checkpoints : bool, goalfrag : bool, tactic_timeout : real option}

datatype checkpoint_policy =
  CheckpointPolicy of {checkpoint : bool, goalfrag : bool, tactic_timeout : real option}

val no_checkpoint_policy =
  CheckpointPolicy {checkpoint = false, goalfrag = false, tactic_timeout = NONE}

fun checkpoint_enabled (CheckpointPolicy {checkpoint, ...}) = checkpoint
fun goalfrag_enabled (CheckpointPolicy {goalfrag, ...}) = goalfrag
fun tactic_timeout (CheckpointPolicy {tactic_timeout, ...}) = tactic_timeout

fun timeout_text NONE = "none"
  | timeout_text (SOME seconds) = Real.toString seconds

fun bool_text true = "true"
  | bool_text false = "false"

val theory_manifest_version = "1"

(* Final theory artifacts are semantic products of source bytes, resolved deps,
   toolchain, and declared action policy. Execution strategy is deliberately not
   part of this key: goalfrag/checkpoint/tactic-timeout affect inspectability and
   replay/debug behavior, not the identity of the generated .uo/.ui/.dat bundle.
   Checkpoint files carry their own validity in the filesystem and .ok metadata. *)
fun policy_config_lines _ =
  ["theory_manifest_version=" ^ theory_manifest_version]

fun instrumented_source policy timeout_marker source_text start_offset checkpoints =
  if goalfrag_enabled policy then
    HolbuildTheoryCheckpoints.instrument
      {source = source_text, start_offset = start_offset, checkpoints = checkpoints,
       save_checkpoints = checkpoint_enabled policy,
       tactic_timeout = tactic_timeout policy,
       timeout_marker = timeout_marker}
  else source_text

fun replay_candidate project node checkpoints =
  if always_reexecute node then NONE
  else best_replay_candidate project node checkpoints

fun checkpoint_resume_message node label =
  HolbuildStatus.message TextIO.stdOut
    (String.concat ["resuming ", logical_name node, " from checkpoint ", label, "\n"])

fun write_theory_script policy project base_context plan keys input_key toolchain_key node source_text checkpoints staged_script preload timeout_marker =
  if not (checkpoint_enabled policy) then
    (write_plain_preload plan node preload;
     write_text staged_script (instrumented_source policy (SOME timeout_marker) source_text 0 checkpoints);
     {context = base_context, files = [preload, staged_script], failure_checkpoints = []})
  else
    let
      val deps_key = dependency_context_key toolchain_key plan keys node
      val deps_loaded = deps_loaded_path project node deps_key
      val deps_ok = deps_checkpoint_ok_text deps_key
      fun run_from_deps_checkpoint () =
        (write_text staged_script (instrumented_source policy (SOME timeout_marker) source_text 0 checkpoints);
         checkpoint_resume_message node "deps_loaded";
         {context = HolState deps_loaded, files = [staged_script], failure_checkpoints = [deps_loaded]})
      fun run_from_fresh_preload () =
        (write_preload plan node deps_loaded deps_ok preload;
         write_text staged_script (instrumented_source policy (SOME timeout_marker) source_text 0 checkpoints);
         {context = base_context, files = [preload, staged_script], failure_checkpoints = []})
    in
      case replay_candidate project node checkpoints of
          SOME {boundary, path, safe_name} =>
            let
              val _ = write_text staged_script (instrumented_source policy (SOME timeout_marker) source_text boundary checkpoints)
              val _ = checkpoint_resume_message node safe_name
            in
              {context = HolState path, files = [staged_script], failure_checkpoints = [path, deps_loaded]}
            end
        | NONE =>
            if deps_checkpoint_exists deps_loaded deps_key then run_from_deps_checkpoint ()
            else run_from_fresh_preload ()
    end

fun build_theory cache_allowed policy tc project base_context plan keys toolchain_key node source_text theorem_checkpoints =
  let
    val input_key = HolbuildBuildPlan.input_key_for keys node
    val stage = stage_dir project input_key
    val staged_script = Path.concat(stage, Path.file (source_file node))
    val preload = Path.concat(stage, "holbuild-preload.sml")
    val final_loader = Path.concat(stage, "holbuild-save-final-context.sml")
    val mldeps_report = Path.concat(stage, "holbuild-theory-mldeps.txt")
    val timeout_marker = Path.concat(stage, "holbuild-tactic-timeout.txt")
    val deps_key = dependency_context_key toolchain_key plan keys node
    val deps_loaded = deps_loaded_path project node deps_key
    val deps_ok = deps_checkpoint_ok_text deps_key
    val final_context = final_context_path project node
    val {sig_path, sml_path, data_path, script_uo, theory_ui, theory_uo} = theory_outputs node
    val staged_sig = staged_theory_file stage node ".sig"
    val staged_sml = staged_theory_file stage node ".sml"
    val staged_dat = staged_theory_file stage node ".dat"
    val _ = ensure_dir stage
    val _ = if checkpoint_enabled policy then ensure_parent deps_loaded else ()
    val _ = if checkpoint_enabled policy then ensure_parent final_context else ()
    val _ =
      if checkpoint_enabled policy then
        List.app (fn {context_path, end_of_proof_path, ...} =>
                    (ensure_parent context_path; ensure_parent end_of_proof_path))
                 theorem_checkpoints
      else ()
    val _ =
      if checkpoint_enabled policy then
        write_final_context_loader
          {sig_path = staged_sig, sml_path = staged_sml,
           output = final_context, path = final_loader,
           mldeps_report = SOME mldeps_report}
      else
        write_plain_final_context_loader
          {sig_path = staged_sig, sml_path = staged_sml,
           path = final_loader, mldeps_report = SOME mldeps_report}
    val _ = remove_file timeout_marker
    val run_spec = write_theory_script policy project base_context plan keys input_key toolchain_key node
                                    source_text theorem_checkpoints staged_script preload timeout_marker
    fun tactic_timeout_error () =
      Error ("tactic timed out while building " ^ logical_name node ^ ": " ^
             String.concatWith " " (String.tokens Char.isSpace (read_text timeout_marker)))
    fun discard_failure_checkpoints () =
      List.app remove_checkpoint (#failure_checkpoints run_spec)
    fun checkpoint_failure_error msg =
      let
        val _ = discard_failure_checkpoints ()
        val failure_log = preserve_checkpoint_failure_log project node input_key stage
        val reason = Option.mapPartial summarize_log failure_log
        val detail =
          String.concat
            [logical_name node,
             " goalfrag/checkpoint run failed\n",
             "plain-source fallback disabled; use --skip-checkpoints to avoid replay or --skip-goalfrag to run source directly\n",
             case failure_log of NONE => "" | SOME path => "instrumented log: " ^ path ^ "\n",
             case reason of NONE => "" | SOME line => "last log line: " ^ line ^ "\n"]
      in
        Error detail
      end
    val _ =
      run_hol_files_to_log tc stage (#context run_spec)
        (#files run_spec @ [final_loader])
        "holbuild-build.log"
        "hol run failed while building theory script"
      handle Error msg =>
        if file_exists timeout_marker then raise tactic_timeout_error ()
        else if null theorem_checkpoints then raise Error msg
        else raise checkpoint_failure_error msg
    val _ = copy_binary staged_dat data_path
    val _ = copy_binary staged_dat (hfs_remapped_path data_path)
    val _ = copy_binary staged_sig sig_path
    val _ = copy_binary staged_sig (hfs_remapped_path sig_path)
    val dat_replacements = stage_dat_replacements stage node data_path
    val cache_replacements = stage_dat_replacements stage node cache_sml_token
    val _ = copy_rewriting_path {src = staged_sml, dst = sml_path,
                                 replacements = dat_replacements}
    val _ = copy_binary sml_path (hfs_remapped_path sml_path)
    val mldeps = unique_strings (read_mldeps_report mldeps_report @
                                  generated_holdep_mldeps plan tc staged_sml)
    val _ =
      if cache_allowed then
        publish_theory_cache input_key cache_replacements staged_sig staged_sml staged_dat mldeps
      else ()
  in
    write_local_theory_manifests plan node mldeps;
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
    val external_loads = direct_external_loads plan node
  in
    write_object_manifest output (external_loads @ project_load_stems deps @ [source_file node]);
    if output_suffix = ".uo" then write_empty_ui_if_needed plan node else ()
  end

fun output_paths _ _ node =
  let
    val artifacts = source_artifacts node
    val generated_paths = #generated artifacts
    val object_paths = #objects artifacts
    val data_paths = #theory_data artifacts
  in
    generated_paths @ map hfs_remapped_path generated_paths @
    object_paths @ map hfs_remapped_path object_paths @
    data_paths @ map hfs_remapped_path data_paths
  end

fun output_hash_line path = "output-sha1=" ^ path ^ " " ^ file_hash path

fun checkpoint_lines _ _ _ = []

fun dependency_context_lines plan keys toolchain_key node =
  case #kind (HolbuildBuildPlan.source_of node) of
      HolbuildSourceIndex.TheoryScript =>
        ["dependency_context_key=" ^ dependency_context_key toolchain_key plan keys node]
    | _ => []

fun action_policy_lines node =
  let
    val policy = source_policy node
    val declared_dep_lines =
      map (fn dep => "declared_dep=" ^ dep) (HolbuildProject.action_deps policy)
    val declared_load_lines =
      map (fn dep => "declared_load=" ^ dep) (HolbuildProject.action_loads policy)
    val extra_inputs = HolbuildProject.action_extra_inputs policy
    val extra_lines =
      map (fn input =>
             "extra_input=" ^ HolbuildProject.extra_input_path input ^ "@" ^
             file_hash (HolbuildProject.extra_input_absolute_path input))
          extra_inputs
  in
    ["cache=" ^ bool_text (HolbuildProject.action_cache_enabled policy),
     "always_reexecute=" ^ bool_text (HolbuildProject.action_always_reexecute policy)] @
    declared_dep_lines @
    declared_load_lines @
    extra_lines
  end

fun theorem_boundary_line ({safe_name, prefix_hash, context_path, end_of_proof_path, ...} : HolbuildTheoryCheckpoints.checkpoint) =
  "theorem_boundary " ^ safe_name ^ " " ^ prefix_hash ^ " " ^
  context_path ^ " " ^ end_of_proof_path

fun theorem_boundary_lines theorem_checkpoints =
  map theorem_boundary_line theorem_checkpoints

fun metadata_core_lines checkpoint_policy project plan keys input_key toolchain_key node theorem_checkpoints =
  let
    val source = HolbuildBuildPlan.source_of node
  in
    ["holbuild-action-metadata-v1",
     "input_key=" ^ input_key,
     "toolchain_key=" ^ toolchain_key,
     "kind=" ^ HolbuildSourceIndex.kind_string (#kind source),
     "package=" ^ #package source,
     "logical=" ^ #logical_name source,
     "source=" ^ #relative_path source] @
    dependency_context_lines plan keys toolchain_key node @
    action_policy_lines node @
    checkpoint_lines checkpoint_policy project node @
    theorem_boundary_lines theorem_checkpoints
  end

fun lines_text lines = String.concatWith "\n" lines ^ "\n"

fun metadata_core_text checkpoint_policy project plan keys input_key toolchain_key node theorem_checkpoints =
  lines_text (metadata_core_lines checkpoint_policy project plan keys input_key toolchain_key node theorem_checkpoints)

fun metadata_text checkpoint_policy project plan keys input_key toolchain_key node theorem_checkpoints =
  lines_text
    (metadata_core_lines checkpoint_policy project plan keys input_key toolchain_key node theorem_checkpoints @
     map output_hash_line (output_paths checkpoint_policy project node))

fun semantic_metadata_text text =
  lines_text (List.filter (fn line => not (String.isPrefix "output-sha1=" line))
                          (metadata_lines text))

fun metadata_input_key_matches input_key text =
  case metadata_value "input_key" (metadata_lines text) of
      SOME old_key => old_key = input_key
    | NONE => false

(* Up-to-date is intentionally a cheap semantic check. The input_key already
   commits to source hash, dependency keys, toolchain key, and declared action
   policy, so do not rebuild full diagnostic metadata here; doing so recomputes
   dependency-context closures for every unchanged node. *)
fun file_nonempty path = file_exists path andalso OS.FileSys.fileSize path > 0

fun output_exists_for_node node path =
  case #kind (HolbuildBuildPlan.source_of node) of
      HolbuildSourceIndex.TheoryScript => file_nonempty path
    | _ => file_exists path

fun up_to_date checkpoint_policy project _ _ input_key _ node _ =
  List.all (output_exists_for_node node) (output_paths checkpoint_policy project node) andalso
  (case current_metadata (metadata_path project node) of
       SOME text => metadata_input_key_matches input_key text
     | NONE => false)

fun write_metadata checkpoint_policy project plan keys input_key toolchain_key node theorem_checkpoints =
  write_text (metadata_path project node)
             (metadata_text checkpoint_policy project plan keys input_key toolchain_key node theorem_checkpoints)

fun root_package_name project =
  HolbuildProject.package_name (HolbuildProject.project_package project)

fun root_package_node project node =
  HolbuildBuildPlan.package node = root_package_name project

fun effective_tactic_timeout goalfrag root_package tactic_timeout =
  if goalfrag andalso root_package then tactic_timeout else NONE

fun checkpoint_policy_for_node ({skip_checkpoints, goalfrag, tactic_timeout, ...} : build_options) project node =
  CheckpointPolicy {checkpoint = not skip_checkpoints,
                    goalfrag = goalfrag,
                    tactic_timeout = effective_tactic_timeout goalfrag (root_package_node project node) tactic_timeout}

fun build_config_lines_for_node options project node =
  case #kind (HolbuildBuildPlan.source_of node) of
      HolbuildSourceIndex.TheoryScript => policy_config_lines (checkpoint_policy_for_node options project node)
    | HolbuildSourceIndex.Sml => policy_config_lines no_checkpoint_policy
    | HolbuildSourceIndex.Sig => policy_config_lines no_checkpoint_policy

fun theory_checkpoints_for_node policy project plan keys toolchain_key node source_text =
  if not (goalfrag_enabled policy) then []
  else
    let
      val deps_key = dependency_context_key toolchain_key plan keys node
      val boundaries = discover_theorem_boundaries (source_file node) source_text
    in
      theorem_checkpoint_specs project node deps_key boundaries
    end

fun build_theory_node (options : build_options) tc project base_context plan keys toolchain_key node input_key =
  let
    val policy = checkpoint_policy_for_node options project node
    val metadata_checkpoints = []
    val stage = stage_dir project input_key
    val cache_allowed = #use_cache options andalso cache_enabled node
  in
    if not (always_reexecute node) andalso
       up_to_date policy project plan keys input_key toolchain_key node metadata_checkpoints then
      (remove_tree_if_exists stage;
       HolbuildStatus.UpToDate)
    else if cache_allowed andalso
            materialize_theory_cache tc project plan input_key node then
      (remove_tree stage;
       write_metadata policy project plan keys input_key toolchain_key node metadata_checkpoints;
       remove_checkpoint_family project node;
       HolbuildStatus.Restored)
    else
      let
        val source_text = read_text (source_file node)
        val theorem_checkpoints =
          theory_checkpoints_for_node policy project plan keys toolchain_key node source_text
      in
        build_theory cache_allowed policy tc project base_context plan keys toolchain_key node source_text theorem_checkpoints;
        write_metadata policy project plan keys input_key toolchain_key node metadata_checkpoints;
        remove_checkpoint_family project node;
        HolbuildStatus.Built
      end
  end

fun build_node options tc project base_context plan keys toolchain_key node =
  let val input_key = HolbuildBuildPlan.input_key_for keys node
  in
    case #kind (HolbuildBuildPlan.source_of node) of
        HolbuildSourceIndex.TheoryScript =>
          build_theory_node options tc project base_context plan keys toolchain_key node input_key
      | HolbuildSourceIndex.Sml =>
          if not (always_reexecute node) andalso
             up_to_date no_checkpoint_policy project plan keys input_key toolchain_key node [] then
            HolbuildStatus.UpToDate
          else (build_sml_like plan node ".uo";
                write_metadata no_checkpoint_policy project plan keys input_key toolchain_key node [];
                HolbuildStatus.Built)
      | HolbuildSourceIndex.Sig =>
          if not (always_reexecute node) andalso
             up_to_date no_checkpoint_policy project plan keys input_key toolchain_key node [] then
            HolbuildStatus.UpToDate
          else (build_sml_like plan node ".ui";
                write_metadata no_checkpoint_policy project plan keys input_key toolchain_key node [];
                HolbuildStatus.Built)
  end

fun node_policy options project node =
  case #kind (HolbuildBuildPlan.source_of node) of
      HolbuildSourceIndex.TheoryScript => checkpoint_policy_for_node options project node
    | HolbuildSourceIndex.Sml => no_checkpoint_policy
    | HolbuildSourceIndex.Sig => no_checkpoint_policy

fun node_is_up_to_date options project plan keys toolchain_key node =
  not (always_reexecute node) andalso
  up_to_date (node_policy options project node)
             project plan keys (HolbuildBuildPlan.input_key_for keys node)
             toolchain_key node []

fun report_up_to_date_node status project keys node =
  let
    val input_key = HolbuildBuildPlan.input_key_for keys node
    val key = HolbuildBuildPlan.key node
    val label = HolbuildBuildPlan.logical_name node
  in
    HolbuildStatus.start_node status key label;
    case #kind (HolbuildBuildPlan.source_of node) of
        HolbuildSourceIndex.TheoryScript => remove_tree_if_exists (stage_dir project input_key)
      | _ => ();
    HolbuildStatus.finish_node status key label HolbuildStatus.UpToDate
  end

fun all_nodes_up_to_date options project plan keys toolchain_key =
  List.all (node_is_up_to_date options project plan keys toolchain_key) plan

fun report_all_up_to_date status project keys plan =
  List.app (report_up_to_date_node status project keys) plan

fun build_one status options tc project base_context plan keys toolchain_key node =
  let
    val key = HolbuildBuildPlan.key node
    val label = HolbuildBuildPlan.logical_name node
    val _ = HolbuildStatus.start_node status key label
    val outcome = build_node options tc project base_context plan keys toolchain_key node
  in
    HolbuildStatus.finish_node status key label outcome
  end

fun build_serial status options tc project base_context plan keys toolchain_key =
  let
    fun error_message e =
      case e of
          Error msg => msg
        | _ => General.exnMessage e
    fun one node =
      build_one status options tc project base_context plan keys toolchain_key node
      handle e =>
        let val msg = error_message e
        in
          HolbuildStatus.fail status (HolbuildBuildPlan.key node)
                                (HolbuildBuildPlan.logical_name node) msg;
          raise e
        end
  in
    List.app one plan
  end

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

fun build_parallel status options tc project base_context plan keys toolchain_key jobs =
  let
    (* Keep scheduler state explicit and reusable: precompute reverse dependency
       edges once, then release dependents by decrementing remaining_dep counts.
       Do not add a serial all-up-to-date preflight in front of this path; that
       duplicates the unchanged-prefix work before any parallel worker can run. *)
    val node_count = length plan
    val nodes = Vector.fromList plan
    val key_index = HolbuildBuildPlan.build_key_index plan
    val lookup = HolbuildBuildPlan.indexed_nodes_named (HolbuildBuildPlan.build_name_index plan)
    val remaining_deps = Array.array (node_count, 0)
    val dependents = Array.array (node_count, [] : int list)
    val ready = ref ([] : int list)
    val mutex = Thread.Mutex.mutex ()
    val cv = Thread.ConditionVar.conditionVar ()
    val running = ref 0
    val completed = ref 0
    val active = ref jobs
    val failure = ref (NONE : string option)

    fun node_id node = HolbuildBuildPlan.indexed_key_id key_index (HolbuildBuildPlan.key node)

    fun add_ready id = ready := id :: !ready

    fun register_node (id, node) =
      let val deps = HolbuildBuildPlan.direct_project_deps_with lookup plan node
      in
        Array.update (remaining_deps, id, length deps);
        if null deps then add_ready id else ();
        List.app
          (fn dep =>
              let val dep_id = node_id dep
              in Array.update (dependents, dep_id, id :: Array.sub (dependents, dep_id)) end)
          deps
      end

    fun register_nodes id =
      if id >= node_count then ()
      else (register_node (id, Vector.sub (nodes, id)); register_nodes (id + 1))

    val _ = register_nodes 0

    fun signal () = Thread.ConditionVar.broadcast cv
    fun lock () = Thread.Mutex.lock mutex
    fun unlock () = Thread.Mutex.unlock mutex

    fun pop_ready () =
      case !ready of
          [] => NONE
        | id :: rest => (ready := rest; SOME id)

    fun next_work_locked () =
      case !failure of
          SOME _ => NONE
        | NONE =>
            case pop_ready () of
                SOME id => (running := !running + 1; SOME id)
              | NONE =>
                  if !completed = node_count andalso !running = 0 then NONE
                  else (Thread.ConditionVar.wait (cv, mutex); next_work_locked ())

    fun with_lock f =
      (lock (); f () before unlock ())
      handle e => (unlock (); raise e)

    fun next_work () = with_lock next_work_locked

    fun release_dependent child_id =
      let val remaining = Array.sub (remaining_deps, child_id) - 1
      in
        Array.update (remaining_deps, child_id, remaining);
        if remaining = 0 then add_ready child_id else ()
      end

    fun finish_success id =
      with_lock
        (fn () =>
            (running := !running - 1;
             completed := !completed + 1;
             List.app release_dependent (Array.sub (dependents, id));
             signal ()))

    fun finish_failure msg =
      let
        val first_failure =
          with_lock
            (fn () =>
                let
                  val _ = running := !running - 1
                  val first =
                    case !failure of
                        SOME _ => false
                      | NONE => (failure := SOME msg; true)
                in
                  signal ();
                  first
                end)
      in
        if first_failure then HolbuildToolchain.cleanup_active_children () else ()
      end

    fun worker_exit () =
      with_lock (fn () => (active := !active - 1; signal ()))

    fun worker () =
      let
        fun loop () =
          case next_work () of
              NONE => worker_exit ()
            | SOME id =>
                let val node = Vector.sub (nodes, id)
                in
                  ((build_one status options tc project base_context plan keys toolchain_key node;
                    finish_success id;
                    loop ())
                   handle e =>
                     let
                       val msg = build_error_message e
                     in
                       HolbuildStatus.fail status (HolbuildBuildPlan.key node)
                                             (HolbuildBuildPlan.logical_name node) msg;
                       finish_failure msg;
                       worker_exit ()
                     end)
                end
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

fun build (options : build_options) tc project plan toolchain_key jobs =
  let
    val base_context = toolchain_base_context tc
    val keys = HolbuildBuildPlan.input_keys (build_config_lines_for_node options project) toolchain_key plan
  in
    let
      val status = HolbuildStatus.create {total = length plan, jobs = jobs}
      fun run () =
        if jobs <= 1 then build_serial status options tc project base_context plan keys toolchain_key
        else build_parallel status options tc project base_context plan keys toolchain_key jobs
    in
      (run (); HolbuildStatus.finish status)
      handle e => (HolbuildStatus.finish status; raise e)
    end
  end

fun heap_external_theories plan =
  unique_strings (List.concat (map (HolbuildBuildPlan.direct_external_theories plan) plan))

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
      [save_heap_line {label = "heap", share_common_data = false,
                       output = output, ok_text = checkpoint_ok_v1 ()}]
  in
    write_text path (String.concatWith "\n" lines ^ "\n")
  end

fun export_heap tc (project : HolbuildProject.t) plan output =
  let
    val base_context = toolchain_base_context tc
    val stage = Path.concat(Path.concat(#root project, ".holbuild/stage"), "heap")
    val loader = Path.concat(stage, "holbuild-save-heap.sml")
  in
    ensure_dir stage;
    ensure_parent output;
    write_heap_loader plan output loader;
    run_hol_files_to_log tc stage base_context [loader]
      "holbuild-heap.log"
      ("hol run failed while exporting heap: " ^ output);
    remove_tree stage
  end

end
