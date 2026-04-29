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
name = "parallel_subprocesses"

[build]
members = ["src"]
TOML

child_log=$project/child.log
: > "$child_log"
for i in 1 2 3 4 5 6; do
  cat > "$project/src/T${i}Script.sml" <<SML
open HolKernel Parse boolLib bossLib;
fun append msg =
  let val out = TextIO.openAppend "$child_log"
  in TextIO.output(out, msg ^ "\\n"); TextIO.closeOut out end;
val _ = append "START T${i}";
val _ = OS.Process.system "sleep 2";
val _ = append "END T${i}";
val _ = new_theory "T${i}";
val t${i}_thm = store_thm("t${i}_thm", ``T``, ACCEPT_TAC TRUTH);
val _ = export_theory();
SML
done

(cd "$project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" -j3 build --skip-checkpoints --skip-goalfrag) > "$tmpdir/build.log"

start_before_first_end=$(awk '
  /^END / { print starts; exit }
  /^START / { starts++ }
' "$child_log")
if [[ "$start_before_first_end" -lt 3 ]]; then
  echo "expected at least 3 subprocesses to start before the first finished" >&2
  echo "child log:" >&2
  cat "$child_log" >&2
  exit 1
fi

for i in 1 2 3 4 5 6; do
  require_grep "START T${i}" "$child_log"
  require_grep "END T${i}" "$child_log"
  require_file "$project/.holbuild/obj/src/T${i}Theory.dat"
done
