structure HolbuildCommands =
struct

exception Error of string

fun err msg =
  (if HolbuildStatus.json_mode () then HolbuildStatus.error msg
   else HolbuildStatus.message_stderr ("holbuild: " ^ msg ^ "\n");
   OS.Process.exit OS.Process.failure)

fun warn msg = HolbuildStatus.message_stderr ("holbuild: warning: " ^ msg ^ "\n")

fun usage () = print
  "holbuild: experimental project-aware build frontend for HOL4\n\n\
  \Usage:\n\
  \  holbuild [--json] [--holdir PATH] [--maxheap MB] [-jN] context\n\
  \  holbuild [--json] [--holdir PATH] [--maxheap MB] [-jN] build [--dry-run] [--no-cache] [--skip-checkpoints] [--skip-goalfrag] [--tactic-timeout SECONDS] [TARGET ...]\n\
  \  holbuild [--json] [--holdir PATH] [--maxheap MB] [-jN] heap NAME\n\
  \  holbuild [--json] [--holdir PATH] [--maxheap MB] run [ARG ...]\n\
  \  holbuild [--json] [--holdir PATH] [--maxheap MB] repl [ARG ...]\n\
  \  holbuild cache gc [--retention-days DAYS] [--cache-dir PATH]\n\n\
  \HOLDIR is found from --holdir, HOLBUILD_HOLDIR, or HOLDIR for HOL commands.\n\
  \-j/--jobs controls build parallelism. Default is .holconfig.toml [build].jobs,\n\
  \or max(1, detected processor count / 2). --maxheap/--max-heap passes Poly/ML\n\
  \maximum heap size in MB to child HOL processes. --json emits newline-delimited\n\
  \JSON for build status, messages, and errors.\n"

fun nonnegative_real label text =
  case Real.fromString text of
      SOME n =>
        if n >= 0.0 then n
        else raise Error (label ^ " must be a non-negative number")
    | NONE => raise Error (label ^ " must be a non-negative number")

fun tactic_timeout_value text =
  let val seconds = nonnegative_real "--tactic-timeout" text
  in if seconds <= 0.0 then NONE else SOME seconds end

fun split_flags args =
  let
    fun loop dry use_cache skip_checkpoints goalfrag tactic_timeout tactic_timeout_set rest =
      case rest of
          [] => ({dry_run = dry, use_cache = use_cache,
                  skip_checkpoints = skip_checkpoints,
                  goalfrag = goalfrag, tactic_timeout = tactic_timeout,
                  tactic_timeout_set = tactic_timeout_set}, [])
        | "--dry-run" :: xs =>
            loop true use_cache skip_checkpoints goalfrag tactic_timeout tactic_timeout_set xs
        | "--no-cache" :: xs =>
            loop dry false skip_checkpoints goalfrag tactic_timeout tactic_timeout_set xs
        | "--skip-checkpoints" :: xs =>
            loop dry use_cache true goalfrag tactic_timeout tactic_timeout_set xs
        | "--skip-goalfrag" :: xs =>
            loop dry use_cache skip_checkpoints false tactic_timeout tactic_timeout_set xs
        | "--tactic-timeout" :: seconds :: xs =>
            loop dry use_cache skip_checkpoints goalfrag (tactic_timeout_value seconds) true xs
        | "--tactic-timeout" :: [] => raise Error "--tactic-timeout requires SECONDS"
        | x :: xs =>
            if String.isPrefix "--tactic-timeout=" x then
              loop dry use_cache skip_checkpoints goalfrag
                   (tactic_timeout_value (String.extract (x, size "--tactic-timeout=", NONE)))
                   true xs
            else
              let val (flags, ys) = loop dry use_cache skip_checkpoints goalfrag tactic_timeout tactic_timeout_set xs
              in (flags, x :: ys) end
  in
    loop false true false true NONE false args
  end

fun has_suffix suffix s =
  let
    val n = size s
    val m = size suffix
  in
    n >= m andalso String.substring(s, n - m, m) = suffix
  end

