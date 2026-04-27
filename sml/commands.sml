structure HolbuildCommands =
struct

exception Error of string

fun err msg = (TextIO.output(TextIO.stdErr, "holbuild: " ^ msg ^ "\n");
               OS.Process.exit OS.Process.failure)

fun usage () = print
  "holbuild: experimental project-aware build frontend for HOL4\n\n\
  \Usage:\n\
  \  holbuild [--holdir PATH] context\n\
  \  holbuild [--holdir PATH] build [--dry-run] [TARGET ...]\n\
  \  holbuild [--holdir PATH] run [ARG ...]\n\
  \  holbuild [--holdir PATH] repl [ARG ...]\n\n\
  \HOLDIR is found from --holdir, HOLBUILD_HOLDIR, or HOLDIR.\n"

fun split_flags args =
  let
    fun loop dry rest =
      case rest of
          [] => (dry, [])
        | "--dry-run" :: xs => loop true xs
        | x :: xs => let val (d, ys) = loop dry xs in (d, x :: ys) end
  in
    loop false args
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

fun take_holdir args =
  case args of
      [] => (NONE, [])
    | "--holdir" :: path :: rest => (SOME path, rest)
    | arg :: rest =>
        if String.isPrefix "--holdir=" arg then
          (SOME (String.extract (arg, size "--holdir=", NONE)), rest)
        else
          let val (h, rest') = take_holdir rest in (h, arg :: rest') end

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

fun build tc args =
  let
    val project = load_project ()
    val (dry_run, targets) = split_flags args
    val _ = reject_object_targets targets
    val index = HolbuildSourceIndex.discover project
    val plan = HolbuildBuildPlan.plan index targets
    val toolchain_key = HolbuildToolchain.toolchain_key tc
  in
    if dry_run then HolbuildBuildPlan.describe toolchain_key plan
    else HolbuildBuildExec.build tc project plan toolchain_key
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

fun dispatch tc args =
  case args of
      [] => context ()
    | "context" :: [] => context ()
    | "build" :: rest => build tc rest
    | "run" :: rest => run_hol tc "run" rest
    | "repl" :: rest => run_hol tc "repl" rest
    | cmd :: _ => raise Error ("unknown command: " ^ cmd)

fun main raw_args =
  let
    val _ =
      if List.exists (fn s => s = "--help" orelse s = "-h" orelse s = "help") raw_args
      then (usage (); OS.Process.exit OS.Process.success)
      else ()
    val (holdir_opt, args) = take_holdir raw_args
    val tc = {holdir = runtime_holdir holdir_opt}
  in
    dispatch tc args
    handle Error msg => err msg
         | HolbuildToolchain.Error msg => err msg
         | HolbuildProject.Error msg => err msg
         | HolbuildSourceIndex.Error msg => err msg
         | HolbuildDependencies.Error msg => err msg
         | HolbuildBuildPlan.Error msg => err msg
         | HolbuildBuildExec.Error msg => err msg
         | e => err (General.exnMessage e)
  end

end
