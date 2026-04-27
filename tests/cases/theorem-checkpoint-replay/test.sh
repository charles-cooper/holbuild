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

Theorem a_thm:
  T
Proof
  ACCEPT_TAC TRUTH
QED

Theorem b_thm:
  T
Proof
  ACCEPT_TAC TRUTH
QED

val _ = export_theory();
SML

(cd "$project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" build ATheory)
require_file "$project/.hol/checkpoints/replay/src/AScript.sml.a_thm_context.save"
require_file "$project/.hol/checkpoints/replay/src/AScript.sml.a_thm_end_of_proof.save"
require_file "$project/.hol/checkpoints/replay/src/AScript.sml.b_thm_context.save"
require_file "$project/.hol/checkpoints/replay/src/AScript.sml.b_thm_end_of_proof.save"
require_grep "theorem_boundary a_thm" "$project/.hol/dep/replay/src/AScript.sml.key"
require_grep "_end_of_proof.save" "$project/.hol/dep/replay/src/AScript.sml.key"
require_grep "dependency_context_key=" "$project/.hol/dep/replay/src/AScript.sml.key"

cat > "$tmpdir/check-proof-state.sml" <<'SML'
val _ = proofManagerLib.b();
val _ =
  case proofManagerLib.top_goals() of
      [] => raise Fail "end-of-proof checkpoint has no goalfrag history"
    | _ => ();
SML
"$HOLDIR/bin/hol" run --noconfig \
  --holstate "$project/.hol/checkpoints/replay/src/AScript.sml.a_thm_end_of_proof.save" \
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
require_file "$project/.hol/gen/src/ATheory.sig"
require_file "$project/.hol/gen/src/ATheory.sml"
require_file "$project/.hol/obj/src/ATheory.dat"
