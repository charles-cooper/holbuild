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
require_grep "holbuild \[0/1\] active=1" "$tmpdir/status-lines.log"
require_grep "holbuild \[1/1\] active=0 built=1" "$tmpdir/status-lines.log"

plain_log=$tmpdir/plain.log
(cd "$project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" build ATheory) > "$plain_log" 2>&1
require_grep "ATheory is up to date" "$plain_log"
if grep -q $'\033\\[0K' "$plain_log"; then
  echo "status redraw escaped into non-tty output" >&2
  exit 1
fi
