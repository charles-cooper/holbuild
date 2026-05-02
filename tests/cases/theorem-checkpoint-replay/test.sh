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
name = "replay"

[build]
members = ["src"]
TOML
cat > "$project/src/AScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;

val _ = new_theory "A";

Theorem simple_thm = TRUTH;

Theorem a_thm:
  T
Proof
  ACCEPT_TAC TRUTH
QED

Theorem b_thm:
  T /\ T
Proof
  CONJ_TAC >- ACCEPT_TAC TRUTH >- ACCEPT_TAC TRUTH
QED

Theorem c_thm:
  T
Proof[exclude_simps = bool_case_thm]
  ACCEPT_TAC TRUTH
QED

val prove_subgoal_tac =
  fn g => (ignore (Tactical.prove (``T``, ACCEPT_TAC TRUTH)); ALL_TAC g);

Theorem reentrant_prover:
  T
Proof
  prove_subgoal_tac
  \\ ACCEPT_TAC TRUTH
QED

Theorem reverse_cases:
  !b. b = T \/ b = F
Proof
  gen_tac
  \\ reverse (Cases_on `b`)
  >- (DISJ2_TAC \\ REFL_TAC)
  \\ DISJ1_TAC
  \\ REFL_TAC
QED

Theorem generated_thenl:
  T /\ T
Proof
  CONJ_TAC THENL
  let
    fun tac () = ACCEPT_TAC TRUTH
  in
    [tac (), tac ()]
  end
QED

Theorem by_after_split:
  T /\ T
Proof
  CONJ_TAC
  \\ `T` by ACCEPT_TAC TRUTH
  \\ ACCEPT_TAC TRUTH
QED

Theorem suffices_after_split:
  F ==> (T /\ T)
Proof
  strip_tac
  \\ CONJ_TAC
  \\ `F` suffices_by simp[]
  \\ FIRST_ASSUM ACCEPT_TAC
QED

Theorem unicode_quote_by:
  T
Proof
  ‘T’ by ACCEPT_TAC TRUTH
  \\ ACCEPT_TAC TRUTH
QED

Theorem reverse_multi_goal_validation:
  (T /\ T) /\ T
Proof
  CONJ_TAC
  \\ Tactical.REVERSE (TRY CONJ_TAC) THENL
     [ACCEPT_TAC TRUTH, ACCEPT_TAC TRUTH, ACCEPT_TAC TRUTH]
QED

Theorem reverse_multi_goal_order:
  (T /\ (F ==> F)) /\ T
Proof
  CONJ_TAC
  \\ reverse (TRY CONJ_TAC) THENL
     [DISCH_TAC \\ FIRST_ASSUM ACCEPT_TAC,
      ACCEPT_TAC TRUTH,
      ACCEPT_TAC TRUTH]
QED

Theorem branch_body_all_subgoals:
  (T /\ T) /\ T
Proof
  CONJ_TAC
  >- (TRY CONJ_TAC >> ACCEPT_TAC TRUTH)
  \\ ACCEPT_TAC TRUTH
QED

Theorem induction_shared_suffix:
  ∀xs:'a list. xs = xs
Proof
  Induct_on `xs` >> simp[]
QED

val _ = export_theory();
SML

first_log=$tmpdir/first.log
(cd "$project" && \
  HOLBUILD_CHECKPOINT_TIMING=1 HOLBUILD_ECHO_CHILD_LOGS=1 "$HOLBUILD_BIN" --holdir "$HOLDIR" build ATheory) \
  > "$first_log" 2>&1
require_grep "holbuild checkpoint kind=deps_loaded" "$first_log"
require_grep "holbuild checkpoint kind=end_of_proof" "$first_log"
require_grep "holbuild checkpoint kind=theorem_context" "$first_log"
require_grep "holbuild checkpoint kind=final_context" "$first_log"
require_file "$project/.holbuild/gen/src/ATheory.sig"
require_file "$project/.holbuild/gen/src/ATheory.sml"
require_file "$project/.holbuild/obj/src/ATheory.dat"
require_grep "dependency_context_key=" "$project/.holbuild/dep/replay/src/AScript.sml.key"
if grep -q "theorem_boundary\|_end_of_proof.save\|deps_loaded=\|final_context=" "$project/.holbuild/dep/replay/src/AScript.sml.key"; then
  echo "successful metadata retained checkpoint paths" >&2
  exit 1
