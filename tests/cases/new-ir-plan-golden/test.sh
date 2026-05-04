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
name = "new-ir-plan"

[build]
members = ["src"]
TOML
cat > "$project/src/AScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
val _ = new_theory "A";
SML

check_plan() {
  local theorem=$1
  local expected=$tmpdir/$theorem.expected
  local actual=$tmpdir/$theorem.actual
  cat > "$expected"
  (cd "$project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" execution-plan ATheory:"$theorem") > "$actual" 2>&1
  if ! diff -u "$expected" "$actual"; then
    echo "new-ir plan mismatch for $theorem" >&2
    exit 1
  fi
}

cat >> "$project/src/AScript.sml" <<'SML'
Theorem thenl_literal_plan:
  T /\ T
Proof
  CONJ_TAC THENL [ACCEPT_TAC TRUTH, ACCEPT_TAC TRUTH]
QED
SML
check_plan thenl_literal_plan <<'EXPECTED'
holbuild proof-ir plan ATheory:thenl_literal_plan source=src/AScript.sml (2 steps)
  00 CONJ_TAC
  01 >| [...]
EXPECTED

cat >> "$project/src/AScript.sml" <<'SML'
Theorem allgoals_plan:
  T /\ T
Proof
  CONJ_TAC >>> ALLGOALS (ACCEPT_TAC TRUTH)
QED
SML
check_plan allgoals_plan <<'EXPECTED'
holbuild proof-ir plan ATheory:allgoals_plan source=src/AScript.sml (2 steps)
  00 CONJ_TAC
  01 >> list_tac ALLGOALS (ACCEPT_TAC TRUTH)
EXPECTED

cat >> "$project/src/AScript.sml" <<'SML'
Theorem tacs_to_lt_plan:
  T /\ T
Proof
  CONJ_TAC >>> TACS_TO_LT [ACCEPT_TAC TRUTH, ACCEPT_TAC TRUTH]
QED
SML
check_plan tacs_to_lt_plan <<'EXPECTED'
holbuild proof-ir plan ATheory:tacs_to_lt_plan source=src/AScript.sml (2 steps)
  00 CONJ_TAC
  01 >> list_tac TACS_TO_LT [ACCEPT_TAC TRUTH, ACCEPT_TAC TRUTH]
EXPECTED

cat >> "$project/src/AScript.sml" <<'SML'
Theorem selectors_plan:
  T /\ T /\ T
Proof
  rpt CONJ_TAC
  >>> NTH_GOAL (ACCEPT_TAC TRUTH) 2
  >>> LASTGOAL (ACCEPT_TAC TRUTH)
  >>> HEADGOAL (ACCEPT_TAC TRUTH)
QED
SML
check_plan selectors_plan <<'EXPECTED'
holbuild proof-ir plan ATheory:selectors_plan source=src/AScript.sml (4 steps)
  00 rpt CONJ_TAC
  01 >> list_tac NTH_GOAL (ACCEPT_TAC TRUTH) 2
  02 >> list_tac LASTGOAL (ACCEPT_TAC TRUTH)
  03 >> list_tac HEADGOAL (ACCEPT_TAC TRUTH)
EXPECTED

cat >> "$project/src/AScript.sml" <<'SML'
Theorem split_first_lt_plan:
  T /\ T
Proof
  CONJ_TAC
  >>> SPLIT_LT 1 (TACS_TO_LT [ACCEPT_TAC TRUTH], FIRST_LT ACCEPT_TAC TRUTH)
QED
SML
check_plan split_first_lt_plan <<'EXPECTED'
holbuild proof-ir plan ATheory:split_first_lt_plan source=src/AScript.sml (2 steps)
  00 CONJ_TAC
  01 >> list_tac SPLIT_LT 1 (TACS_TO_LT [ACCEPT_TAC TRUTH], FIRST_LT ACCEPT_TAC TRUTH)
EXPECTED

cat >> "$project/src/AScript.sml" <<'SML'
Theorem try_plan:
  T
Proof
  TRY NO_TAC >> ACCEPT_TAC TRUTH
QED
SML
check_plan try_plan <<'EXPECTED'
holbuild proof-ir plan ATheory:try_plan source=src/AScript.sml (5 steps)
  00 TRY
  01   NO_TAC
  02   |
  03   ALL_TAC
  04 >> ACCEPT_TAC TRUTH
EXPECTED

cat >> "$project/src/AScript.sml" <<'SML'
Theorem repeat_plan:
  T
Proof
  REPEAT NO_TAC >> ACCEPT_TAC TRUTH
QED
SML
check_plan repeat_plan <<'EXPECTED'
holbuild proof-ir plan ATheory:repeat_plan source=src/AScript.sml (2 steps)
  00 REPEAT NO_TAC
  01 >> ACCEPT_TAC TRUTH
EXPECTED

cat >> "$project/src/AScript.sml" <<'SML'
Theorem reverse_plan:
  T /\ T
Proof
  REVERSE CONJ_TAC >- ACCEPT_TAC TRUTH >- ACCEPT_TAC TRUTH
