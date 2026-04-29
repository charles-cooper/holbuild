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

first_log=$tmpdir/first.log
(cd "$project" && \
  HOLBUILD_CHECKPOINT_TIMING=1 HOLBUILD_SHARE_COMMON_DATA=0 \
  "$HOLBUILD_BIN" --holdir "$HOLDIR" build ATheory) > "$first_log" 2>&1
require_grep "holbuild checkpoint kind=base share=false" "$first_log"
require_grep "holbuild checkpoint kind=deps_loaded share=false" "$first_log"
require_grep "holbuild checkpoint kind=final_context share=false" "$first_log"

require_file "$project/.holbuild/gen/src/ATheory.sig"
require_file "$project/.holbuild/gen/src/ATheory.sml"
require_file "$project/.holbuild/obj/src/ATheory.dat"
require_file "$project/.holbuild/checkpoints/basic/src/AScript.sml.deps_loaded.save"
require_file "$project/.holbuild/checkpoints/basic/src/AScript.sml.deps_loaded.save.ok"
require_file "$project/.holbuild/checkpoints/basic/src/AScript.sml.final_context.save"
require_file "$project/.holbuild/checkpoints/basic/src/AScript.sml.final_context.save.ok"
require_file "$project/.holbuild/dep/basic/src/AScript.sml.key"
base_count=$(find "$project/.holbuild/checkpoints/_base" -name '*.save' | wc -l)
base_ok_count=$(find "$project/.holbuild/checkpoints/_base" -name '*.save.ok' | wc -l)
if [[ "$base_count" -lt 1 || "$base_ok_count" -lt 1 ]]; then
  echo "missing project base checkpoint" >&2
  exit 1
fi

second_log=$tmpdir/second.log
(cd "$project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" build ATheory) > "$second_log"
require_grep "ATheory is up to date" "$second_log"

rm "$project/.holbuild/checkpoints/basic/src/AScript.sml.deps_loaded.save.ok"
missing_ok_log=$tmpdir/missing-ok.log
(cd "$project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" build ATheory) > "$missing_ok_log"
if grep -q "ATheory is up to date" "$missing_ok_log"; then
  echo "checkpoint without .ok marker was treated as up to date" >&2
  exit 1
fi
require_file "$project/.holbuild/checkpoints/basic/src/AScript.sml.deps_loaded.save.ok"

rm -rf "$project/.holbuild"
cache_log=$tmpdir/cache-restore.log
(cd "$project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" build ATheory) > "$cache_log"
require_grep "ATheory restored from cache" "$cache_log"
require_file "$project/.holbuild/gen/src/ATheory.sig"
require_file "$project/.holbuild/gen/src/ATheory.sml"
require_file "$project/.holbuild/obj/src/ATheory.dat"
require_file "$project/.holbuild/checkpoints/basic/src/AScript.sml.deps_loaded.save"
require_file "$project/.holbuild/checkpoints/basic/src/AScript.sml.deps_loaded.save.ok"
require_file "$project/.holbuild/checkpoints/basic/src/AScript.sml.final_context.save"
require_file "$project/.holbuild/checkpoints/basic/src/AScript.sml.final_context.save.ok"
base_count=$(find "$project/.holbuild/checkpoints/_base" -name '*.save' | wc -l)
base_ok_count=$(find "$project/.holbuild/checkpoints/_base" -name '*.save.ok' | wc -l)
if [[ "$base_count" -lt 1 || "$base_ok_count" -lt 1 ]]; then
  echo "missing restored project base checkpoint" >&2
  exit 1
fi