fi
if find "$project/.holbuild/checkpoints" \( -name '*.save' -o -name '*.save.ok' \) -print -quit 2>/dev/null | grep -q .; then
  echo "successful theorem build retained checkpoint files" >&2
  exit 1
fi

second_log=$tmpdir/second.log
(cd "$project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" build ATheory) > "$second_log"
require_grep "ATheory is up to date" "$second_log"

same_artifact_skip_goalfrag_log=$tmpdir/same-artifact-skip-goalfrag.log
(cd "$project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" build --skip-goalfrag ATheory) > "$same_artifact_skip_goalfrag_log"
require_grep "ATheory is up to date" "$same_artifact_skip_goalfrag_log"

trace_project=$tmpdir/trace-project
mkdir -p "$trace_project/src"
cp "$project/holproject.toml" "$trace_project/holproject.toml"
cp "$project/src/AScript.sml" "$trace_project/src/AScript.sml"
plan_log=$tmpdir/goalfrag-plan.log
(cd "$trace_project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" goalfrag-plan ATheory:b_thm) > "$plan_log" 2>&1
require_grep "holbuild goalfrag plan ATheory:b_thm source=src/AScript.sml (" "$plan_log"
require_grep "^[[:space:]]*00 .*CONJ_TAC" "$plan_log"
require_grep "^[[:space:]]*[0-9][0-9] .*ACCEPT_TAC TRUTH" "$plan_log"
if grep -q "holbuild goalfrag before theorem=b_thm\|elapsed_ms=\|ATheory built\|ATheory inspected\|resuming ATheory" "$plan_log"; then
  echo "--goalfrag-plan executed the build instead of statically printing the plan" >&2
  exit 1
fi
trace_log=$tmpdir/goalfrag-trace.log
(cd "$trace_project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" build --force --goalfrag-trace ATheory) > "$trace_log" 2>&1
require_grep "ATheory built" "$trace_log"
if grep -q "holbuild goalfrag plan theorem=\|holbuild goalfrag before theorem=" "$trace_log"; then
  echo "--goalfrag-trace should not dump successful proof traces to stdout" >&2
  exit 1
fi
require_grep "goalfrag trace log:" "$trace_log"
trace_child_log=$(find "$trace_project/.holbuild/logs" -name '*-ATheory-goalfrag-trace.log' -print -quit)
require_file "$trace_child_log"
require_grep "holbuild goalfrag plan theorem=a_thm steps=" "$trace_child_log"
require_grep "holbuild goalfrag plan theorem=b_thm steps=" "$trace_child_log"
require_grep "holbuild goalfrag before theorem=b_thm step=0" "$trace_child_log"
require_grep "holbuild goalfrag after theorem=b_thm step=0.*elapsed_ms=" "$trace_child_log"
force_log=$tmpdir/force.log
(cd "$trace_project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" build --force ATheory) > "$force_log" 2>&1
require_grep "ATheory built" "$force_log"
if grep -q "ATheory is up to date\|ATheory restored from cache" "$force_log"; then
  echo "--force skipped source rebuild" >&2
  exit 1
fi

skip_goalfrag_project=$tmpdir/skip-goalfrag-project
mkdir -p "$skip_goalfrag_project/src"
cp "$project/holproject.toml" "$skip_goalfrag_project/holproject.toml"
cp "$project/src/AScript.sml" "$skip_goalfrag_project/src/AScript.sml"
(cd "$skip_goalfrag_project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" build --skip-goalfrag ATheory)
require_file "$skip_goalfrag_project/.holbuild/gen/src/ATheory.sig"
require_file "$skip_goalfrag_project/.holbuild/gen/src/ATheory.sml"
require_file "$skip_goalfrag_project/.holbuild/obj/src/ATheory.dat"
if grep -q "theorem_boundary a_thm" "$skip_goalfrag_project/.holbuild/dep/replay/src/AScript.sml.key"; then
  echo "--skip-goalfrag should not create theorem boundaries" >&2
  exit 1
