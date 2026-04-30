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
cat > "$project/src/ATheory.sml" <<'SML'
this source-tree generated theory artifact must be ignored by discovery
SML
cat > "$project/src/ATheory.sig" <<'SML'
this source-tree generated theory artifact must be ignored by discovery
SML

first_log=$tmpdir/first.log
(cd "$project" && \
  HOLBUILD_CHECKPOINT_TIMING=1 HOLBUILD_SHARE_COMMON_DATA=0 HOLBUILD_ECHO_CHILD_LOGS=1 \
  "$HOLBUILD_BIN" --holdir "$HOLDIR" build ATheory) > "$first_log" 2>&1
require_grep "holbuild checkpoint kind=deps_loaded share=false" "$first_log"
require_grep "holbuild checkpoint kind=final_context share=false" "$first_log"

require_file "$project/.holbuild/gen/src/ATheory.sig"
require_file "$project/.holbuild/gen/src/ATheory.sml"
require_file "$project/.holbuild/obj/src/ATheory.dat"
require_file "$project/.holbuild/dep/basic/src/AScript.sml.key"
if find "$project/.holbuild/checkpoints" \( -name '*.save' -o -name '*.save.ok' \) -print -quit 2>/dev/null | grep -q .; then
  echo "successful build retained checkpoint files" >&2
  exit 1
fi
if grep -q "deps_loaded=\|final_context=\|theorem_boundary" "$project/.holbuild/dep/basic/src/AScript.sml.key"; then
  echo "metadata should not retain checkpoint paths" >&2
  exit 1
fi

second_log=$tmpdir/second.log
(cd "$project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" build ATheory) > "$second_log"
require_grep "ATheory is up to date" "$second_log"

metadata="$project/.holbuild/dep/basic/src/AScript.sml.key"
require_grep "^output-sha1=" "$metadata"
sed -i 's/^output-sha1=.*/output-sha1=stale-diagnostic-hash/' "$metadata"
stale_hash_log=$tmpdir/stale-output-hash.log
(cd "$project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" build ATheory) > "$stale_hash_log"
require_grep "ATheory is up to date" "$stale_hash_log"

rm -rf "$project/.holbuild"
cache_log=$tmpdir/cache-restore.log
(cd "$project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" build ATheory) > "$cache_log"
require_grep "ATheory restored from cache" "$cache_log"
require_file "$project/.holbuild/gen/src/ATheory.sig"
require_file "$project/.holbuild/gen/src/ATheory.sml"
require_file "$project/.holbuild/obj/src/ATheory.dat"
if find "$project/.holbuild/checkpoints" \( -name '*.save' -o -name '*.save.ok' \) -print -quit 2>/dev/null | grep -q .; then
  echo "cache restore retained checkpoint files" >&2
  exit 1
fi

skip_project=$tmpdir/skip-project
mkdir -p "$skip_project/src"
cp "$project/holproject.toml" "$skip_project/holproject.toml"
cp "$project/src/AScript.sml" "$skip_project/src/AScript.sml"
skip_log=$tmpdir/skip.log
(cd "$skip_project" && \
  HOLBUILD_CHECKPOINT_TIMING=1 HOLBUILD_ECHO_CHILD_LOGS=1 "$HOLBUILD_BIN" --holdir "$HOLDIR" build --skip-checkpoints ATheory) \
  > "$skip_log" 2>&1
if grep -q "holbuild checkpoint kind=deps_loaded\|holbuild checkpoint kind=final_context" "$skip_log"; then
  echo "--skip-checkpoints created theory checkpoints" >&2
  exit 1
fi
require_file "$skip_project/.holbuild/gen/src/ATheory.sig"
require_file "$skip_project/.holbuild/gen/src/ATheory.sml"
require_file "$skip_project/.holbuild/obj/src/ATheory.dat"
if find "$skip_project/.holbuild/checkpoints" \( -name '*.save' -o -name '*.save.ok' \) -print -quit 2>/dev/null | grep -q .; then
  echo "--skip-checkpoints left checkpoint files" >&2
  exit 1
fi

bad_flags_log=$tmpdir/bad-flags.log
if (cd "$project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" build --skip-goalfrag --tactic-timeout 0 ATheory) > "$bad_flags_log" 2>&1; then
  echo "--skip-goalfrag --tactic-timeout should fail" >&2
  exit 1
fi
require_grep "requires goalfrag" "$bad_flags_log"
