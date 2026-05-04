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
counter=$tmpdir/slow-prefix-count.txt
mkdir -p "$project/src"
touch "$counter"
cat > "$project/holproject.toml" <<'TOML'
[project]
name = "new-ir-replay"

[build]
members = ["src"]
TOML
cat > "$project/src/AScript.sml" <<SML
open HolKernel Parse boolLib bossLib;
val _ = new_theory "A";
val slow_prefix_counter = "$counter";
fun bump_counter () =
  let val out = TextIO.openAppend slow_prefix_counter
  in TextIO.output(out, "x"); TextIO.closeOut out end;
fun slow_tac g = (bump_counter(); OS.Process.sleep (Time.fromReal 0.25); ALL_TAC g);
Theorem slow_prefix_failure:
  T
Proof
  slow_tac >> slow_tac >> FAIL_TAC "first suffix failure"
QED
val _ = export_theory();
SML

first_log=$tmpdir/first.log
if (cd "$project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" build --new-ir ATheory) > "$first_log" 2>&1; then
  echo "expected first new-ir proof to fail" >&2
  exit 1
fi
first_count=$(wc -c < "$counter" | tr -d ' ')
[[ "$first_count" = "2" ]] || { echo "expected first run to execute slow prefix twice, got $first_count" >&2; exit 1; }
require_grep "FAIL_TAC \"first suffix failure\"" "$first_log"
require_grep "top goal at failed fragment:" "$first_log"
require_grep "remaining goals at failed fragment: 1" "$first_log"
require_file "$(find "$project/.holbuild/checkpoints" -name '*slow_prefix_failure_failed_prefix.save' -print -quit)"

python3 - <<PY
from pathlib import Path
path = Path("$project/src/AScript.sml")
path.write_text(path.read_text().replace('FAIL_TAC "first suffix failure"', 'FAIL_TAC "edited suffix failure"'))
PY
edited_log=$tmpdir/edited.log
if (cd "$project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" build --new-ir ATheory) > "$edited_log" 2>&1; then
  echo "expected edited suffix new-ir proof to fail" >&2
  exit 1
fi
edited_count=$(wc -c < "$counter" | tr -d ' ')
[[ "$edited_count" = "2" ]] || { echo "new-ir failed-prefix replay reran unchanged slow prefix after suffix edit; count $edited_count" >&2; exit 1; }
require_grep "resuming ATheory from checkpoint slow_prefix_failure failed_prefix" "$edited_log"
require_grep "edited suffix failure" "$edited_log"
require_grep "remaining goals at failed fragment: 1" "$edited_log"

python3 - <<PY
from pathlib import Path
path = Path("$project/src/AScript.sml")
path.write_text(path.read_text().replace('FAIL_TAC "edited suffix failure"', 'ACCEPT_TAC TRUTH'))
PY
fixed_log=$tmpdir/fixed.log
(cd "$project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" build --new-ir ATheory) > "$fixed_log" 2>&1
fixed_count=$(wc -c < "$counter" | tr -d ' ')
[[ "$fixed_count" = "2" ]] || { echo "new-ir failed-prefix replay reran unchanged slow prefix after suffix fix; count $fixed_count" >&2; exit 1; }
require_grep "resuming ATheory from checkpoint slow_prefix_failure failed_prefix" "$fixed_log"
require_grep "ATheory built" "$fixed_log"
require_file "$project/.holbuild/obj/src/ATheory.dat"
