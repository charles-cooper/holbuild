structure HolbuildCommands =
struct

exception Error of string

fun err msg = (TextIO.output(TextIO.stdErr, "holbuild: " ^ msg ^ "\n");
               OS.Process.exit OS.Process.failure)

fun warn msg = TextIO.output(TextIO.stdErr, "holbuild: warning: " ^ msg ^ "\n")

fun usage () = print
  "holbuild: experimental project-aware build frontend for HOL4\n\n\
  \Usage:\n\
  \  holbuild [--holdir PATH] [-jN] context\n\
  \  holbuild [--holdir PATH] [-jN] build [--dry-run] [--skip-checkpoints] [--skip-goalfrag] [--tactic-timeout SECONDS] [TARGET ...]\n\
  \  holbuild [--holdir PATH] [-jN] heap NAME\n\
  \  holbuild [--holdir PATH] run [ARG ...]\n\
  \  holbuild [--holdir PATH] repl [ARG ...]\n\
  \  holbuild cache gc [--retention-days DAYS] [--cache-dir PATH]\n\n\
  \HOLDIR is found from --holdir, HOLBUILD_HOLDIR, or HOLDIR for HOL commands.\n\
  \-j/--jobs controls build parallelism and defaults to 1.\n"

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
    fun loop dry skip_checkpoints goalfrag tactic_timeout tactic_timeout_set rest =
      case rest of
          [] => ({dry_run = dry, skip_checkpoints = skip_checkpoints,
                  goalfrag = goalfrag, tactic_timeout = tactic_timeout,
                  tactic_timeout_set = tactic_timeout_set}, [])
        | "--dry-run" :: xs =>
            loop true skip_checkpoints goalfrag tactic_timeout tactic_timeout_set xs
        | "--skip-checkpoints" :: xs =>
            loop dry true goalfrag tactic_timeout tactic_timeout_set xs
        | "--skip-goalfrag" :: xs =>
            loop dry skip_checkpoints false tactic_timeout tactic_timeout_set xs
        | "--tactic-timeout" :: seconds :: xs =>
            loop dry skip_checkpoints goalfrag (tactic_timeout_value seconds) true xs
        | "--tactic-timeout" :: [] => raise Error "--tactic-timeout requires SECONDS"
        | x :: xs =>
            if String.isPrefix "--tactic-timeout=" x then
              loop dry skip_checkpoints goalfrag
                   (tactic_timeout_value (String.extract (x, size "--tactic-timeout=", NONE)))
                   true xs
            else
              let val (flags, ys) = loop dry skip_checkpoints goalfrag tactic_timeout tactic_timeout_set xs
              in (flags, x :: ys) end
  in
    loop false false true (SOME 2.5) false args
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
    fun loop holdir jobs rest =
      case rest of
          [] => ({holdir = holdir, jobs = jobs}, [])
        | "--holdir" :: path :: xs => loop (SOME path) jobs xs
        | "--jobs" :: n :: xs => loop holdir (positive_int "--jobs" n) xs
        | "-j" :: n :: xs => loop holdir (positive_int "-j" n) xs
        | arg :: xs =>
            if String.isPrefix "--holdir=" arg then
              loop (SOME (String.extract (arg, size "--holdir=", NONE))) jobs xs
            else if String.isPrefix "--jobs=" arg then
              loop holdir (positive_int "--jobs" (String.extract (arg, size "--jobs=", NONE))) xs
            else if String.isPrefix "-j" arg andalso size arg > 2 then
              loop holdir (positive_int "-j" (String.extract (arg, 2, NONE))) xs
            else
              let val (opts, args') = loop holdir jobs xs in (opts, arg :: args') end
  in
    loop NONE 1 args
  end

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

