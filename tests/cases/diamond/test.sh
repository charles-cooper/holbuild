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

project=$tmpdir/project
mkdir -p "$project/src"
cat > "$project/holproject.toml" <<'TOML'
[project]
name = "diamond"

[build]
members = ["src"]
TOML
cat > "$project/src/AScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
val _ = new_theory "A";
val a_thm = store_thm("a_thm", ``T``, ACCEPT_TAC TRUTH);
val _ = export_theory();
SML
cat > "$project/src/BScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
open ATheory;
val _ = new_theory "B";
val b_thm = store_thm("b_thm", ``T``, ACCEPT_TAC ATheory.a_thm);
val _ = export_theory();
SML
cat > "$project/src/CScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
open ATheory;
val _ = new_theory "C";
val c_thm = store_thm("c_thm", ``T``, ACCEPT_TAC ATheory.a_thm);
val _ = export_theory();
SML
cat > "$project/src/DScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
open BTheory CTheory;
val _ = new_theory "D";
val d_thm = store_thm("d_thm", ``T /\ T``, CONJ_TAC THENL [ACCEPT_TAC BTheory.b_thm, ACCEPT_TAC CTheory.c_thm]);
val _ = export_theory();
SML

dry_log=$tmpdir/dry.log
(cd "$project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" build --dry-run DTheory) > "$dry_log"
require_grep "ATheory" "$dry_log"
require_grep "BTheory" "$dry_log"
require_grep "CTheory" "$dry_log"
require_grep "DTheory" "$dry_log"

(cd "$project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" -j2 build DTheory)
require_file "$project/.hol/checkpoints/diamond/src/DScript.sml.final_context.save"

second_log=$tmpdir/second.log
(cd "$project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" build DTheory) > "$second_log"
require_grep "DTheory is up to date" "$second_log"
