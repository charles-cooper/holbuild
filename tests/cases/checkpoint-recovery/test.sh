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
name = "checkpointrecovery"

[build]
members = ["src"]

[actions.ATheory]
cache = false
TOML
cat > "$project/src/AScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
val _ = new_theory "A";

Theorem first:
  T
Proof
  ACCEPT_TAC TRUTH
QED

Theorem second:
  T
Proof
  ACCEPT_TAC first
QED

val _ = export_theory();
SML

metadata="$project/.holbuild/dep/checkpointrecovery/src/AScript.sml.key"
context_path="$project/.holbuild/checkpoints/checkpointrecovery/src/AScript.sml.first_context.save"
end_path="$project/.holbuild/checkpoints/checkpointrecovery/src/AScript.sml.first_end_of_proof.save"

prefix_hash() {
  python3 - <<PY
from pathlib import Path
src = Path("$project/src/AScript.sml").read_text()
end = src.index("QED") + len("QED")
Path("$tmpdir/prefix").write_text(src[:end])
PY
  sha1sum "$tmpdir/prefix" | awk '{print $1}'
}

seed_old_boundary_metadata() {
  require_file "$metadata"
  printf 'theorem_boundary first %s %s %s\n' "$(prefix_hash)" "$context_path" "$end_path" >> "$metadata"
}

assert_no_checkpoints() {
  if find "$project/.holbuild/checkpoints" \( -name '*.save' -o -name '*.save.ok' \) -print -quit 2>/dev/null | grep -q .; then
    echo "$1" >&2
    exit 1
  fi
}

checkpoint_count() {
  find "$project/.holbuild/checkpoints" \( -name '*.save' -o -name '*.save.ok' \) -print 2>/dev/null | wc -l
}

(cd "$project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" build ATheory) > "$tmpdir/initial.log" 2>&1
require_file "$project/.holbuild/obj/src/ATheory.dat"
assert_no_checkpoints "successful initial build retained checkpoint files"

seed_old_boundary_metadata
missing_ok_log=$tmpdir/missing-ok.log
(cd "$project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" build ATheory) > "$missing_ok_log" 2>&1
if grep -q "replaying from checkpoint\|checkpoint instrumentation failed" "$missing_ok_log"; then
  echo "missing checkpoint .ok was treated as replayable" >&2
  exit 1
fi
assert_no_checkpoints "missing-checkpoint rebuild retained checkpoint files"

seed_old_boundary_metadata
mkdir -p "$(dirname "$context_path")"
printf 'not a valid PolyML checkpoint\n' > "$context_path"
printf 'holbuild-checkpoint-ok-v1\n' > "$context_path.ok"
corrupt_log=$tmpdir/corrupt.log
(cd "$project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" build ATheory) > "$corrupt_log" 2>&1
require_grep "ATheory replaying from checkpoint first" "$corrupt_log"
require_grep "checkpoint instrumentation failed; retrying without theorem checkpoints" "$corrupt_log"
require_file "$project/.holbuild/obj/src/ATheory.dat"
assert_no_checkpoints "corrupt-checkpoint recovery retained checkpoint files"

cat > "$project/src/AScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
val _ = new_theory "A";

Theorem first:
  T
Proof
  ACCEPT_TAC TRUTH
QED

Theorem second:
  T
Proof
  FAIL_TAC "expected dirty residue"
QED

val _ = export_theory();
SML
failed_log=$tmpdir/failed.log
if (cd "$project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" build ATheory) > "$failed_log" 2>&1; then
  echo "expected second theorem failure" >&2
  exit 1
fi
require_grep "expected dirty residue" "$failed_log"
deps_loaded_path="$project/.holbuild/checkpoints/checkpointrecovery/src/AScript.sml.deps_loaded.save"
if [[ ! -e "$deps_loaded_path" || ! -e "$deps_loaded_path.ok" ]]; then
  echo "failed action did not retain deps_loaded checkpoint breadcrumb" >&2
  exit 1
fi
if find "$project/.holbuild/checkpoints/checkpointrecovery/src" \
    \( -name 'AScript.sml.*_context.save' -o -name 'AScript.sml.*_context.save.ok' -o \
       -name 'AScript.sml.*_end_of_proof.save' -o -name 'AScript.sml.*_end_of_proof.save.ok' \) \
    -print -quit 2>/dev/null | grep -q .; then
  echo "failed theorem fallback retained stale theorem checkpoints" >&2
  exit 1
fi

cat > "$project/src/AScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
val _ = new_theory "A";

Theorem first:
  T
Proof
  ACCEPT_TAC TRUTH
QED

Theorem second:
  T
Proof
  ACCEPT_TAC first
QED

val _ = export_theory();
SML
fixed_log=$tmpdir/fixed.log
(cd "$project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" build ATheory) > "$fixed_log" 2>&1
require_file "$project/.holbuild/obj/src/ATheory.dat"
if grep -q "checkpoint instrumentation failed" "$fixed_log"; then
  echo "fixed source reused dirty checkpoint residue" >&2
  exit 1
fi

residue_before_up_to_date=$(checkpoint_count)
up_to_date_log=$tmpdir/up-to-date.log
(cd "$project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" build ATheory) > "$up_to_date_log" 2>&1
require_grep "ATheory is up to date" "$up_to_date_log"
residue_after_up_to_date=$(checkpoint_count)
[[ "$residue_before_up_to_date" == "$residue_after_up_to_date" ]] || {
  echo "up-to-date check should not eagerly scan/clean checkpoint residue" >&2
  exit 1
}