fun build tc jobs args =
  let
    val project = load_project ()
    val ({dry_run, skip_checkpoints, goalfrag, tactic_timeout, tactic_timeout_set}, targets) = split_flags args
    val _ =
      if not goalfrag andalso tactic_timeout_set then
        raise Error "--tactic-timeout requires goalfrag; remove --skip-goalfrag"
      else ()
    val build_options = {skip_checkpoints = skip_checkpoints,
                         goalfrag = goalfrag,
                         tactic_timeout = tactic_timeout}
    val index = HolbuildSourceIndex.discover project
    val requested_targets = targets
    val targets = default_build_targets project index requested_targets
    val _ = reject_object_targets targets
    val plan = HolbuildBuildPlan.plan (#holdir tc) index targets
    val _ = if null requested_targets andalso not (null targets) then
              warn_unreachable_root_scripts project index plan
            else ()
    val toolchain_key = HolbuildToolchain.toolchain_key tc
  in
    if dry_run then HolbuildBuildPlan.describe (HolbuildBuildExec.build_config_lines build_options) toolchain_key plan
    else
      HolbuildBuildExec.with_project_lock project "build"
        (fn () => HolbuildBuildExec.build build_options tc project plan toolchain_key jobs)
  end

fun heap_named project target =
  let
    fun matches (HolbuildProject.Heap {name, ...}) = name = target
  in
    case List.find matches (#heaps project) of
        SOME heap => heap
      | NONE => raise Error ("unknown heap target: " ^ target)
  end

fun build_heap tc jobs target =
  let
    val project = load_project ()
    val HolbuildProject.Heap {output, objects, ...} = heap_named project target
    val _ = if null objects then raise Error ("heap target has no objects: " ^ target) else ()
    val index = HolbuildSourceIndex.discover project
    val plan = HolbuildBuildPlan.plan (#holdir tc) index objects
    val toolchain_key = HolbuildToolchain.toolchain_key tc
    val output_path = HolbuildProject.abs_under (#root project) output
  in
    HolbuildBuildExec.with_project_lock project ("heap " ^ target)
      (fn () =>
          (HolbuildBuildExec.build {skip_checkpoints = false, goalfrag = true, tactic_timeout = SOME 2.5}
                                  tc project plan toolchain_key jobs;
           HolbuildBuildExec.export_heap tc project plan output_path))
  end

fun hol_args_for_project tc project subcommand user_args =
  let
    val context = HolbuildToolchain.write_run_context project
    val heap_args =
      case HolbuildProject.abs_run_heap project of
          NONE => ["--holstate", HolbuildToolchain.base_state tc]
        | SOME heap => ["--holstate", heap]
  in
    [subcommand] @ heap_args @ [context] @ #run_loads project @ user_args
  end

fun run_hol tc subcommand user_args =
  let
    val project = load_project ()
    val argv = HolbuildToolchain.hol tc :: hol_args_for_project tc project subcommand user_args
    val status = HolbuildToolchain.run argv
  in
    if HolbuildToolchain.success status then ()
    else raise Error ("hol " ^ subcommand ^ " failed")
  end

fun dispatch tc jobs args =
  case args of
      [] => context ()
    | "context" :: [] => context ()
    | "build" :: rest => build tc jobs rest
    | "heap" :: [target] => build_heap tc jobs target
    | "heap" :: _ => raise Error "usage: holbuild heap NAME"
    | "run" :: rest => run_hol tc "run" rest
    | "repl" :: rest => run_hol tc "repl" rest
    | cmd :: _ => raise Error ("unknown command: " ^ cmd)

fun dispatch_with_options {holdir, jobs} args =
  case args of
      "cache" :: rest => HolbuildCache.dispatch rest
    | _ =>
      let val tc = {holdir = runtime_holdir holdir}
      in dispatch tc jobs args end

fun main raw_args =
  (let
     val _ =
       if List.exists (fn s => s = "--help" orelse s = "-h" orelse s = "help") raw_args
       then (usage (); OS.Process.exit OS.Process.success)
       else ()
     val (options, args) = parse_global_options raw_args
   in
     dispatch_with_options options args
   end)
  handle Error msg => err msg
       | HolbuildToolchain.Error msg => err msg
       | HolbuildProject.Error msg => err msg
       | HolbuildSourceIndex.Error msg => err msg
       | HolbuildDependencies.Error msg => err msg
       | HolbuildBuildPlan.Error msg => err msg
       | HolbuildBuildExec.Error msg => err msg
       | HolbuildCache.Error msg => err msg
       | e => err (General.exnMessage e)

end