fi
if find "$skip_goalfrag_project/.holbuild/checkpoints" \( -name '*.save' -o -name '*.save.ok' \) -print -quit 2>/dev/null | grep -q .; then
  echo "--skip-goalfrag successful build retained checkpoints" >&2
  exit 1
fi

plain_replay_project=$tmpdir/plain-replay-project
mkdir -p "$plain_replay_project/src"
cp "$project/holproject.toml" "$plain_replay_project/holproject.toml"
cat > "$plain_replay_project/src/AScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
val _ = new_theory "A";
Theorem a_thm:
  T
Proof
  ACCEPT_TAC TRUTH
QED
Theorem b_thm:
  T
Proof
  FAIL_TAC "expected replay seed failure"
QED
val _ = export_theory();
SML
plain_replay_failure_log=$tmpdir/plain-replay-failure.log
if (cd "$plain_replay_project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" build ATheory) > "$plain_replay_failure_log" 2>&1; then
  echo "expected replay seed proof to fail" >&2
  exit 1
fi
require_file "$(find "$plain_replay_project/.holbuild/checkpoints" -name '*a_thm_context.save' -print -quit)"
python3 - <<PY
from pathlib import Path
path = Path("$plain_replay_project/src/AScript.sml")
path.write_text(path.read_text().replace('FAIL_TAC "expected replay seed failure"', 'ACCEPT_TAC TRUTH'))
PY
plain_replay_log=$tmpdir/plain-replay.log
(cd "$plain_replay_project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" build --skip-goalfrag --no-cache ATheory) > "$plain_replay_log" 2>&1
require_grep "resuming ATheory from checkpoint a_thm" "$plain_replay_log"
require_grep "ATheory built" "$plain_replay_log"

failure_project=$tmpdir/failure-project
mkdir -p "$failure_project/src"
cp "$project/holproject.toml" "$failure_project/holproject.toml"
python3 - <<PY
from pathlib import Path
src = Path("$project/src/AScript.sml").read_text()
long_goal = "p" * 5000
b_thm = "Theorem b_thm:\n  T /" + chr(92) + " T\nProof\n  CONJ_TAC >- ACCEPT_TAC TRUTH >- ACCEPT_TAC TRUTH\nQED"
src = src.replace(b_thm, f'''Theorem b_thm:
  {long_goal}
Proof
  FAIL_TAC "expected failure"
QED''')
Path("$failure_project/src/AScript.sml").write_text(src)
PY

failure_log=$tmpdir/failure.log
if (cd "$failure_project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" build ATheory) > "$failure_log" 2>&1; then
  echo "expected failing proof to fail build" >&2
  exit 1
fi
require_grep "expected failure" "$failure_log"
require_grep "holbuild top goal at failed fragment (first open goal, 4 KiB max)" "$failure_log"
require_grep "top goal exceeded 4 KiB" "$failure_log"
require_grep "full top goal is in the instrumented log above" "$failure_log"
require_grep "begin top goal" "$failure_log"
require_grep "end top goal" "$failure_log"
require_grep "holbuild failed fragment source context (best effort)" "$failure_log"
require_grep "FAIL_TAC \"expected failure\"" "$failure_log"
failure_child_log=$(find "$failure_project/.holbuild/logs" -name '*-ATheory-instrumented-failure.log' -print -quit)
require_file "$failure_child_log"
require_grep "holbuild goal state at failed fragment" "$failure_child_log"
require_grep "holbuild remaining goals: 1" "$failure_child_log"
require_grep "holbuild top goal:" "$failure_child_log"
require_grep "holbuild end top goal" "$failure_child_log"
a_thm_context=$(find "$failure_project/.holbuild/checkpoints" -name '*a_thm_context.save' -print -quit)
require_file "$a_thm_context"
b_thm_failed_prefix=$(find "$failure_project/.holbuild/checkpoints" -name '*b_thm_failed_prefix.save' -print -quit)
require_file "$b_thm_failed_prefix"
failure_again_log=$tmpdir/failure-again.log
if (cd "$failure_project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" build ATheory) > "$failure_again_log" 2>&1; then
  echo "expected repeated failing proof to fail build" >&2
  exit 1
