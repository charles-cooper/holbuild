fun compile_holdir () =
  case OS.Process.getEnv "HOLBUILD_HOLDIR" of
      SOME h => h
    | NONE =>
      case OS.Process.getEnv "HOLDIR" of
          SOME h => h
        | NONE =>
          raise Fail "set HOLBUILD_HOLDIR or HOLDIR when compiling holbuild";

val compile_time_holdir = compile_holdir ();

structure HolbuildRuntimePaths =
struct
  val source_root = OS.FileSys.getDir ()
end

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
use_hol("src/portableML/DString.sig");
use_hol("src/portableML/DString.sml");
use_hol("src/portableML/DArray.sig");
use_hol("src/portableML/DArray.sml");
use_hol("tools/Holmake/hfs/HOLFS_dtype.sml");
use_hol("tools/Holmake/hfs/HFS_NameMunge.sig");
use_hol("tools/Holmake/poly/HFS_NameMunge.sml");
use_hol("tools/Holmake/hfs/HOLFileSys.sig");
use_hol("tools/Holmake/hfs/HOLFileSys.sml");
use_hol("tools/Holmake/deps/Holdep_tokens.sig");
use_hol("tools/Holmake/deps/Holdep_tokens.sml");
use_hol("tools/Holmake/Systeml.sig");
use_hol("tools/Holmake/Systeml.sml");
use_hol("tools/Holmake/util/terminal_primitives.sig");
use_hol("tools/Holmake/util/poly-terminal-prims.ML");
use_hol("tools/parsing/AttributeSyntax.sig");
use_hol("tools/parsing/AttributeSyntax.sml");
use_hol("tools/parsing/HOLSourceAST.sig");
use_hol("tools/parsing/HOLSourceAST.sml");
use_hol("tools/parsing/HOLSourceParser.sig");
use_hol("tools/parsing/HOLSourceParser.sml");
use_hol("tools/parsing/HOLSourceExpand.sig");
use_hol("tools/parsing/HOLSourceExpand.sml");
use_hol("tools/parsing/HOLSourcePrinter.sig");
use_hol("tools/parsing/HOLSourcePrinter.sml");
use_hol("tools/parsing/HOLSource.sig");
use_hol("tools/parsing/HOLSource.sml");
use_hol("tools/Holmake/deps/Holdep.sig");
use_hol("tools/Holmake/deps/Holdep.sml");
use_hol("tools/Holmake/toml/TOML.sig");
use_hol("tools/Holmake/toml/TOML.sml");
use_hol("src/portableML/poly/SHA1_ML.sig");
use_hol("src/portableML/poly/w64-SHA1.ML");

use "sml/hash.sml";
use "sml/project.sml";
use "sml/source_index.sml";
use "sml/dependencies.sml";
use "sml/build_plan.sml";
use "sml/toolchain.sml";
use "sml/status.sml";
use "sml/theory_checkpoints.sml";
use "sml/cache.sml";
use "sml/build_exec.sml";
use "sml/commands.sml";

fun main () = HolbuildCommands.main (CommandLine.arguments())