fun reject_object_target target =
  if has_suffix ".uo" target orelse has_suffix ".ui" target orelse
     has_suffix ".dat" target orelse has_suffix ".art" target then
    raise Error ("build targets are logical names, not object files: " ^ target)
  else ()

fun reject_object_targets targets = List.app reject_object_target targets

fun default_build_targets project index targets =
  if null targets then HolbuildSourceIndex.default_targets index project else targets

fun source_key source =
  #package source ^ "\000" ^ #relative_path source ^ "\000" ^ #logical_name source

fun key_member key keys = List.exists (fn k => k = key) keys

fun rooted_package_names project =
  map HolbuildProject.package_name
    (List.filter (fn package => not (null (HolbuildProject.package_roots package)))
                 (HolbuildProject.packages project))

fun root_warning_source rooted_packages built_keys source =
  #kind source = HolbuildSourceIndex.TheoryScript andalso
  key_member (#package source) rooted_packages andalso
  not (key_member (source_key source) built_keys)

fun warn_unreachable_root_scripts project index plan =
  let
    val rooted_packages = rooted_package_names project
    val built_keys = map (source_key o HolbuildBuildPlan.source_of) plan
    val unreachable = List.filter (root_warning_source rooted_packages built_keys) index
    fun describe source = #package source ^ ":" ^ #relative_path source ^ " (" ^ #logical_name source ^ ")"
    val limit = 20
    fun take (0, _) = []
      | take (_, []) = []
      | take (n, x :: xs) = x :: take (n - 1, xs)
  in
    case unreachable of
        [] => ()
      | _ =>
        (warn (Int.toString (length unreachable) ^
               " discoverable theory script(s) are not reachable from build.roots");
         List.app (fn source => warn ("  unreachable: " ^ describe source))
                  (take (limit, unreachable));
         if length unreachable > limit then
           warn ("  ... " ^ Int.toString (length unreachable - limit) ^ " more")
         else ())
  end

fun positive_int label text =
  case Int.fromString text of
      SOME n => if n >= 1 then n else raise Error (label ^ " must be a positive integer")
    | NONE => raise Error (label ^ " must be a positive integer")

fun parse_global_options args =
  let
    fun loop holdir jobs maxheap json rest =
      case rest of
          [] => ({holdir = holdir, jobs = jobs, maxheap = maxheap, json = json}, [])
        | "--json" :: xs => loop holdir jobs maxheap true xs
        | "--holdir" :: path :: xs => loop (SOME path) jobs maxheap json xs
        | "--jobs" :: n :: xs => loop holdir (SOME (positive_int "--jobs" n)) maxheap json xs
        | "-j" :: n :: xs => loop holdir (SOME (positive_int "-j" n)) maxheap json xs
        | "--maxheap" :: n :: xs => loop holdir jobs (SOME (positive_int "--maxheap" n)) json xs
        | "--max-heap" :: n :: xs => loop holdir jobs (SOME (positive_int "--max-heap" n)) json xs
        | arg :: xs =>
            if String.isPrefix "--holdir=" arg then
              loop (SOME (String.extract (arg, size "--holdir=", NONE))) jobs maxheap json xs
            else if String.isPrefix "--jobs=" arg then
              loop holdir (SOME (positive_int "--jobs" (String.extract (arg, size "--jobs=", NONE)))) maxheap json xs
            else if String.isPrefix "--maxheap=" arg then
              loop holdir jobs (SOME (positive_int "--maxheap" (String.extract (arg, size "--maxheap=", NONE)))) json xs
            else if String.isPrefix "--max-heap=" arg then
              loop holdir jobs (SOME (positive_int "--max-heap" (String.extract (arg, size "--max-heap=", NONE)))) json xs
            else if String.isPrefix "-j" arg andalso size arg > 2 then
              loop holdir (SOME (positive_int "-j" (String.extract (arg, 2, NONE)))) maxheap json xs
            else
              let val (opts, args') = loop holdir jobs maxheap json xs in (opts, arg :: args') end
  in
    loop NONE NONE NONE false args
  end

fun with_input path f =
  let val ins = TextIO.openIn path
  in (f ins before TextIO.closeIn ins)
     handle e => (TextIO.closeIn ins; raise e)
  end

fun detected_processors () =
  let
    fun count ins n =
      case TextIO.inputLine ins of
          NONE => n
        | SOME line =>
            if String.isPrefix "processor" line then count ins (n + 1)
            else count ins n
    val n = with_input "/proc/cpuinfo" (fn ins => count ins 0)
  in
    if n > 0 then n else 2
  end
  handle _ => 2

fun default_jobs () = Int.max (1, detected_processors () div 2)

fun effective_jobs (project : HolbuildProject.t) cli_jobs =
  case cli_jobs of
      SOME jobs => jobs
    | NONE => Option.getOpt (#local_build_jobs project, default_jobs ())

fun runtime_holdir cline_holdir =
  case cline_holdir of
      SOME h => h
    | NONE =>
      case OS.Process.getEnv "HOLBUILD_HOLDIR" of
          SOME h => h
        | NONE =>
          case OS.Process.getEnv "HOLDIR" of
              SOME h => h
            | NONE => raise Error "set --holdir, HOLBUILD_HOLDIR, or HOLDIR"

fun load_project () =
  HolbuildProject.discover ()
  handle HolbuildProject.Error msg => raise Error msg

fun context () = HolbuildProject.describe (load_project ())

fun timed_phase name f = HolbuildToolchain.time_phase name f

fun build tc cli_jobs args =
  let
    val project = timed_phase "project.discover" load_project
    val jobs = effective_jobs project cli_jobs
    val ({dry_run, use_cache, skip_checkpoints, goalfrag, tactic_timeout, tactic_timeout_set}, targets) = split_flags args
    val _ =
      if HolbuildStatus.json_mode () andalso dry_run then
        raise Error "--json does not support build --dry-run yet"
      else if not goalfrag andalso tactic_timeout_set then
        raise Error "--tactic-timeout requires goalfrag; remove --skip-goalfrag"
      else ()
    val build_options = {use_cache = use_cache,
                         skip_checkpoints = skip_checkpoints,
                         goalfrag = goalfrag,
                         tactic_timeout =
                           case tactic_timeout of
                               SOME _ => tactic_timeout
                             | NONE => (case #build_tactic_timeout project of
                                          NONE => SOME 2.5
                                        | some => some)}
    fun prepare_plan () =
      let
        val index = timed_phase "source.discover" (fn () => HolbuildSourceIndex.discover project)
        val requested_targets = targets
        val targets = timed_phase "targets.default" (fn () => default_build_targets project index requested_targets)
        val _ = reject_object_targets targets
        val plan = timed_phase "build.plan" (fn () => HolbuildBuildPlan.plan (#holdir tc) index targets)
        val _ = if null requested_targets andalso not (null targets) then
                  warn_unreachable_root_scripts project index plan
                else ()
        val toolchain_key = timed_phase "toolchain.key" (fn () => HolbuildToolchain.toolchain_key tc)
      in
        (plan, toolchain_key)
      end
    fun describe_dry_run () =
      let val (plan, toolchain_key) = prepare_plan ()
      in
        timed_phase "dry_run.describe"
          (fn () => HolbuildBuildPlan.describe (HolbuildBuildExec.build_config_lines_for_node build_options project) toolchain_key plan)
      end
    fun execute_build () =
      let val (plan, toolchain_key) = prepare_plan ()
      in
        timed_phase "build.execute"
          (fn () => HolbuildBuildExec.build build_options tc project plan toolchain_key jobs)
      end
  in
    if dry_run then describe_dry_run ()
    else HolbuildBuildExec.with_project_lock project "build" execute_build
  end

fun heap_named project target =
  let
    fun matches (HolbuildProject.Heap {name, ...}) = name = target
  in
    case List.find matches (#heaps project) of
        SOME heap => heap
      | NONE => raise Error ("unknown heap target: " ^ target)
  end

fun build_heap tc cli_jobs target =
  let
    val project = timed_phase "project.discover" load_project
    val jobs = effective_jobs project cli_jobs
    fun execute_heap () =
      let
        val HolbuildProject.Heap {output, objects, ...} = heap_named project target
        val _ = if null objects then raise Error ("heap target has no objects: " ^ target) else ()
        val index = timed_phase "source.discover" (fn () => HolbuildSourceIndex.discover project)
        val plan = timed_phase "build.plan" (fn () => HolbuildBuildPlan.plan (#holdir tc) index objects)
        val toolchain_key = timed_phase "toolchain.key" (fn () => HolbuildToolchain.toolchain_key tc)
        val output_path = HolbuildProject.abs_under (#root project) output
      in
        HolbuildBuildExec.build {use_cache = true, skip_checkpoints = false, goalfrag = true, tactic_timeout = SOME 2.5}
                               tc project plan toolchain_key jobs;
        HolbuildBuildExec.export_heap tc project plan output_path
      end
  in
    HolbuildBuildExec.with_project_lock project ("heap " ^ target) execute_heap
  end

fun hol_args_for_project tc project subcommand user_args =
  let
    val context = HolbuildToolchain.write_run_context project
    val heap_args =
      case HolbuildProject.abs_run_heap project of
          NONE => ["--holstate", HolbuildToolchain.base_state tc]
        | SOME heap => ["--holstate", heap]
  in
    HolbuildToolchain.hol_subcommand_argv tc subcommand @ heap_args @ [context] @ #run_loads project @ user_args
  end

fun run_hol tc subcommand user_args =
  let
    val project = timed_phase "project.discover" load_project
    val argv = hol_args_for_project tc project subcommand user_args
    val status = HolbuildToolchain.run argv
  in
    if HolbuildToolchain.success status then ()
    else raise Error ("hol " ^ subcommand ^ " failed")
  end

fun reject_json command =
  if HolbuildStatus.json_mode () then
    raise Error ("--json does not support " ^ command ^ " yet")
  else ()

fun dispatch tc jobs args =
  case args of
      [] => (reject_json "context"; context ())
    | "context" :: [] => (reject_json "context"; context ())
    | "build" :: rest => build tc jobs rest
    | "heap" :: [target] => (reject_json "heap"; build_heap tc jobs target)
    | "heap" :: _ => raise Error "usage: holbuild heap NAME"
    | "run" :: rest => (reject_json "run"; run_hol tc "run" rest)
    | "repl" :: rest => (reject_json "repl"; run_hol tc "repl" rest)
    | cmd :: _ => raise Error ("unknown command: " ^ cmd)

fun dispatch_with_options {holdir, jobs, maxheap, json} args =
  (HolbuildStatus.set_json_mode json;
   case args of
       "cache" :: rest => (reject_json "cache"; HolbuildCache.dispatch rest)
     | _ =>
       let
         val tc = {holdir = runtime_holdir holdir, maxheap = maxheap}
         val _ = HolbuildProject.set_holdir (#holdir tc)
       in
         dispatch tc jobs args
       end)

fun main raw_args =
  (let
     val _ = HolbuildStatus.set_json_mode (List.exists (fn s => s = "--json") raw_args)
     val _ =
       if List.exists (fn s => s = "--help" orelse s = "-h" orelse s = "help") raw_args
       then (usage (); OS.Process.exit OS.Process.success)
       else ()
     val (options, args) = parse_global_options raw_args
   in
     dispatch_with_options options args
   end)
  handle Thread.Thread.Interrupt => (HolbuildToolchain.cleanup_active_children (); err "interrupted")
       | Error msg => err msg
       | HolbuildToolchain.Error msg => err msg
       | HolbuildProject.Error msg => err msg
       | HolbuildSourceIndex.Error msg => err msg
       | HolbuildDependencies.Error msg => err msg
       | HolbuildBuildPlan.Error msg => err msg
       | HolbuildBuildExec.Error msg => err msg
       | HolbuildCache.Error msg => err msg
       | e => err (General.exnMessage e)

end
