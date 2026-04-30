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

dep=$tmpdir/dep
project=$tmpdir/project
mkdir -p "$dep/src" "$project/src"

cat > "$dep/holproject.toml" <<'TOML'
[project]
name = "dep"

[build]
members = ["src"]
TOML
cat > "$dep/src/AScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
val _ = new_theory "A";
fun slow_tac g = (OS.Process.sleep (Time.fromReal 0.5); ACCEPT_TAC TRUTH g);
Theorem dep_slow_thm:
  T
Proof
  slow_tac
QED
val _ = export_theory();
SML

cat > "$project/holproject.toml" <<'TOML'
[project]
name = "consumer"

[build]
members = ["src"]

[dependencies.dep]
path = "../dep"
TOML
cat > "$project/src/BScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
open ATheory;
val _ = new_theory "B";
Theorem root_fast_thm:
  T
Proof
  ACCEPT_TAC ATheory.dep_slow_thm
QED
val _ = export_theory();
SML

build_log=$tmpdir/build.log
(cd "$project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" build --tactic-timeout 0.1 BTheory) > "$build_log" 2>&1
require_file "$project/.holbuild/deps/dep/obj/src/ATheory.dat"
require_file "$project/.holbuild/obj/src/BTheory.dat"
require_grep "tactic_timeout=none" "$project/.holbuild/dep/dep/src/AScript.sml.key"
require_grep "tactic_timeout=0.1" "$project/.holbuild/dep/consumer/src/BScript.sml.key"
if grep -q "tactic timed out while building ATheory" "$build_log"; then
  echo "dependency package used root tactic timeout" >&2
  exit 1
fi

changed_root_timeout_log=$tmpdir/changed-root-timeout.log
(cd "$project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" build --tactic-timeout 0.2 BTheory) > "$changed_root_timeout_log" 2>&1
require_grep "ATheory is up to date" "$changed_root_timeout_log"
require_grep "tactic_timeout=none" "$project/.holbuild/dep/dep/src/AScript.sml.key"
require_grep "tactic_timeout=0.2" "$project/.holbuild/dep/consumer/src/BScript.sml.key"

root_timeout_project=$tmpdir/root-timeout
mkdir -p "$root_timeout_project/src"
cat > "$root_timeout_project/holproject.toml" <<'TOML'
[project]
name = "root-timeout"

[build]
members = ["src"]
TOML
cat > "$root_timeout_project/src/AScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
val _ = new_theory "A";
fun slow_tac g = (OS.Process.sleep (Time.fromReal 0.5); ACCEPT_TAC TRUTH g);
Theorem root_slow_thm:
  T
Proof
  slow_tac
QED
val _ = export_theory();
SML

root_timeout_log=$tmpdir/root-timeout.log
if (cd "$root_timeout_project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" build --tactic-timeout 0.1 ATheory) > "$root_timeout_log" 2>&1; then
  echo "expected root project tactic to time out" >&2
  exit 1
fi
require_grep "tactic timed out while building ATheory" "$root_timeout_log"

root_default_project=$tmpdir/root-default
mkdir -p "$root_default_project/src"
cp "$root_timeout_project/holproject.toml" "$root_default_project/holproject.toml"
cp "$root_timeout_project/src/AScript.sml" "$root_default_project/src/AScript.sml"
(cd "$root_default_project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" build ATheory) > "$tmpdir/root-default.log" 2>&1
require_file "$root_default_project/.holbuild/obj/src/ATheory.dat"
require_grep "tactic_timeout=2.5" "$root_default_project/.holbuild/dep/root-timeout/src/AScript.sml.key"
