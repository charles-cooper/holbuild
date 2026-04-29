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
require_file "$project/.holbuild/checkpoints/replay/src/AScript.sml.a_thm_context.save.ok"
require_file "$project/.holbuild/checkpoints/replay/src/AScript.sml.a_thm_end_of_proof.save"
require_file "$project/.holbuild/checkpoints/replay/src/AScript.sml.a_thm_end_of_proof.save.ok"
require_file "$project/.holbuild/checkpoints/replay/src/AScript.sml.b_thm_context.save"
require_file "$project/.holbuild/checkpoints/replay/src/AScript.sml.b_thm_context.save.ok"
require_file "$project/.holbuild/checkpoints/replay/src/AScript.sml.b_thm_end_of_proof.save"
require_file "$project/.holbuild/checkpoints/replay/src/AScript.sml.b_thm_end_of_proof.save.ok"
require_file "$project/.holbuild/checkpoints/replay/src/AScript.sml.c_thm_context.save"
require_file "$project/.holbuild/checkpoints/replay/src/AScript.sml.c_thm_context.save.ok"
require_file "$project/.holbuild/checkpoints/replay/src/AScript.sml.c_thm_end_of_proof.save"
require_file "$project/.holbuild/checkpoints/replay/src/AScript.sml.c_thm_end_of_proof.save.ok"
require_grep "theorem_boundary a_thm" "$project/.holbuild/dep/replay/src/AScript.sml.key"
require_grep "theorem_boundary c_thm" "$project/.holbuild/dep/replay/src/AScript.sml.key"
require_grep "_end_of_proof.save" "$project/.holbuild/dep/replay/src/AScript.sml.key"
require_grep "dependency_context_key=" "$project/.holbuild/dep/replay/src/AScript.sml.key"

cat > "$tmpdir/check-checkpoint-parents.sml" <<SML
fun expect_parent child expected =
  case PolyML.SaveState.showParent child of
      SOME actual => if actual = expected then () else raise Fail ("bad parent for " ^ child ^ ": " ^ actual)
    | NONE => raise Fail ("missing parent for " ^ child);
val deps_loaded = "$project/.holbuild/checkpoints/replay/src/AScript.sml.deps_loaded.save";
val a_context = "$project/.holbuild/checkpoints/replay/src/AScript.sml.a_thm_context.save";
val a_end = "$project/.holbuild/checkpoints/replay/src/AScript.sml.a_thm_end_of_proof.save";
val b_context = "$project/.holbuild/checkpoints/replay/src/AScript.sml.b_thm_context.save";
val b_end = "$project/.holbuild/checkpoints/replay/src/AScript.sml.b_thm_end_of_proof.save";
val _ = expect_parent a_end deps_loaded;
val _ = expect_parent a_context deps_loaded;
val _ = expect_parent b_end a_context;
val _ = expect_parent b_context a_context;
SML
"$HOLDIR/bin/hol" run --noconfig --holstate "$HOLDIR/bin/hol.state" "$tmpdir/check-checkpoint-parents.sml"

if grep -q "theorem_boundary simple_thm" "$project/.holbuild/dep/replay/src/AScript.sml.key"; then
  echo "simple Theorem = declaration should not create a goalfrag checkpoint" >&2
  exit 1
fi

cat > "$tmpdir/check-fragmented-proof-state.sml" <<'SML'
val _ = proofManagerLib.b();
val _ = proofManagerLib.b();
val _ =
  case proofManagerLib.top_goals() of
      [] => raise Fail "end-of-proof checkpoint has no multi-step goalfrag history"
    | _ => ();
SML
cat > "$tmpdir/check-proof-state.sml" <<'SML'
val _ = proofManagerLib.b();
val _ =
  case proofManagerLib.top_goals() of
      [] => raise Fail "end-of-proof checkpoint has no goalfrag history"
    | _ => ();
SML
"$HOLDIR/bin/hol" run --noconfig \
  --holstate "$project/.holbuild/checkpoints/replay/src/AScript.sml.b_thm_end_of_proof.save" \
  "$tmpdir/check-fragmented-proof-state.sml"
"$HOLDIR/bin/hol" run --noconfig \
  --holstate "$project/.holbuild/checkpoints/replay/src/AScript.sml.c_thm_end_of_proof.save" \
  "$tmpdir/check-proof-state.sml"

skip_goalfrag_project=$tmpdir/skip-goalfrag-project
mkdir -p "$skip_goalfrag_project/src"
cp "$project/holproject.toml" "$skip_goalfrag_project/holproject.toml"
cp "$project/src/AScript.sml" "$skip_goalfrag_project/src/AScript.sml"
(cd "$skip_goalfrag_project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" build --skip-goalfrag ATheory)
require_file "$skip_goalfrag_project/.holbuild/checkpoints/replay/src/AScript.sml.deps_loaded.save"
require_file "$skip_goalfrag_project/.holbuild/checkpoints/replay/src/AScript.sml.final_context.save"
if grep -q "theorem_boundary a_thm" "$skip_goalfrag_project/.holbuild/dep/replay/src/AScript.sml.key"; then
  echo "--skip-goalfrag should not create theorem boundaries" >&2
  exit 1
fi
if find "$skip_goalfrag_project/.holbuild/checkpoints/replay/src" -name '*_thm_context.save' -print -quit | grep -q .; then
  echo "--skip-goalfrag created theorem checkpoints" >&2
  exit 1
fi

rm "$project/.holbuild/checkpoints/replay/src/AScript.sml.a_thm_context.save.ok"
python3 - <<PY
from pathlib import Path
path = Path("$project/src/AScript.sml")
text = path.read_text()
path.write_text(text.replace('Theorem b_thm:', '(* missing-ok edit after a_thm *)\nTheorem b_thm:'))
PY

missing_ok_log=$tmpdir/missing-ok-replay.log
(cd "$project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" build ATheory) > "$missing_ok_log" 2>&1
if grep -q "replaying from checkpoint" "$missing_ok_log"; then
  echo "replayed from checkpoint without .ok marker" >&2
  exit 1
fi
require_file "$project/.holbuild/checkpoints/replay/src/AScript.sml.a_thm_context.save.ok"

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
      -e "$project/.holbuild/checkpoints/replay/src/AScript.sml.b_thm_context.save.ok" || \
      -e "$project/.holbuild/checkpoints/replay/src/AScript.sml.b_thm_end_of_proof.save" || \
      -e "$project/.holbuild/checkpoints/replay/src/AScript.sml.b_thm_end_of_proof.save.ok" ]]; then
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
if grep -q "retrying without theorem checkpoints" "$timeout_log"; then
  echo "timed out goalfrag proof retried plain source" >&2
  exit 1
fi
