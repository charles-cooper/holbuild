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

make_project() {
  local project=$1
  mkdir -p "$project/src"
  cat > "$project/holproject.toml" <<'TOML'
[project]
name = "goalfrag-runtime"

[build]
members = ["src"]
TOML
}

run_goalfrag_success_project() {
  local project=$tmpdir/success
  make_project "$project"
  cat > "$project/src/AScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
val _ = new_theory "A";

Theorem try_no_tac:
  T
Proof
  TRY NO_TAC >> ACCEPT_TAC TRUTH
QED

Theorem direct_tacs_to_lt:
  T
Proof
  ALL_TAC >>> TACS_TO_LT [ACCEPT_TAC TRUTH]
QED

Theorem select_then1_nested_body:
  T /\ T
Proof
  CONJ_TAC >>~- ([`T`], sg `T` >- ACCEPT_TAC TRUTH >> ACCEPT_TAC TRUTH)
QED

Theorem no_lt_orelse:
  T
Proof
  ALL_TAC >>> (NO_LT ORELSE_LT TACS_TO_LT [ACCEPT_TAC TRUTH])
QED

Theorem nth_goal_expr:
  T /\ T /\ T
Proof
  rpt CONJ_TAC >>> NTH_GOAL (ACCEPT_TAC TRUTH) (1 + 1) >>>
  TACS_TO_LT [ACCEPT_TAC TRUTH, ACCEPT_TAC TRUTH]
QED

Theorem split_expr:
  T /\ T
Proof
  CONJ_TAC >>> SPLIT_LT (1 + 0)
    (TACS_TO_LT [ACCEPT_TAC TRUTH], TACS_TO_LT [ACCEPT_TAC TRUTH])
QED

Theorem try_then1_group:
  (T /\ T) /\ T
Proof
  CONJ_TAC >> TRY (CONJ_TAC >- ACCEPT_TAC TRUTH) >> ACCEPT_TAC TRUTH
QED

Theorem by_after_multiple_goals:
  p /\ q ==> p /\ q
Proof
  strip_tac
  \\ CONJ_TAC
  \\ `T` by ACCEPT_TAC TRUTH
  \\ FIRST_ASSUM ACCEPT_TAC
QED

Theorem repeat_case_atomic:
  (case x:'a option of NONE => T | SOME y => T)
Proof
  rpt CASE_TAC \\ simp[]
QED

Theorem first_per_goal:
  T /\ (F ==> F)
Proof
  CONJ_TAC
  \\ FIRST [ACCEPT_TAC TRUTH, DISCH_TAC \\ FIRST_ASSUM ACCEPT_TAC]
QED

Theorem qed_closes_branch:
  T /\ T
Proof
  CONJ_TAC
  >- ACCEPT_TAC TRUTH
  >> (
    ACCEPT_TAC TRUTH
QED

val _ = export_theory();
SML
  (cd "$project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" build --skip-checkpoints --tactic-timeout 60) > "$tmpdir/success.goalfrag.out" 2>&1
  (cd "$project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" build --force --skip-goalfrag --skip-checkpoints) > "$tmpdir/success.plain.out" 2>&1
}

expect_both_fail() {
  local name=$1
  local proof=$2
  local project=$tmpdir/$name
  make_project "$project"
  cat > "$project/src/AScript.sml" <<SML
open HolKernel Parse boolLib bossLib;
val _ = new_theory "A";

$proof

val _ = export_theory();
SML
  if (cd "$project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" build --skip-checkpoints --tactic-timeout 60) > "$tmpdir/$name.goalfrag.out" 2>&1; then
    echo "expected goalfrag build to fail for $name" >&2
    exit 1
  fi
  if (cd "$project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" build --force --skip-goalfrag --skip-checkpoints) > "$tmpdir/$name.plain.out" 2>&1; then
    echo "expected plain build to fail for $name" >&2
    exit 1
  fi
}

run_goalfrag_success_project

expect_both_fail first_empty_then 'Theorem first_empty_then:
  T
Proof
  FIRST [] >> ACCEPT_TAC TRUTH
QED'
require_grep 'FIRST \[\]' "$tmpdir/first_empty_then.goalfrag.out"
require_grep 'NO_TAC' "$tmpdir/first_empty_then.plain.out"

expect_both_fail map_first_empty_then 'Theorem map_first_empty_then:
  T
Proof
  MAP_FIRST (fn th => ACCEPT_TAC th) [] >> ACCEPT_TAC TRUTH
QED'
require_grep 'MAP_FIRST' "$tmpdir/map_first_empty_then.goalfrag.out"
require_grep 'NO_TAC' "$tmpdir/map_first_empty_then.plain.out"
