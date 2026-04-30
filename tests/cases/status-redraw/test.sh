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
name = "status-redraw"

[build]
members = ["src"]
TOML

cat > "$project/.holconfig.toml" <<'TOML'
[build]
jobs = 3
TOML

cat > "$project/src/AScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
val _ = new_theory "A";
Theorem a_thm:
  T
Proof
  ACCEPT_TAC TRUTH
QED
val _ = export_theory();
SML

status_log=$tmpdir/status.log
(cd "$project" && HOLBUILD_STATUS=1 TERM=xterm COLUMNS=120 "$HOLBUILD_BIN" --holdir "$HOLDIR" build ATheory) > "$status_log" 2>&1
require_file "$project/.holbuild/obj/src/ATheory.dat"
tr '\r' '\n' < "$status_log" > "$tmpdir/status-lines.log"
require_grep "holbuild done=0/1 running=1/3" "$tmpdir/status-lines.log"
require_grep "holbuild done=1/1 running=0/3 built=1 from_cache=0 unchanged=0" "$tmpdir/status-lines.log"

cli_log=$tmpdir/cli.log
(cd "$project" && HOLBUILD_STATUS=1 TERM=xterm COLUMNS=120 "$HOLBUILD_BIN" --holdir "$HOLDIR" -j1 build ATheory) > "$cli_log" 2>&1
tr '\r' '\n' < "$cli_log" > "$tmpdir/cli-lines.log"
require_grep "holbuild done=0/1 running=1/1" "$tmpdir/cli-lines.log"

long_project=$tmpdir/long-project
long_name=LongStatusTargetNameThatShouldNotBeCutOffAtTheOldEightyColumnFallbackTheory
long_script=${long_name%Theory}Script.sml
mkdir -p "$long_project/src"
cp "$project/holproject.toml" "$long_project/holproject.toml"
cat > "$long_project/src/$long_script" <<SML
open HolKernel Parse boolLib bossLib;
val _ = new_theory "${long_name%Theory}";
Theorem long_status_thm:
  T
Proof
  ACCEPT_TAC TRUTH
QED
val _ = export_theory();
SML
long_log=$tmpdir/long.log
(cd "$long_project" && env -u COLUMNS HOLBUILD_STATUS=1 TERM=xterm "$HOLBUILD_BIN" --holdir "$HOLDIR" build "$long_name") > "$long_log" 2>&1
tr '\r' '\n' < "$long_log" > "$tmpdir/long-lines.log"
require_grep "$long_name" "$tmpdir/long-lines.log"
if grep -q "LongStatusTargetNameThatShouldNotBeCutOffAtTheOldEightyColumnFallbackThe\.\.\." "$tmpdir/long-lines.log"; then
  echo "status redraw used old 80-column fallback" >&2
  exit 1
fi

plain_log=$tmpdir/plain.log
(cd "$project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" build ATheory) > "$plain_log" 2>&1
require_grep "ATheory is up to date" "$plain_log"
if grep -q $'\033\\[0K' "$plain_log"; then
  echo "status redraw escaped into non-tty output" >&2
  exit 1
fi

plain_build_project=$tmpdir/plain-build-project
mkdir -p "$plain_build_project/src"
cat > "$plain_build_project/holproject.toml" <<'TOML'
[project]
name = "status-redraw-plain-build"

[build]
members = ["src"]

[actions.BTheory]
cache = false
TOML
cat > "$plain_build_project/src/BScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
val _ = new_theory "B";
Theorem b_thm:
  T
Proof
  ACCEPT_TAC TRUTH
QED
val _ = export_theory();
SML
plain_build_log=$tmpdir/plain-build.log
(cd "$plain_build_project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" build BTheory) > "$plain_build_log" 2>&1
require_grep "BTheory built" "$plain_build_log"
if grep -q $'\033\\[0K' "$plain_build_log"; then
  echo "status redraw escaped into non-tty build output" >&2
  exit 1
fi

message_project=$tmpdir/message-project
mkdir -p "$message_project/src"
cat > "$message_project/holproject.toml" <<'TOML'
[project]
name = "status-redraw-message"

[build]
members = ["src"]

[actions.ATheory]
cache = false
TOML

write_message_bad_source() {
  cat > "$message_project/src/AScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
val _ = new_theory "A";

Theorem first:
  T
Proof
  ACCEPT_TAC TRUTH
QED

Theorem second:
  T
Proof
  FAIL_TAC "expected status checkpoint residue"
QED

val _ = export_theory();
SML
}

write_message_good_source() {
  cat > "$message_project/src/AScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
val _ = new_theory "A";

Theorem first:
  T
Proof
  ACCEPT_TAC TRUTH
QED

Theorem second:
  T
Proof
  ACCEPT_TAC first
QED

val _ = export_theory();
SML
}

write_message_bad_source
if (cd "$message_project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" build ATheory) > "$tmpdir/message-seed.log" 2>&1; then
  echo "expected status message seed build to fail" >&2
  exit 1
fi
require_grep "expected status checkpoint residue" "$tmpdir/message-seed.log"

write_message_good_source
message_log=$tmpdir/message.log
(cd "$message_project" && HOLBUILD_STATUS=1 TERM=xterm COLUMNS=160 "$HOLBUILD_BIN" --holdir "$HOLDIR" build ATheory) > "$message_log" 2>&1
tr '\r' '\n' < "$message_log" > "$tmpdir/message-lines.log"
require_grep "resuming ATheory from checkpoint first" "$tmpdir/message-lines.log"
if grep -q "holbuild .*resuming ATheory from checkpoint" "$tmpdir/message-lines.log"; then
  echo "status redraw line interleaved with ordinary message" >&2
  exit 1
fi
