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
name = "golden"

[build]
members = ["src"]
TOML
cat > "$project/src/AScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
val _ = new_theory "A";

Theorem grouped_prefix:
  T
Proof
  rpt gen_tac >> strip_tac >> qpat_x_assum `step s = _` mp_tac >> simp[]
QED

Theorem reverse_branch:
  T
Proof
  simp[step_create_def] >> strip_tac
  >> rewrite_tac[Ntimes CONJ_ASSOC 3]
  >> reverse conj_tac >- (
    qpat_x_assum `proceed_create _ _ _ _ _ se = _` mp_tac >>
    rewrite_tac[proceed_create_def] >>
    strip_tac >> gvs[] )
  >> strip_tac
QED

Theorem reverse_thenl:
  T
Proof
  CONJ_TAC
  \\ Tactical.REVERSE (TRY CONJ_TAC) THENL
     [ACCEPT_TAC TRUTH, ACCEPT_TAC TRUTH, ACCEPT_TAC TRUTH]
QED

Theorem branch_list:
  T /\ T
Proof
  CONJ_TAC >| [ACCEPT_TAC TRUTH, ACCEPT_TAC TRUTH]
QED

Theorem first_try_repeat:
  T
Proof
  FIRST [NO_TAC, TRY NO_TAC, REPEAT NO_TAC, ACCEPT_TAC TRUTH]
QED

Theorem goal_selector_numbers:
  T /\ T /\ T
Proof
  rpt CONJ_TAC
  >>> NTH_GOAL (ACCEPT_TAC TRUTH) 2
  >>> SPLIT_LT 1 (ALL_LT, FIRST_LT ACCEPT_TAC TRUTH)
QED

Theorem map_aliases:
  T /\ T
Proof
  CONJ_TAC
  >- MAP_EVERY (fn th => ACCEPT_TAC th) [TRUTH]
  >> MAP_FIRST (fn th => ACCEPT_TAC th) [TRUTH]
QED

Theorem branch_and_by:
  T /\ T
Proof
  CONJ_TAC
  >- (`T` by ACCEPT_TAC TRUTH >> ACCEPT_TAC TRUTH)
  \\ `T` suffices_by simp[]
  \\ ACCEPT_TAC TRUTH
QED

Theorem nested_combinators:
  T /\ T /\ T
Proof
  rpt strip_tac
  >> CONJ_TAC
  >- (TRY CONJ_TAC >> ACCEPT_TAC TRUTH)
  >> reverse CONJ_TAC
  >- (sg `T` >- ACCEPT_TAC TRUTH >> ACCEPT_TAC TRUTH)
  >> ACCEPT_TAC TRUTH
QED

Theorem select_goals:
  T /\ T
Proof
  CONJ_TAC >>~ [`T`]
  \\ ACCEPT_TAC TRUTH
  \\ ACCEPT_TAC TRUTH
QED

Theorem select_single:
  T /\ T
Proof
  CONJ_TAC >~ `T`
  \\ ACCEPT_TAC TRUTH
  \\ ACCEPT_TAC TRUTH
QED

Theorem select_then1:
  T /\ T
Proof
  CONJ_TAC >>~- ([`T`], ACCEPT_TAC TRUTH)
  \\ ACCEPT_TAC TRUTH
QED

val _ = export_theory();
SML

check_plan() {
  local theorem=$1
  local expected=$tmpdir/$theorem.expected
  local actual=$tmpdir/$theorem.actual
  cat > "$expected"
  (cd "$project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" goalfrag-plan "ATheory:$theorem") > "$actual"
  diff -u "$expected" "$actual"
}

check_plan grouped_prefix <<'EXPECTED'
holbuild goalfrag plan ATheory:grouped_prefix source=src/AScript.sml (5 steps)
  00 rpt
  01   gen_tac
  02 >> strip_tac
  03 >> qpat_x_assum `step s = _` mp_tac
  04 >> simp[]
EXPECTED

check_plan reverse_branch <<'EXPECTED'
holbuild goalfrag plan ATheory:reverse_branch source=src/AScript.sml (5 steps)
  00 simp[step_create_def]
  01 >> strip_tac
  02 >> rewrite_tac[Ntimes CONJ_ASSOC 3]
  03 >> reverse conj_tac >- (
         qpat_x_assum `proceed_create _ _ _ _ _ se = _` mp_tac >>
         rewrite_tac[proceed_create_def] >>
         strip_tac >> gvs[] )
  04 >> strip_tac
