#!/usr/bin/env bash
set -euo pipefail

HOLDIR=${HOLDIR:-${HOLBUILD_HOLDIR:-}}
if [[ -z "${HOLDIR}" ]]; then
  echo "Set HOLDIR=/path/to/HOL or HOLBUILD_HOLDIR" >&2
  exit 2
fi

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
HOLBUILD_BIN=${HOLBUILD_BIN:-"$ROOT/bin/holbuild"}

tmpdir=$(mktemp -d)
cleanup() { rm -rf "$tmpdir"; }
trap cleanup EXIT

require_file() {
  local path=$1
  [[ -f "$path" ]] || { echo "missing expected file: $path" >&2; exit 1; }
}

run_basic_theory_build() {
  local project=$tmpdir/basic
  mkdir -p "$project/src"
  cat > "$project/holproject.toml" <<'TOML'
[project]
name = "basic"

[build]
members = ["src"]

[[heap]]
name = "main"
output = ".hol/heap/main.save"
objects = ["ATheory"]
TOML
  cat > "$project/src/AScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;

val _ = new_theory "A";

val a_thm = store_thm("a_thm", ``T``, ACCEPT_TAC TRUTH);

val _ = export_theory();
SML

  (cd "$project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" build ATheory)

  require_file "$project/.hol/gen/src/ATheory.sig"
  require_file "$project/.hol/gen/src/ATheory.sml"
  require_file "$project/.hol/obj/src/ATheory.dat"
  require_file "$project/.hol/checkpoints/basic/src/AScript.sml.deps_loaded.save"
  require_file "$project/.hol/checkpoints/basic/src/AScript.sml.final_context.save"
  require_file "$project/.hol/dep/basic/src/AScript.sml.key"

  local second_log=$tmpdir/basic-second.log
  (cd "$project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" build ATheory) > "$second_log"
  grep -q "ATheory is up to date" "$second_log"

  (cd "$project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" heap main)
  require_file "$project/.hol/heap/main.save"
}

run_diamond_theory_build() {
  local project=$tmpdir/diamond
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

  local dry_log=$tmpdir/diamond-dry.log
  (cd "$project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" build --dry-run DTheory) > "$dry_log"
  grep -n "ATheory" "$dry_log" | grep -q "^[0-9]"
  grep -n "BTheory" "$dry_log" | grep -q "^[0-9]"
  grep -n "CTheory" "$dry_log" | grep -q "^[0-9]"
  grep -n "DTheory" "$dry_log" | grep -q "^[0-9]"

  (cd "$project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" build DTheory)
  require_file "$project/.hol/checkpoints/diamond/src/DScript.sml.final_context.save"

  local second_log=$tmpdir/diamond-second.log
  (cd "$project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" build DTheory) > "$second_log"
  grep -q "DTheory is up to date" "$second_log"
}

run_object_target_rejection() {
  local project=$tmpdir/reject
  mkdir -p "$project/src"
  cat > "$project/holproject.toml" <<'TOML'
[project]
name = "reject"

[build]
members = ["src"]
TOML
  cat > "$project/src/AScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
val _ = new_theory "A";
val _ = export_theory();
SML

  local log=$tmpdir/reject.log
  if (cd "$project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" build ATheory.uo) > "$log" 2>&1; then
    echo "object target unexpectedly accepted" >&2
    exit 1
  fi
  grep -q "build targets are logical names" "$log"
}

run_cache_gc() {
  local cache=$tmpdir/cache
  mkdir -p "$cache/tmp/oldtmp" "$cache/blobs" "$cache/actions/live" "$cache/actions/old" "$cache/actions/nomani"
  : > "$cache/blobs/live"
  : > "$cache/blobs/dead"
  printf 'holbuild-cache-action-v1\nblob=live\n' > "$cache/actions/live/manifest"
  printf 'holbuild-cache-action-v1\nblob=old\n' > "$cache/actions/old/manifest"
  touch -d '10 days ago' \
    "$cache/tmp/oldtmp" \
    "$cache/blobs/live" \
    "$cache/blobs/dead" \
    "$cache/actions/old/manifest" \
    "$cache/actions/nomani"

  env -u HOLDIR -u HOLBUILD_HOLDIR HOLBUILD_CACHE="$cache" "$HOLBUILD_BIN" cache gc > "$tmpdir/cache-gc.log"

  [[ -f "$cache/blobs/live" ]] || { echo "referenced blob removed" >&2; exit 1; }
  [[ ! -e "$cache/blobs/dead" ]] || { echo "unreferenced blob survived" >&2; exit 1; }
  [[ ! -e "$cache/actions/old" ]] || { echo "old action survived" >&2; exit 1; }
  [[ ! -e "$cache/actions/nomani" ]] || { echo "stale incomplete action survived" >&2; exit 1; }
  [[ ! -e "$cache/tmp/oldtmp" ]] || { echo "stale tmp survived" >&2; exit 1; }
}

run_basic_theory_build
run_diamond_theory_build
run_object_target_rejection
run_cache_gc

echo "smoke tests passed"
