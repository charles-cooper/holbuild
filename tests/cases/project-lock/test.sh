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
name = "projectlock"

[build]
members = ["src"]
TOML
cat > "$project/src/AScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;

val _ = OS.Process.sleep (Time.fromSeconds 3);

val _ = new_theory "A";
val a_thm = store_thm("a_thm", ``T``, ACCEPT_TAC TRUTH);
val _ = export_theory();
SML

first_log=$tmpdir/first.log
(cd "$project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" build ATheory) > "$first_log" 2>&1 &
first_pid=$!

lock="$project/.hol/locks/project.lock"
for _ in $(seq 1 100); do
  [[ -d "$lock" ]] && break
  sleep 0.05
done
[[ -d "$lock" ]] || { echo "project lock was not acquired" >&2; wait "$first_pid" || true; exit 1; }
require_file "$lock/owner"
require_grep "command=build" "$lock/owner"

second_log=$tmpdir/second.log
if (cd "$project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" build ATheory) > "$second_log" 2>&1; then
  echo "concurrent same-project build unexpectedly succeeded" >&2
  wait "$first_pid" || true
  exit 1
fi
require_grep "project is already being modified" "$second_log"
require_grep "holbuild-project-lock-v1" "$second_log"

wait "$first_pid"
[[ ! -e "$lock" ]] || { echo "project lock survived successful build" >&2; exit 1; }
require_file "$project/.hol/obj/src/ATheory.dat"

third_log=$tmpdir/third.log
(cd "$project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" build ATheory) > "$third_log" 2>&1
require_grep "ATheory is up to date" "$third_log"
