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

Theorem reverse_branch_suffix:
  T /\ T /\ T
Proof
  CONJ_TAC
  >> reverse CONJ_TAC >- (ACCEPT_TAC TRUTH)
  >> simp[GSYM CONJ_ASSOC]
  >> reverse CONJ_TAC >- (ACCEPT_TAC TRUTH)
  >> ACCEPT_TAC TRUTH
QED

Theorem verifereum_reverse_shape:
  T
Proof
  simp[step_create_def] >> strip_tac
  >> rewrite_tac[Ntimes CONJ_ASSOC 3]
  >> reverse conj_tac >- (
    (* a large first reverse branch, matching the shape that used to hide
       all following same-level work inside one plan line. *)
    qpat_x_assum `proceed_create _ _ _ _ _ se = _` mp_tac >>
    rewrite_tac[proceed_create_def] >>
    simp[ignore_bind_def, bind_def, update_accounts_def, return_def,
          get_rollback_def, get_original_def, set_original_def, fail_def] >>
    strip_tac >> gvs[] >>
    drule push_context_effect >> strip_tac >> gvs[] >>
    Cases_on`s.contexts` >- gvs[] >> simp[] >>
    Cases_on`se.contexts` >- gvs[] >> simp[Abbr`slc`] >>
    gvs[set_last_accounts_def] >>
    simp[EL_SNOC] >>
    reverse(qspec_then`t`FULL_STRUCT_CASES_TAC SNOC_CASES >> gvs[]) >- (
      simp[LAST_CONS_SNOC, FRONT_CONS_SNOC] >>
      conj_tac >- (Cases >> simp[EL_SNOC]) >>
      simp[Abbr`uc`, update_account_def, APPLY_UPDATE_THM] >>
      gen_tac >> simp[LAST_CONS_SNOC]) >>
    simp[Abbr`uc`, lookup_account_def, update_account_def, APPLY_UPDATE_THM])
  >> simp[GSYM CONJ_ASSOC]
  >> reverse conj_tac >- (
    reverse conj_tac
    >- metis_tac[SUBSET_TRANS, same_frame_rel_def] >>
    qpat_x_assum`same_frame_rel s se`mp_tac >>
    simp[same_frame_rel_def] >> strip_tac >>
    Cases_on`s.contexts` >- gvs[] >> simp[] >>
    Cases_on`s'.contexts` >- gvs[] >> simp[] >>
    Cases_on`t'` >- gvs[] >> simp[] >>
    Cases_on`se.contexts` >- gvs[] >> fs[])
  >> qpat_x_assum `proceed_create _ _ _ _ _ se = _` mp_tac
  >> simp[proceed_create_def]
  >> strip_tac >> gvs[]
  >> drule push_context_effect >> strip_tac >> gvs[]
  >> rpt strip_tac
  >> `i < LENGTH se.contexts` by gvs[same_frame_rel_def]
  >> simp[set_last_accounts_def]
  >> qmatch_goalsub_abbrev_tac`SNOC new`
  >> qhdtm_x_assum`push_context` kall_tac
  >> qpat_x_assum`_ = TL s.contexts`mp_tac
  >> simp[LIST_EQ_REWRITE] >> rewrite_tac[GSYM EL]
  >> Cases_on`i=0` >- (
    Cases_on`FRONT se.contexts = []` >- gvs[] >>
    rewrite_tac[GSYM EL] >> DEP_REWRITE_TAC[EL_SNOC] >> simp[LENGTH_FRONT])
  >> Cases_on`i = LENGTH s.contexts - 1` >- (
    simp[EL_LENGTH_SNOC] >> first_x_assum(qspec_then`PRE i`mp_tac))
  >> strip_tac
  >> simp[EL_SNOC, LENGTH_FRONT, EL_FRONT, NULL_EQ]
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