EXPECTED

check_plan reverse_thenl <<'EXPECTED'
holbuild goalfrag plan ATheory:reverse_thenl source=src/AScript.sml (1 steps)
  00 CONJ_TAC
       \\ Tactical.REVERSE (TRY CONJ_TAC) THENL
          [ACCEPT_TAC TRUTH, ACCEPT_TAC TRUTH, ACCEPT_TAC TRUTH]
EXPECTED

check_plan branch_list <<'EXPECTED'
holbuild goalfrag plan ATheory:branch_list source=src/AScript.sml (1 steps)
  00 CONJ_TAC >| [ACCEPT_TAC TRUTH, ACCEPT_TAC TRUTH]
EXPECTED

check_plan first_try_repeat <<'EXPECTED'
holbuild goalfrag plan ATheory:first_try_repeat source=src/AScript.sml (10 steps)
  00 FIRST
  01   NO_TAC
  02   |
  03   FIRST
  04     NO_TAC
  05   |
  06   rpt
  07     NO_TAC
  08   |
  09   ACCEPT_TAC TRUTH
EXPECTED

check_plan goal_selector_numbers <<'EXPECTED'
holbuild goalfrag plan ATheory:goal_selector_numbers source=src/AScript.sml (7 steps)
  00 rpt
  01   CONJ_TAC
  02 >> NTH_GOAL 2
  03   ACCEPT_TAC TRUTH
  04 >> split_lt 1
  05   |
  06   FIRST_LT ACCEPT_TAC TRUTH
EXPECTED

check_plan map_aliases <<'EXPECTED'
holbuild goalfrag plan ATheory:map_aliases source=src/AScript.sml (3 steps)
  00 CONJ_TAC
  01   >- MAP_EVERY (fn th => ACCEPT_TAC th) [TRUTH]
  02 >> MAP_FIRST (fn th => ACCEPT_TAC th) [TRUTH]
EXPECTED

check_plan branch_and_by <<'EXPECTED'
holbuild goalfrag plan ATheory:branch_and_by source=src/AScript.sml (7 steps)
  00 CONJ_TAC
  01   >- sg `T`
  02     >- ACCEPT_TAC TRUTH
  03   >> ACCEPT_TAC TRUTH
  04 >> Tactical.REVERSE (sg `T`)
  05   >- simp[]
  06 >> ACCEPT_TAC TRUTH
EXPECTED

check_plan nested_combinators <<'EXPECTED'
holbuild goalfrag plan ATheory:nested_combinators source=src/AScript.sml (8 steps)
  00 rpt
  01   strip_tac
  02 >> CONJ_TAC
  03   >- FIRST
  04     CONJ_TAC
  05   >> ACCEPT_TAC TRUTH
  06 >> reverse CONJ_TAC
       >- (sg `T` >- ACCEPT_TAC TRUTH >> ACCEPT_TAC TRUTH)
  07 >> ACCEPT_TAC TRUTH
EXPECTED

check_plan select_goals <<'EXPECTED'
holbuild goalfrag plan ATheory:select_goals source=src/AScript.sml (4 steps)
  00 CONJ_TAC
  01 >> list_tac Q.SELECT_GOALS_LT [`T`]
  02 >> ACCEPT_TAC TRUTH
  03 >> ACCEPT_TAC TRUTH
EXPECTED

check_plan select_single <<'EXPECTED'
holbuild goalfrag plan ATheory:select_single source=src/AScript.sml (4 steps)
  00 CONJ_TAC
  01 >> list_tac Q.SELECT_GOAL_LT `T`
  02 >> ACCEPT_TAC TRUTH
  03 >> ACCEPT_TAC TRUTH
EXPECTED

check_plan select_then1 <<'EXPECTED'
holbuild goalfrag plan ATheory:select_then1 source=src/AScript.sml (3 steps)
  00 CONJ_TAC
  01 >> list_tac Q.SELECT_GOALS_LT_THEN1 [`T`] (
       ACCEPT_TAC TRUTH
     )
  02 >> ACCEPT_TAC TRUTH
EXPECTED
