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

failure_project=$tmpdir/failure-project
mkdir -p "$failure_project/src"
cp "$project/holproject.toml" "$failure_project/holproject.toml"
python3 - <<PY
from pathlib import Path
src = Path("$project/src/AScript.sml").read_text()
src = src.replace('CONJ_TAC >- ACCEPT_TAC TRUTH >- ACCEPT_TAC TRUTH',
                  'CONJ_TAC >- FAIL_TAC "expected failure" >- ACCEPT_TAC TRUTH')
Path("$failure_project/src/AScript.sml").write_text(src)
PY

failure_log=$tmpdir/failure.log
if (cd "$failure_project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" build ATheory) > "$failure_log" 2>&1; then
  echo "expected failing proof to fail build" >&2
  exit 1
fi
require_grep "expected failure" "$failure_log"
if [[ -e "$failure_project/.holbuild/checkpoints/replay/src/AScript.sml.b_thm_context.save" || \
      -e "$failure_project/.holbuild/checkpoints/replay/src/AScript.sml.b_thm_context.save.ok" || \
      -e "$failure_project/.holbuild/checkpoints/replay/src/AScript.sml.b_thm_end_of_proof.save" || \
      -e "$failure_project/.holbuild/checkpoints/replay/src/AScript.sml.b_thm_end_of_proof.save.ok" ]]; then
  echo "stale b_thm checkpoint survived failed proof" >&2
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
require_grep "tactic timed out while building ATheory" "$timeout_log"
if grep -q "goalfrag/checkpoint run failed\|plain-source fallback disabled" "$timeout_log"; then
  echo "timeout was reported as generic instrumentation failure" >&2
  exit 1
fi
