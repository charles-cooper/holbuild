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

lock="$project/.holbuild/locks/project.lock"
owner="$lock.owner"
for _ in $(seq 1 100); do
  [[ -f "$lock" && -f "$owner" ]] && break
  sleep 0.05
done
[[ -f "$lock" ]] || { echo "project lock file was not created" >&2; wait "$first_pid" || true; exit 1; }
require_file "$owner"
require_grep "command=build" "$owner"
require_grep "pid=" "$owner"
require_grep "pid_ns=" "$owner"
require_grep "starttime=" "$owner"

second_log=$tmpdir/second.log
if (cd "$project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" build ATheory) > "$second_log" 2>&1; then
  echo "concurrent same-project build unexpectedly succeeded" >&2
  wait "$first_pid" || true
  exit 1
fi
require_grep "project is already being modified" "$second_log"
require_grep "owner: command=build pid=" "$second_log"
if grep -q "holbuild-project-lock-v1" "$second_log"; then
  echo "project lock conflict leaked raw owner file" >&2
  exit 1
fi

locked_bad_project=$tmpdir/locked-bad-project
mkdir -p "$locked_bad_project/.holbuild/locks/project.lock"
cat > "$locked_bad_project/holproject.toml" <<'TOML'
[project]
name = "locked-bad-project"

[build]
members = ["missing"]
TOML
cat > "$locked_bad_project/.holbuild/locks/project.lock/owner" <<TOML
holbuild-project-lock-v1
command=build
pid=$$
cwd=$locked_bad_project
host=$(cat /proc/sys/kernel/hostname)
started=live-lock-test
TOML
locked_bad_log=$tmpdir/locked-bad.log
if (cd "$locked_bad_project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" build) > "$locked_bad_log" 2>&1; then
  echo "locked project with missing member unexpectedly succeeded" >&2
  wait "$first_pid" || true
  exit 1
fi
require_grep "project is already being modified" "$locked_bad_log"
if grep -q "member does not exist" "$locked_bad_log"; then
  echo "locked build discovered sources before checking the project lock" >&2
  wait "$first_pid" || true
  exit 1
fi

wait "$first_pid"
[[ -f "$lock" ]] || { echo "project lock file was removed" >&2; exit 1; }
[[ ! -e "$owner" ]] || { echo "project lock owner survived successful build" >&2; exit 1; }
require_file "$project/.holbuild/obj/src/ATheory.dat"

third_log=$tmpdir/third.log
(cd "$project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" build ATheory) > "$third_log" 2>&1
require_grep "ATheory is up to date" "$third_log"

rm -f "$lock"
mkdir -p "$lock"
cat > "$lock/owner" <<TOML
holbuild-project-lock-v1
command=build
pid=999999999
cwd=$project
host=$(hostname)
started=stale-test
TOML
stale_log=$tmpdir/stale.log
(cd "$project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" build ATheory) > "$stale_log" 2>&1
require_grep "removing stale project lock" "$stale_log"
require_grep "ATheory is up to date" "$stale_log"
[[ -f "$lock" ]] || { echo "stale legacy project lock was not replaced by lock file" >&2; exit 1; }
[[ ! -e "$owner" ]] || { echo "project lock owner survived stale recovery build" >&2; exit 1; }

rm -f "$owner"
missing_owner_log=$tmpdir/missing-owner.log
(cd "$project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" build ATheory) > "$missing_owner_log" 2>&1
require_grep "ATheory is up to date" "$missing_owner_log"
[[ ! -e "$owner" ]] || { echo "project lock owner survived missing-owner recovery build" >&2; exit 1; }

sleep 30 &
unrelated_pid=$!
rm -f "$lock"
mkdir -p "$lock"
cat > "$lock/owner" <<TOML
holbuild-project-lock-v1
command=build
pid=$unrelated_pid
cwd=$project
host=$(hostname)
started=namespace-stale-test
TOML
namespace_stale_log=$tmpdir/namespace-stale.log
(cd "$project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" build ATheory) > "$namespace_stale_log" 2>&1
kill "$unrelated_pid" 2>/dev/null || true
wait "$unrelated_pid" 2>/dev/null || true
require_grep "removing stale project lock" "$namespace_stale_log"
require_grep "ATheory is up to date" "$namespace_stale_log"
[[ -f "$lock" ]] || { echo "namespace-stale legacy project lock was not replaced by lock file" >&2; exit 1; }