check_plan reverse_branch_suffix <<'EXPECTED'
holbuild goalfrag plan ATheory:reverse_branch_suffix source=src/AScript.sml (5 steps)
  00 CONJ_TAC
  01 >> reverse CONJ_TAC >- (ACCEPT_TAC TRUTH)
  02 >> simp[GSYM CONJ_ASSOC]
  03 >> reverse CONJ_TAC >- (ACCEPT_TAC TRUTH)
  04 >> ACCEPT_TAC TRUTH
EXPECTED

check_plan verifereum_reverse_shape <<'EXPECTED'
holbuild goalfrag plan ATheory:verifereum_reverse_shape source=src/AScript.sml (34 steps)
  00 simp[step_create_def]
  01 >> strip_tac
  02 >> rewrite_tac[Ntimes CONJ_ASSOC 3]
  03 >> reverse conj_tac >- (
         (* a large first reverse branch, matching the shape that used to hide
            all following same-level work inside one plan line. *)
         qpat_x_assum `proceed_create _ _ _ _ _ se = _` mp_tac >>
         rewrite_tac[proceed_create_def] >>
         simp[ignore_bind_def, bind_def, update_accounts_def, return_def,
               get_rollback_def, get_original_def, set_original_def, fail_def] >>
         strip_tac >> gvs[] >>
         drule push_context_effect >> strip_tac >> gvs[] >>
         Cases_on`s.contexts` >- gvs[] >> simp[] >>
         Cases_on`se.contexts` >- gvs[] >> simp[Abbr`slc`] >>
         gvs[set_last_accounts_def] >>
         simp[EL_SNOC] >>
         reverse(qspec_then`t`FULL_STRUCT_CASES_TAC SNOC_CASES >> gvs[]) >- (
           simp[LAST_CONS_SNOC, FRONT_CONS_SNOC] >>
           conj_tac >- (Cases >> simp[EL_SNOC]) >>
           simp[Abbr`uc`, update_account_def, APPLY_UPDATE_THM] >>
           gen_tac >> simp[LAST_CONS_SNOC]) >>
         simp[Abbr`uc`, lookup_account_def, update_account_def, APPLY_UPDATE_THM])
  04 >> simp[GSYM CONJ_ASSOC]
  05 >> reverse conj_tac >- (
         reverse conj_tac
         >- metis_tac[SUBSET_TRANS, same_frame_rel_def] >>
         qpat_x_assum`same_frame_rel s se`mp_tac >>
         simp[same_frame_rel_def] >> strip_tac >>
         Cases_on`s.contexts` >- gvs[] >> simp[] >>
         Cases_on`s'.contexts` >- gvs[] >> simp[] >>
         Cases_on`t'` >- gvs[] >> simp[] >>
         Cases_on`se.contexts` >- gvs[] >> fs[])
  06 >> qpat_x_assum `proceed_create _ _ _ _ _ se = _` mp_tac
  07 >> simp[proceed_create_def]
  08 >> strip_tac
  09 >> gvs[]
  10 >> drule push_context_effect
  11 >> strip_tac
  12 >> gvs[]
  13 >> rpt
  14   strip_tac
  15 >> sg `i < LENGTH se.contexts`
  16   >- gvs[same_frame_rel_def]
  17 >> simp[set_last_accounts_def]
  18 >> qmatch_goalsub_abbrev_tac`SNOC new`
  19 >> qhdtm_x_assum`push_context` kall_tac
  20 >> qpat_x_assum`_ = TL s.contexts`mp_tac
  21 >> simp[LIST_EQ_REWRITE]
  22 >> rewrite_tac[GSYM EL]
  23 >> Cases_on`i=0`
  24   >- Cases_on`FRONT se.contexts = []`
  25     >- gvs[]
  26   >> rewrite_tac[GSYM EL]
  27   >> DEP_REWRITE_TAC[EL_SNOC]
  28   >> simp[LENGTH_FRONT]
  29 >> Cases_on`i = LENGTH s.contexts - 1`
  30   >- simp[EL_LENGTH_SNOC]
  31   >> first_x_assum(qspec_then`PRE i`mp_tac)
  32 >> strip_tac
  33 >> simp[EL_SNOC, LENGTH_FRONT, EL_FRONT, NULL_EQ]
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
