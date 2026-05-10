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

dep=$tmpdir/dep
nested=$tmpdir/nested
project=$tmpdir/project
shimdir=$tmpdir/shims
mkdir -p "$dep/src" "$nested/src" "$project/src" "$shimdir"

cat > "$dep/holproject.toml" <<'TOML'
[project]
name = "dep"

[build]
members = ["src"]
TOML
cat > "$dep/src/AScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
val _ = new_theory "A";
val a_thm = store_thm("a_thm", ``T``, ACCEPT_TAC TRUTH);
val _ = export_theory();
SML

cat > "$nested/holproject.toml" <<'TOML'
[project]
name = "nested"

[build]
members = ["src"]
TOML
cat > "$nested/src/CScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
val _ = new_theory "C";
val c_thm = store_thm("c_thm", ``T``, ACCEPT_TAC TRUTH);
val _ = export_theory();
SML

cat > "$shimdir/dep-shim.toml" <<'TOML'
[project]
name = "dep"

[build]
members = ["src"]

[dependencies.nested]
manifest = "$HOLBUILD_TEST_SHIMDIR/nested-shim.toml"
TOML
cat > "$shimdir/nested-shim.toml" <<'TOML'
[project]
name = "nested"

[build]
members = ["src"]
TOML

cat > "$project/holproject.toml" <<'TOML'
[project]
name = "consumer"

[build]
members = ["src"]

[dependencies.dep]
manifest = "${HOLBUILD_TEST_SHIMDIR}/dep-shim.toml"
TOML
cat > "$project/.holconfig.toml" <<'TOML'
[overrides.dep]
path = "$HOLBUILD_TEST_DEP"

[overrides.nested]
path = "${HOLBUILD_TEST_NESTED}"
TOML
export HOLBUILD_TEST_SHIMDIR="$shimdir"
export HOLBUILD_TEST_DEP="$dep"
export HOLBUILD_TEST_NESTED="$nested"
cat > "$project/src/BScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
open ATheory CTheory;
val _ = new_theory "B";
val b_thm = store_thm("b_thm", ``T``, ACCEPT_TAC ATheory.a_thm);
val c_thm = store_thm("c_thm", ``T``, ACCEPT_TAC CTheory.c_thm);
val _ = export_theory();
SML

(cd "$project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" build BTheory)

require_file "$project/.holbuild/deps/dep/gen/src/ATheory.sig"
require_file "$project/.holbuild/deps/dep/gen/src/ATheory.sml"
require_file "$project/.holbuild/deps/dep/obj/src/ATheory.dat"
# checkpoints persist after successful builds for incremental rebuilds
require_file "$project/.holbuild/gen/src/BTheory.sig"
require_file "$project/.holbuild/gen/src/BTheory.sml"
require_file "$project/.holbuild/obj/src/BTheory.dat"

second_log=$tmpdir/second.log
(cd "$project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" build BTheory) > "$second_log"
require_grep "ATheory is up to date" "$second_log"
require_grep "BTheory is up to date" "$second_log"