fi
require_grep "resuming ATheory from checkpoint b_thm failed_prefix" "$failure_again_log"
require_grep "holbuild top goal at failed fragment" "$failure_again_log"
require_file "$a_thm_context"
require_file "$b_thm_failed_prefix"
failed_prefix_plan_log=$tmpdir/failed-prefix-plan.log
(cd "$failure_project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" build --goalfrag-plan ATheory:b_thm) > "$failed_prefix_plan_log" 2>&1
require_grep "holbuild goalfrag plan ATheory:b_thm source=src/AScript.sml (" "$failed_prefix_plan_log"
require_grep "FAIL_TAC \"expected failure\"" "$failed_prefix_plan_log"
if grep -q "resuming ATheory\|ATheory inspected\|holbuild top goal at failed fragment\|goalfrag/checkpoint run failed" "$failed_prefix_plan_log"; then
  echo "--goalfrag-plan executed/replayed the build instead of statically printing the plan" >&2
  exit 1
fi
python3 - <<PY
from pathlib import Path
path = Path("$failure_project/src/AScript.sml")
path.write_text(path.read_text().replace('FAIL_TAC "expected failure"', 'cheat'))
PY
failure_fixed_log=$tmpdir/failure-fixed.log
(cd "$failure_project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" build ATheory) > "$failure_fixed_log" 2>&1
require_grep "resuming ATheory from checkpoint b_thm failed_prefix" "$failure_fixed_log"
require_grep "ATheory built" "$failure_fixed_log"
if [[ -e "$failure_project/.holbuild/checkpoints/replay/src/AScript.sml.b_thm_context.save" || \
      -e "$failure_project/.holbuild/checkpoints/replay/src/AScript.sml.b_thm_context.save.ok" || \
      -e "$failure_project/.holbuild/checkpoints/replay/src/AScript.sml.b_thm_end_of_proof.save" || \
      -e "$failure_project/.holbuild/checkpoints/replay/src/AScript.sml.b_thm_end_of_proof.save.ok" ]]; then
  echo "stale b_thm checkpoint survived failed proof" >&2
  exit 1
fi

branch_failure_project=$tmpdir/branch-failure-project
mkdir -p "$branch_failure_project/src"
cp "$project/holproject.toml" "$branch_failure_project/holproject.toml"
cat > "$branch_failure_project/src/AScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
val _ = new_theory "A";
Theorem branch_failure:
  T /\ T
Proof
  CONJ_TAC >- FAIL_TAC "branch side failed"
  \\ ACCEPT_TAC TRUTH
QED
val _ = export_theory();
SML
branch_failure_log=$tmpdir/branch-failure.log
if (cd "$branch_failure_project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" build --goalfrag-trace ATheory) > "$branch_failure_log" 2>&1; then
  echo "expected branch proof to fail build" >&2
  exit 1
fi
require_grep "holbuild goalfrag trace:" "$branch_failure_log"
require_grep "holbuild goalfrag after theorem=branch_failure.*status=failed.*elapsed_ms=" "$branch_failure_log"
require_grep "fragment: FAIL_TAC" "$branch_failure_log"
require_grep "branch side failed" "$branch_failure_log"
if grep -q "fragment: CONJ_TAC >- FAIL_TAC" "$branch_failure_log"; then
  echo "branch tactical was emitted as one atomic fragment" >&2
  exit 1
fi

timeout_project=$tmpdir/timeout-project
mkdir -p "$timeout_project/src"
cp "$project/holproject.toml" "$timeout_project/holproject.toml"
cat > "$timeout_project/src/AScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
val _ = new_theory "A";
fun loop_tac g = loop_tac g;
Theorem timeout_thm:
  T
Proof
  loop_tac
QED
val _ = export_theory();
SML

timeout_log=$tmpdir/timeout.log
if (cd "$timeout_project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" build --tactic-timeout 0.1 ATheory) > "$timeout_log" 2>&1; then
  echo "expected looping tactic to time out" >&2
  exit 1
fi
require_grep "tactic timed out after 0.1s while building ATheory: loop_tac" "$timeout_log"
require_grep "instrumented log:" "$timeout_log"
if grep -q "goalfrag/checkpoint run failed\|plain-source fallback disabled" "$timeout_log"; then
  echo "timeout was reported as generic instrumentation failure" >&2
  exit 1
fi
