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
Ancestors arithmetic
Libs numLib

Theorem add_one:
  1 + 1 = 2
Proof
  numLib.REDUCE_TAC
QED

val _ = export_theory();
SML

(cd "$project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" build --dry-run ATheory) > "$tmpdir/dry.log"
require_grep "external theories: arithmeticTheory" "$tmpdir/dry.log"
require_grep "external libs: numLib" "$tmpdir/dry.log"

(cd "$project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" build ATheory) > "$tmpdir/build.log"
require_file "$project/.holbuild/gen/src/ATheory.sml"
require_file "$project/.holbuild/obj/src/ATheory.dat"
require_grep "numLib" "$project/.holbuild/obj/src/AScript.uo"
require_grep "numLib" "$project/.holbuild/obj/src/ATheory.uo"
require_grep "dependency_context_key=" "$project/.holbuild/dep/headerdeps/src/AScript.sml.key"
