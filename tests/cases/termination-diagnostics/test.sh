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
name = "termination-diagnostics"

[build]
members = ["src"]
TOML
cat > "$project/src/AScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
val _ = new_theory "A";

Definition test_def:
  test n = if n = 0 then 0 else test (n - 1)
Termination
  FAIL_TAC "expected termination failure"
End

val _ = export_theory();
SML

failure_log=$tmpdir/failure.log
if (cd "$project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" build ATheory) > "$failure_log" 2>&1; then
  echo "expected termination proof failure" >&2
  exit 1
fi

require_grep "termination: test_def (line " "$failure_log"
require_grep "proof: line " "$failure_log"
require_grep "source: .*AScript.sml:7:3-42" "$failure_log"
require_grep "termination condition goal:" "$failure_log"
require_grep "WF" "$failure_log"
require_grep "expected termination failure" "$failure_log"
require_grep "instrumented log:" "$failure_log"

success_project=$tmpdir/success-project
mkdir -p "$success_project/src"
cat > "$success_project/holproject.toml" <<'TOML'
[project]
name = "termination-success"

[build]
members = ["src"]
TOML
cat > "$success_project/src/AScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
val _ = new_theory "A";

Definition test_def:
  test n = if n = 0 then 0 else test (n - 1)
Termination
  WF_REL_TAC `measure I` >> simp[]
End

val _ = export_theory();
SML

success_log=$tmpdir/success.log
(cd "$success_project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" build ATheory) > "$success_log" 2>&1
require_grep "ATheory built" "$success_log"
require_file "$success_project/.holbuild/obj/src/AScript.uo"
require_file "$success_project/.holbuild/obj/src/ATheory.uo"
require_file "$success_project/.holbuild/obj/src/ATheory.dat"
