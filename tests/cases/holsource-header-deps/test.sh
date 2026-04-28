#!/usr/bin/env bash
set -euo pipefail

HOLBUILD_BIN=$1
HOLDIR=$2
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../../lib.sh
source "$SCRIPT_DIR/../../lib.sh"

tmpdir=$(make_temp_dir)
cleanup() { rm -rf "$tmpdir"; }
trap cleanup EXIT
export HOLBUILD_CACHE="$tmpdir/cache"

project=$tmpdir/project
mkdir -p "$project/src"
cat > "$project/holproject.toml" <<'TOML'
[project]
name = "headerdeps"

[build]
members = ["src"]
TOML
cat > "$project/src/AScript.sml" <<'SML'
Theory A
Ancestors arithmetic[qualified, ignore_grammar] string
Libs numLib monadsyntax

Type identifier = “:string”;

val _ = Theory.add_ML_dependency "monadsyntax";

Theorem add_one:
  1 + 1 = 2
Proof
  numLib.REDUCE_TAC
QED

val _ = export_theory();
SML
cat > "$project/src/BScript.sml" <<'SML'
Theory B
Ancestors A

Theorem two:
  2 = 2
Proof
  simp[]
QED

val _ = export_theory();
SML

(cd "$project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" build --dry-run ATheory) > "$tmpdir/dry.log"
require_grep "external theories: arithmeticTheory, stringTheory" "$tmpdir/dry.log"
require_grep "external libs: monadsyntax, numLib" "$tmpdir/dry.log"
if grep -q "ignore_grammar\|qualified\|identifier" "$tmpdir/dry.log"; then
  echo "HOLSource header/body qualifier or Type declaration was misclassified" >&2
  exit 1
fi

(cd "$project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" build BTheory) > "$tmpdir/build.log"
require_file "$project/.holbuild/gen/src/ATheory.sml"
require_file "$project/.holbuild/obj/src/ATheory.dat"
require_file "$project/.holbuild/obj/src/BTheory.dat"
require_grep "numLib" "$project/.holbuild/obj/src/AScript.uo"
require_grep "monadsyntax" "$project/.holbuild/obj/src/AScript.uo"
require_grep "arithmeticTheory" "$project/.holbuild/obj/src/ATheory.uo"
require_grep "monadsyntax" "$project/.holbuild/obj/src/ATheory.uo"
if grep -q "numLib" "$project/.holbuild/obj/src/ATheory.uo"; then
  echo "source-only Libs leaked into generated theory load manifest" >&2
  exit 1
fi
if grep -q "numLib" "$project/.holbuild/obj/src/BTheory.uo"; then
  echo "dependency source-only Libs leaked into dependent theory load manifest" >&2
  exit 1
fi
require_grep "dependency_context_key=" "$project/.holbuild/dep/headerdeps/src/AScript.sml.key"

rm -rf "$project/.holbuild"
(cd "$project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" build BTheory) > "$tmpdir/cache.log"
require_grep "ATheory restored from cache" "$tmpdir/cache.log"
require_grep "monadsyntax" "$project/.holbuild/obj/src/ATheory.uo"
if grep -q "numLib" "$project/.holbuild/obj/src/ATheory.uo"; then
  echo "cache restore leaked source-only Libs into generated theory load manifest" >&2
  exit 1
fi
