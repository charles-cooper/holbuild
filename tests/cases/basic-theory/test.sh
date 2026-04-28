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

require_file "$project/.holbuild/gen/src/ATheory.sig"
require_file "$project/.holbuild/gen/src/ATheory.sml"
require_file "$project/.holbuild/obj/src/ATheory.dat"
require_file "$project/.holbuild/checkpoints/basic/src/AScript.sml.deps_loaded.save"
require_file "$project/.holbuild/checkpoints/basic/src/AScript.sml.final_context.save"
require_file "$project/.holbuild/dep/basic/src/AScript.sml.key"
base_count=$(find "$project/.holbuild/checkpoints/_base" -name '*.save' | wc -l)
if [[ "$base_count" -lt 1 ]]; then
  echo "missing project base checkpoint" >&2
  exit 1
fi

second_log=$tmpdir/second.log
(cd "$project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" build ATheory) > "$second_log"
require_grep "ATheory is up to date" "$second_log"

rm -rf "$project/.holbuild"
cache_log=$tmpdir/cache-restore.log
(cd "$project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" build ATheory) > "$cache_log"
require_grep "ATheory restored from cache" "$cache_log"
require_file "$project/.holbuild/gen/src/ATheory.sig"
require_file "$project/.holbuild/gen/src/ATheory.sml"
require_file "$project/.holbuild/obj/src/ATheory.dat"
require_file "$project/.holbuild/checkpoints/basic/src/AScript.sml.deps_loaded.save"
require_file "$project/.holbuild/checkpoints/basic/src/AScript.sml.final_context.save"
base_count=$(find "$project/.holbuild/checkpoints/_base" -name '*.save' | wc -l)
if [[ "$base_count" -lt 1 ]]; then
  echo "missing restored project base checkpoint" >&2
  exit 1
fi
