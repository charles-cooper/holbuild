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
metadata="$project/.holbuild/dep/checkpointrecovery/src/AScript.sml.key"
mkdir -p "$project/src"
cat > "$project/holproject.toml" <<'TOML'
[project]
name = "checkpointrecovery"

[build]
members = ["src"]

[actions.ATheory]
cache = false
TOML

write_good_source() {
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
}

write_bad_suffix_source() {
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
}

write_changed_prefix_source() {
  cat > "$project/src/AScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
val _ = new_theory "A";

(* prefix edit changes the theorem context key *)
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
}

write_non_goal_failure_source() {
  cat > "$project/src/AScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
val _ = new_theory "A";

Theorem first:
  T
Proof
  ACCEPT_TAC TRUTH
QED

val _ = print "HOL message: expected non-goal failure\n";
val _ = raise Fail "expected non-goal failure";
SML
}

write_non_goal_failure_after_first_source() {
  cat > "$project/src/AScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
val _ = new_theory "A";

Theorem first:
  T
Proof
  ACCEPT_TAC TRUTH
QED

val _ = print "HOL message: expected non-goal failure after first\n";
val _ = raise Fail "expected non-goal failure after first";
SML
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

force_rebuild() {
  rm -f "$metadata"
}

first_context_path() {
  find "$project/.holbuild/checkpoints/checkpointrecovery/src/AScript.sml.theorems" \
    -path '*/first_context.save' -print -quit
}

first_deps_path() {
  find "$project/.holbuild/checkpoints/checkpointrecovery/src/AScript.sml.deps" \
    -path '*/deps_loaded.save' -print -quit
}

second_failed_prefix_path() {
  find "$project/.holbuild/checkpoints/checkpointrecovery/src/AScript.sml.theorems" \
    -path '*second_failed_prefix.save' -print -quit
}

run_expect_suffix_failure() {
  local log=$1
  write_bad_suffix_source
  if (cd "$project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" build ATheory) > "$log" 2>&1; then
    echo "expected second theorem failure" >&2
    exit 1
  fi
  require_grep "expected dirty residue" "$log"
  deps_loaded_path=$(first_deps_path)
  context_path=$(first_context_path)
  if [[ -z "$deps_loaded_path" || ! -e "$deps_loaded_path.ok" ]]; then
    echo "failed action did not retain deps_loaded checkpoint breadcrumb" >&2
    exit 1
  fi
  if [[ -z "$context_path" || ! -e "$context_path.ok" ]]; then
    echo "failed action did not retain reusable first theorem context" >&2
    exit 1
  fi
  require_grep '^holbuild-checkpoint-ok-v2$' "$deps_loaded_path.ok"
  require_grep '^kind=deps_loaded$' "$deps_loaded_path.ok"
  require_grep '^holbuild-checkpoint-ok-v2$' "$context_path.ok"
  require_grep '^kind=theorem_context$' "$context_path.ok"
}

write_good_source
(cd "$project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" build ATheory) > "$tmpdir/initial.log" 2>&1
require_file "$project/.holbuild/obj/src/ATheory.dat"
assert_no_checkpoints "successful initial build retained checkpoint files"

run_expect_suffix_failure "$tmpdir/failed.log"
write_good_source
force_rebuild
fixed_log=$tmpdir/fixed.log
(cd "$project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" build ATheory) > "$fixed_log" 2>&1
require_grep "from: failed-prefix checkpoint in second" "$fixed_log"
if grep -q "parent for this saved state\|goalfrag/checkpoint run failed" "$fixed_log"; then
  echo "suffix recovery hit checkpoint parent mismatch/instrumentation failure" >&2
  exit 1
fi
require_file "$project/.holbuild/obj/src/ATheory.dat"
assert_no_checkpoints "successful fixed build retained checkpoint files"

run_expect_suffix_failure "$tmpdir/missing-ok-seed.log"
missing_context=$(first_context_path)
missing_failed_prefix=$(second_failed_prefix_path)
rm -f "$missing_context.ok" "$missing_failed_prefix" "$missing_failed_prefix.ok" "$missing_failed_prefix.meta" "$missing_failed_prefix.prefix"
write_good_source
force_rebuild
missing_ok_log=$tmpdir/missing-ok.log
(cd "$project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" build ATheory) > "$missing_ok_log" 2>&1
require_grep "from: deps-loaded checkpoint" "$missing_ok_log"
if grep -q "from: theorem-context checkpoint after first" "$missing_ok_log"; then
  echo "missing checkpoint .ok was treated as replayable" >&2
  exit 1
fi
assert_no_checkpoints "missing-checkpoint rebuild retained checkpoint files"

run_expect_suffix_failure "$tmpdir/missing-save-seed.log"
missing_save_context=$(first_context_path)
missing_save_failed_prefix=$(second_failed_prefix_path)
rm -f "$missing_save_context" "$missing_save_failed_prefix" "$missing_save_failed_prefix.ok" "$missing_save_failed_prefix.meta" "$missing_save_failed_prefix.prefix"
write_good_source
force_rebuild
missing_save_log=$tmpdir/missing-save.log
(cd "$project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" build ATheory) > "$missing_save_log" 2>&1
require_grep "checkpoint metadata exists without checkpoint file; discarding metadata:" "$missing_save_log"
require_grep "from: deps-loaded checkpoint" "$missing_save_log"
if grep -q "from: theorem-context checkpoint after first\|selected HOL base-state checkpoint is missing\|Couldn't load HOL base-state\|instrumented log:" "$missing_save_log"; then
  echo "orphan checkpoint .ok/.save mismatch was treated as replayable" >&2
  exit 1
fi
assert_no_checkpoints "clean rebuild after orphan checkpoint metadata retained checkpoint files"

run_expect_suffix_failure "$tmpdir/missing-failed-prefix-seed.log"
missing_failed_prefix_save=$(second_failed_prefix_path)
rm -f "$missing_failed_prefix_save"
write_good_source
force_rebuild
missing_failed_prefix_log=$tmpdir/missing-failed-prefix.log
(cd "$project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" build ATheory) > "$missing_failed_prefix_log" 2>&1
require_grep "from: theorem-context checkpoint after first" "$missing_failed_prefix_log"
if grep -q "from: failed-prefix checkpoint\|selected HOL base-state checkpoint is missing\|Couldn't load HOL base-state\|instrumented log:" "$missing_failed_prefix_log"; then
  echo "missing failed-prefix .save was treated as replayable" >&2
  exit 1
fi
assert_no_checkpoints "clean rebuild after missing failed-prefix save retained checkpoint files"

run_expect_suffix_failure "$tmpdir/fresh-deps-seed.log"
fresh_deps=$(first_deps_path)
fresh_context=$(first_context_path)
fresh_failed_prefix=$(second_failed_prefix_path)
stale_descendant="$(dirname "$(dirname "$fresh_context")")/stale_prefix/stale_context.save"
mkdir -p "$(dirname "$stale_descendant")"
printf 'stale child checkpoint\n' > "$stale_descendant"
printf 'holbuild-checkpoint-ok-v2\nkind=theorem_context\n' > "$stale_descendant.ok"
rm -f "$fresh_deps" "$fresh_deps.ok" "$fresh_deps.meta" "$fresh_deps.prefix" "$fresh_failed_prefix" "$fresh_failed_prefix.ok" "$fresh_failed_prefix.meta" "$fresh_failed_prefix.prefix"
force_rebuild
fresh_deps_log=$tmpdir/fresh-deps-rebuild-failure.log
if (cd "$project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" build ATheory) > "$fresh_deps_log" 2>&1; then
  echo "expected fresh deps rebuild to preserve suffix failure" >&2
  exit 1
fi
require_grep "expected dirty residue" "$fresh_deps_log"
if [[ -e "$stale_descendant" || -e "$stale_descendant.ok" ]]; then
  echo "fresh deps checkpoint rewrite left stale theorem descendants" >&2
  exit 1
fi
rm -rf "$project/.holbuild/checkpoints"

run_expect_suffix_failure "$tmpdir/backup-seed.log"
backup_context=$(first_context_path)
backup_failed_prefix=$(second_failed_prefix_path)
rm -f "$backup_failed_prefix" "$backup_failed_prefix.ok" "$backup_failed_prefix.meta" "$backup_failed_prefix.prefix"
mv "$backup_context.ok" "$backup_context.ok.bak"
mv "$backup_context" "$backup_context.bak"
printf 'partial interrupted checkpoint\n' > "$backup_context"
write_good_source
force_rebuild
backup_log=$tmpdir/backup-restore.log
(cd "$project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" build ATheory) > "$backup_log" 2>&1
require_grep "checkpoint save was interrupted; restoring previous checkpoint:" "$backup_log"
require_grep "from: theorem-context checkpoint after first" "$backup_log"
assert_no_checkpoints "clean rebuild after restored checkpoint backup retained checkpoint files"

run_expect_suffix_failure "$tmpdir/partial-ok-seed.log"
partial_ok_context=$(first_context_path)
partial_ok_failed_prefix=$(second_failed_prefix_path)
rm -f "$partial_ok_failed_prefix" "$partial_ok_failed_prefix.ok" "$partial_ok_failed_prefix.meta" "$partial_ok_failed_prefix.prefix"
mv "$partial_ok_context.ok" "$partial_ok_context.ok.bak"
mv "$partial_ok_context" "$partial_ok_context.bak"
printf 'partial replacement checkpoint\n' > "$partial_ok_context"
printf 'holbuild-checkpoint-ok-v2\nkind=theorem_context\n' > "$partial_ok_context.ok"
write_good_source
force_rebuild
partial_ok_log=$tmpdir/partial-ok-restore.log
(cd "$project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" build ATheory) > "$partial_ok_log" 2>&1
require_grep "checkpoint metadata publish was interrupted; restoring previous checkpoint:" "$partial_ok_log"
require_grep "from: theorem-context checkpoint after first" "$partial_ok_log"
assert_no_checkpoints "clean rebuild after restored partial-ok checkpoint retained checkpoint files"

run_expect_suffix_failure "$tmpdir/parent-mismatch-seed.log"
parent_mismatch_deps=$(first_deps_path)
parent_mismatch_failed_prefix=$(second_failed_prefix_path)
rm -f "$parent_mismatch_failed_prefix" "$parent_mismatch_failed_prefix.ok" "$parent_mismatch_failed_prefix.meta" "$parent_mismatch_failed_prefix.prefix"
cp "$HOLDIR/bin/hol.state" "$parent_mismatch_deps"
write_good_source
force_rebuild
parent_mismatch_log=$tmpdir/parent-mismatch.log
(cd "$project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" build ATheory) > "$parent_mismatch_log" 2>&1
require_grep "discarding invalid checkpoint after HOL state load failure" "$parent_mismatch_log"
if grep -q "Couldn't load HOL base-state\|parent for this saved state" "$parent_mismatch_log"; then
  echo "checkpoint parent mismatch leaked as a build failure" >&2
  exit 1
fi
require_file "$project/.holbuild/obj/src/ATheory.dat"
assert_no_checkpoints "clean rebuild after invalid parent checkpoint retained checkpoint files"

run_expect_suffix_failure "$tmpdir/corrupt-seed.log"
corrupt_context=$(first_context_path)
corrupt_failed_prefix=$(second_failed_prefix_path)
rm -f "$corrupt_failed_prefix" "$corrupt_failed_prefix.ok" "$corrupt_failed_prefix.meta" "$corrupt_failed_prefix.prefix"
printf 'not a valid PolyML checkpoint\n' > "$corrupt_context"
write_good_source
force_rebuild
corrupt_log=$tmpdir/corrupt.log
(cd "$project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" build ATheory) > "$corrupt_log" 2>&1
require_grep "from: theorem-context checkpoint after first" "$corrupt_log"
require_grep "discarding invalid checkpoint after HOL state load failure" "$corrupt_log"
if grep -q "Couldn't load HOL base-state\|Unable to load header" "$corrupt_log"; then
  echo "corrupt checkpoint load failure leaked as a build failure" >&2
  exit 1
fi
require_file "$project/.holbuild/obj/src/ATheory.dat"
assert_no_checkpoints "clean rebuild after corrupt checkpoint retained checkpoint files"

run_expect_suffix_failure "$tmpdir/corrupt-deps-seed.log"
corrupt_deps=$(first_deps_path)
corrupt_context=$(first_context_path)
corrupt_failed_prefix=$(second_failed_prefix_path)
rm -f "$corrupt_context" "$corrupt_context.ok" "$corrupt_failed_prefix" "$corrupt_failed_prefix.ok" "$corrupt_failed_prefix.meta" "$corrupt_failed_prefix.prefix"
printf 'not a valid PolyML deps checkpoint\n' > "$corrupt_deps"
write_good_source
force_rebuild
corrupt_deps_log=$tmpdir/corrupt-deps.log
(cd "$project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" build ATheory) > "$corrupt_deps_log" 2>&1
require_grep "from: deps-loaded checkpoint" "$corrupt_deps_log"
require_grep "discarding invalid checkpoint after HOL state load failure" "$corrupt_deps_log"
if grep -q "Couldn't load HOL base-state\|Unable to load header" "$corrupt_deps_log"; then
  echo "corrupt deps checkpoint load failure leaked as a build failure" >&2
  exit 1
fi
require_file "$project/.holbuild/obj/src/ATheory.dat"
assert_no_checkpoints "clean rebuild after corrupt deps checkpoint retained checkpoint files"

run_expect_suffix_failure "$tmpdir/non-goal-replay-seed.log"
non_goal_replay_deps=$(first_deps_path)
write_non_goal_failure_after_first_source
force_rebuild
non_goal_replay_log=$tmpdir/non-goal-replay.log
if (cd "$project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" build ATheory) > "$non_goal_replay_log" 2>&1; then
  echo "expected non-goal child failure after replay" >&2
  exit 1
fi
require_grep "from: theorem-context checkpoint after first" "$non_goal_replay_log"
require_grep "HOL message: expected non-goal failure after first" "$non_goal_replay_log"
if [[ -e "$non_goal_replay_deps" || -e "$non_goal_replay_deps.ok" ]]; then
  echo "non-goal replay failure left deps parent after discard" >&2
  exit 1
fi
if find "$project/.holbuild/checkpoints/checkpointrecovery/src/AScript.sml.theorems" -type f -print -quit 2>/dev/null | grep -q .; then
  echo "non-goal replay failure deleted deps parent but left theorem descendants" >&2
  exit 1
fi
rm -rf "$project/.holbuild/checkpoints"

run_expect_suffix_failure "$tmpdir/prefix-seed.log"
write_changed_prefix_source
force_rebuild
prefix_log=$tmpdir/prefix-change.log
(cd "$project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" build ATheory) > "$prefix_log" 2>&1
if grep -q "from: theorem-context checkpoint after first" "$prefix_log"; then
  echo "prefix-changing edit reused stale theorem checkpoint" >&2
  exit 1
fi
assert_no_checkpoints "prefix-changing rebuild retained checkpoint files"

mkdir -p "$project/.holbuild/checkpoints/checkpointrecovery/src/stale"
printf 'stale residue\n' > "$project/.holbuild/checkpoints/checkpointrecovery/src/stale/manual.save"
printf 'holbuild-checkpoint-ok-v2\nkind=manual\n' > "$project/.holbuild/checkpoints/checkpointrecovery/src/stale/manual.save.ok"
residue_before_up_to_date=$(checkpoint_count)
up_to_date_log=$tmpdir/up-to-date.log
(cd "$project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" build ATheory) > "$up_to_date_log" 2>&1
require_grep "ATheory is up to date" "$up_to_date_log"
residue_after_up_to_date=$(checkpoint_count)
[[ "$residue_before_up_to_date" == "$residue_after_up_to_date" ]] || {
  echo "up-to-date check should not eagerly scan/clean checkpoint residue" >&2
  exit 1
}

rm -rf "$project/.holbuild"
write_non_goal_failure_source
non_goal_failure_log=$tmpdir/non-goal-failure.log
if (cd "$project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" build ATheory) > "$non_goal_failure_log" 2>&1; then
  echo "expected non-goal child failure" >&2
  exit 1
fi
require_grep "child failure:" "$non_goal_failure_log"
require_grep "HOL message: expected non-goal failure" "$non_goal_failure_log"
if grep -q -- "--- child log tail ---" "$non_goal_failure_log"; then
  echo "non-goal failure duplicated full child log tail" >&2
  exit 1
fi
