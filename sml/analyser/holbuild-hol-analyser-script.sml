fun compile_holdir () =
  case OS.Process.getEnv "HOLBUILD_HOLDIR" of
      SOME h => h
    | NONE =>
      case OS.Process.getEnv "HOLDIR" of
          SOME h => h
        | NONE => raise Fail "set HOLBUILD_HOLDIR or HOLDIR when compiling holbuild-hol-analyser";

fun analyser_src () =
  case OS.Process.getEnv "HOLBUILD_ANALYSER_SRC" of
      SOME h => h
    | NONE => raise Fail "set HOLBUILD_ANALYSER_SRC when compiling holbuild-hol-analyser";

val compile_time_holdir = compile_holdir ();
val source_dir = analyser_src ();

fun path_join (a, b) = OS.Path.concat(a, b);
fun use_hol rel = use (path_join(compile_time_holdir, rel));
fun use_src rel = use (path_join(source_dir, rel));

fun load_poly_hol_context () =
  let val origdir = OS.FileSys.getDir ()
  in
    OS.FileSys.chDir (path_join(compile_time_holdir, "tools-poly"));
    use "poly/poly-init2.ML";
    OS.FileSys.chDir origdir
  end;

load_poly_hol_context ();
Meta.quiet_load := true;

use_hol("tools/Holmake/deps/Holdep_tokens.sig");
use_hol("tools/Holmake/deps/Holdep_tokens.sml");
use_hol("tools/Holmake/deps/Holdep.sig");
use_hol("tools/Holmake/deps/Holdep.sml");

use_src "analysis_protocol.sml";
use_src "dependency_extract.sml";
use_src "analyser_main.sml";

fun main () = OS.Process.exit (HolbuildAnalyserMain.main (CommandLine.arguments()))
