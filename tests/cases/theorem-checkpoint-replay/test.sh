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

(cd "$project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" build ATheory)
require_file "$project/.holbuild/checkpoints/replay/src/AScript.sml.a_thm_context.save"
require_file "$project/.holbuild/checkpoints/replay/src/AScript.sml.a_thm_end_of_proof.save"
require_file "$project/.holbuild/checkpoints/replay/src/AScript.sml.b_thm_context.save"
require_file "$project/.holbuild/checkpoints/replay/src/AScript.sml.b_thm_end_of_proof.save"
require_file "$project/.holbuild/checkpoints/replay/src/AScript.sml.c_thm_context.save"
require_file "$project/.holbuild/checkpoints/replay/src/AScript.sml.c_thm_end_of_proof.save"
require_grep "theorem_boundary a_thm" "$project/.holbuild/dep/replay/src/AScript.sml.key"
require_grep "theorem_boundary c_thm" "$project/.holbuild/dep/replay/src/AScript.sml.key"
require_grep "_end_of_proof.save" "$project/.holbuild/dep/replay/src/AScript.sml.key"
require_grep "dependency_context_key=" "$project/.holbuild/dep/replay/src/AScript.sml.key"
if grep -q "theorem_boundary simple_thm" "$project/.holbuild/dep/replay/src/AScript.sml.key"; then
  echo "simple Theorem = declaration should not create a goalfrag checkpoint" >&2
  exit 1
fi

cat > "$tmpdir/check-proof-state.sml" <<'SML'
val _ = proofManagerLib.b();
val _ =
  case proofManagerLib.top_goals() of
      [] => raise Fail "end-of-proof checkpoint has no goalfrag history"
    | _ => ();
SML
"$HOLDIR/bin/hol" run --noconfig \
  --holstate "$project/.holbuild/checkpoints/replay/src/AScript.sml.b_thm_end_of_proof.save" \
  "$tmpdir/check-proof-state.sml"
"$HOLDIR/bin/hol" run --noconfig \
  --holstate "$project/.holbuild/checkpoints/replay/src/AScript.sml.c_thm_end_of_proof.save" \
  "$tmpdir/check-proof-state.sml"

python3 - <<PY
from pathlib import Path
path = Path("$project/src/AScript.sml")
text = path.read_text()
path.write_text(text.replace('Theorem b_thm:', '(* proof/comment edit after a_thm *)\nTheorem b_thm:'))
PY

replay_log=$tmpdir/replay.log
(cd "$project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" build ATheory) > "$replay_log" 2>&1
require_grep "ATheory replaying from checkpoint a_thm" "$replay_log"
require_file "$project/.holbuild/gen/src/ATheory.sig"
require_file "$project/.holbuild/gen/src/ATheory.sml"
require_file "$project/.holbuild/obj/src/ATheory.dat"

python3 - <<PY
from pathlib import Path
path = Path("$project/src/AScript.sml")
text = path.read_text()
path.write_text(text.replace('CONJ_TAC >- ACCEPT_TAC TRUTH >- ACCEPT_TAC TRUTH', 'CONJ_TAC >- FAIL_TAC "expected failure" >- ACCEPT_TAC TRUTH'))
PY

failure_log=$tmpdir/failure.log
if (cd "$project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" build ATheory) > "$failure_log" 2>&1; then
  echo "expected failing proof to fail build" >&2
  exit 1
fi
require_grep "expected failure" "$failure_log"
if [[ -e "$project/.holbuild/checkpoints/replay/src/AScript.sml.b_thm_context.save" || \
      -e "$project/.holbuild/checkpoints/replay/src/AScript.sml.b_thm_end_of_proof.save" ]]; then
  echo "stale b_thm checkpoint survived failed proof" >&2
  exit 1
fi
