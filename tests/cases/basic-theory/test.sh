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
name = "basic"

[build]
members = ["src"]
TOML
cat > "$project/src/AScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;

val _ = new_theory "A";

val a_thm = store_thm("a_thm", ``T``, ACCEPT_TAC TRUTH);

val _ = export_theory();
SML

(cd "$project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" build ATheory)

require_file "$project/.hol/gen/src/ATheory.sig"
require_file "$project/.hol/gen/src/ATheory.sml"
require_file "$project/.hol/obj/src/ATheory.dat"
require_file "$project/.hol/checkpoints/basic/src/AScript.sml.deps_loaded.save"
require_file "$project/.hol/checkpoints/basic/src/AScript.sml.final_context.save"
require_file "$project/.hol/dep/basic/src/AScript.sml.key"

second_log=$tmpdir/second.log
(cd "$project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" build ATheory) > "$second_log"
require_grep "ATheory is up to date" "$second_log"

rm -rf "$project/.hol"
cache_log=$tmpdir/cache-restore.log
(cd "$project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" build ATheory) > "$cache_log"
require_grep "ATheory restored from cache" "$cache_log"
require_file "$project/.hol/gen/src/ATheory.sig"
require_file "$project/.hol/gen/src/ATheory.sml"
require_file "$project/.hol/obj/src/ATheory.dat"
require_file "$project/.hol/checkpoints/basic/src/AScript.sml.deps_loaded.save"
require_file "$project/.hol/checkpoints/basic/src/AScript.sml.final_context.save"
