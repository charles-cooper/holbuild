fun compile_holdir () =
  case OS.Process.getEnv "HOLBUILD_HOLDIR" of
      SOME h => h
    | NONE =>
      case OS.Process.getEnv "HOLDIR" of
          SOME h => h
        | NONE =>
          raise Fail "set HOLBUILD_HOLDIR or HOLDIR when compiling holbuild";

val compile_time_holdir = compile_holdir ();

fun use_hol rel = use (OS.Path.concat(compile_time_holdir, rel));

use_hol("tools/Holmake/toml/TOMLvalue_dtype.sml");
use_hol("tools/Holmake/toml/TOMLvalue.sig");
use_hol("tools/Holmake/toml/TOMLvalue.sml");
use_hol("tools/Holmake/toml/TOMLerror.sml");
use_hol("tools/Holmake/toml/parseTOMLUtil.sml");
use_hol("tools/Holmake/toml/parseTOMLFunctor.sml");
use_hol("tools/Holmake/toml/parseTOML.sml");
use_hol("tools-poly/poly/Binarymap.sig");
use_hol("tools-poly/poly/Binarymap.sml");
use_hol("tools/Holmake/toml/TOML.sig");
use_hol("tools/Holmake/toml/TOML.sml");
use_hol("src/portableML/poly/SHA1_ML.sig");
use_hol("src/portableML/poly/w64-SHA1.ML");

use "sml/project.sml";
use "sml/source_index.sml";
use "sml/dependencies.sml";
use "sml/build_plan.sml";
use "sml/toolchain.sml";
use "sml/cache.sml";
use "sml/build_exec.sml";
use "sml/commands.sml";

fun main () = HolbuildCommands.main (CommandLine.arguments())