QED
SML
check_plan reverse_plan <<'EXPECTED'
holbuild proof-ir plan ATheory:reverse_plan source=src/AScript.sml (3 steps)
  00 REVERSE CONJ_TAC
  01 >- ACCEPT_TAC TRUTH
  02 >- ACCEPT_TAC TRUTH
EXPECTED

cat >> "$project/src/AScript.sml" <<'SML'
Theorem try_repeat_reverse_lt_plan:
  T /\ T
Proof
  CONJ_TAC
  >>> REVERSE_LT
  >>> TRY_LT NO_LT
  >>> REPEAT_LT NO_LT
  >>> TACS_TO_LT [ACCEPT_TAC TRUTH, ACCEPT_TAC TRUTH]
QED
SML
check_plan try_repeat_reverse_lt_plan <<'EXPECTED'
holbuild proof-ir plan ATheory:try_repeat_reverse_lt_plan source=src/AScript.sml (5 steps)
  00 CONJ_TAC
  01 >> list_tac REVERSE_LT
  02 >> list_tac TRY_LT NO_LT
  03 >> list_tac REPEAT_LT NO_LT
  04 >> list_tac TACS_TO_LT [ACCEPT_TAC TRUTH, ACCEPT_TAC TRUTH]
EXPECTED

cat >> "$project/src/AScript.sml" <<'SML'
Theorem orelse_plan:
  T
Proof
  NO_TAC ORELSE ACCEPT_TAC TRUTH
QED
SML
check_plan orelse_plan <<'EXPECTED'
holbuild proof-ir plan ATheory:orelse_plan source=src/AScript.sml (4 steps)
  00 ORELSE
  01   NO_TAC
  02   |
  03   ACCEPT_TAC TRUTH
EXPECTED

cat >> "$project/src/AScript.sml" <<'SML'
Theorem suffices_plan:
  F ==> T
Proof
  strip_tac
  >> `F` suffices_by simp[]
  >> FIRST_ASSUM ACCEPT_TAC
QED
SML
check_plan suffices_plan <<'EXPECTED'
holbuild proof-ir plan ATheory:suffices_plan source=src/AScript.sml (4 steps)
  00 strip_tac
  01 >> Q_TAC SUFF_TAC `F`
  02   >- simp[]
  03 >> FIRST_ASSUM ACCEPT_TAC
EXPECTED

cat >> "$project/src/AScript.sml" <<'SML'
Theorem map_every_plan:
  T
Proof
  MAP_EVERY ACCEPT_TAC [TRUTH]
QED
SML
check_plan map_every_plan <<'EXPECTED'
holbuild proof-ir plan ATheory:map_every_plan source=src/AScript.sml (1 steps)
  00 ACCEPT_TAC TRUTH
EXPECTED

cat >> "$project/src/AScript.sml" <<'SML'
Theorem map_first_plan:
  T
Proof
  MAP_FIRST ACCEPT_TAC [TRUTH]
QED
SML
check_plan map_first_plan <<'EXPECTED'
holbuild proof-ir plan ATheory:map_first_plan source=src/AScript.sml (2 steps)
  00 FIRST
  01   ACCEPT_TAC TRUTH
EXPECTED

cat >> "$project/src/AScript.sml" <<'SML'
Theorem select_goals_plan:
  T /\ T
Proof
  CONJ_TAC >>~ [`T`]
  >> ACCEPT_TAC TRUTH
  >> ACCEPT_TAC TRUTH
QED
SML
check_plan select_goals_plan <<'EXPECTED'
holbuild proof-ir plan ATheory:select_goals_plan source=src/AScript.sml (4 steps)
  00 CONJ_TAC
  01 >> list_tac Q.SELECT_GOALS_LT [`T`]
  02 >> ACCEPT_TAC TRUTH
  03 >> ACCEPT_TAC TRUTH
EXPECTED

cat >> "$project/src/AScript.sml" <<'SML'
Theorem select_single_plan:
  T /\ T
Proof
  CONJ_TAC >~ `T`
  >> ACCEPT_TAC TRUTH
  >> ACCEPT_TAC TRUTH
QED
SML
check_plan select_single_plan <<'EXPECTED'
holbuild proof-ir plan ATheory:select_single_plan source=src/AScript.sml (4 steps)
  00 CONJ_TAC
  01 >> list_tac Q.SELECT_GOAL_LT `T`
  02 >> ACCEPT_TAC TRUTH
  03 >> ACCEPT_TAC TRUTH
EXPECTED

cat >> "$project/src/AScript.sml" <<'SML'
Theorem select_then1_plan:
  T /\ T
Proof
  CONJ_TAC >>~- ([`T`], ACCEPT_TAC TRUTH)
  >> ACCEPT_TAC TRUTH
QED
SML
check_plan select_then1_plan <<'EXPECTED'
holbuild proof-ir plan ATheory:select_then1_plan source=src/AScript.sml (3 steps)
  00 CONJ_TAC
  01 >> list_tac Q.SELECT_GOALS_LT_THEN1 [`T`] (ACCEPT_TAC TRUTH)
  02 >> ACCEPT_TAC TRUTH
EXPECTED
