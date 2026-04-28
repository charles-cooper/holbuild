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

make_theory_project() {
  local project=$1
  local action_stanza=$2
  mkdir -p "$project/src"
  cat > "$project/holproject.toml" <<TOML
[project]
name = "$(basename "$project")"

[build]
members = ["src"]

$action_stanza
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
}

metadata_key() {
  grep '^input_key=' "$1/.holbuild/dep/$(basename "$1")/src/AScript.sml.key" | cut -d= -f2
}

extra_project="$tmpdir/extra_policy"
make_theory_project "$extra_project" '[actions.ATheory]
extra_inputs = ["extra.txt"]'
echo one > "$extra_project/extra.txt"
(cd "$extra_project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" build ATheory) > "$tmpdir/extra1.log" 2>&1
key1=$(metadata_key "$extra_project")
(cd "$extra_project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" build ATheory) > "$tmpdir/extra2.log" 2>&1
require_grep "ATheory is up to date" "$tmpdir/extra2.log"
echo two > "$extra_project/extra.txt"
(cd "$extra_project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" build ATheory) > "$tmpdir/extra3.log" 2>&1
key2=$(metadata_key "$extra_project")
if [[ "$key1" == "$key2" ]]; then
  echo "extra input edit did not change action key" >&2
  exit 1
fi
if grep -q "ATheory is up to date" "$tmpdir/extra3.log"; then
  echo "extra input edit was incorrectly treated as up to date" >&2
  exit 1
fi
require_grep "extra_input=extra.txt@" "$extra_project/.holbuild/dep/extra_policy/src/AScript.sml.key"

always_project="$tmpdir/always_policy"
make_theory_project "$always_project" '[actions.ATheory]
always_reexecute = true'
(cd "$always_project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" build ATheory) > "$tmpdir/always1.log" 2>&1
(cd "$always_project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" build ATheory) > "$tmpdir/always2.log" 2>&1
if grep -q "ATheory is up to date" "$tmpdir/always2.log"; then
  echo "always_reexecute action was skipped" >&2
  exit 1
fi
require_grep "Created theory \"A\"" "$tmpdir/always2.log"

no_cache_project="$tmpdir/no_cache_policy"
make_theory_project "$no_cache_project" '[actions.ATheory]
cache = false'
(cd "$no_cache_project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" build ATheory) > "$tmpdir/no_cache1.log" 2>&1
rm -rf "$no_cache_project/.holbuild"
(cd "$no_cache_project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" build ATheory) > "$tmpdir/no_cache2.log" 2>&1
if grep -q "restored from cache" "$tmpdir/no_cache2.log"; then
  echo "cache=false action restored from cache" >&2
  exit 1
fi
require_grep "Created theory \"A\"" "$tmpdir/no_cache2.log"

unknown_project="$tmpdir/unknown_policy"
make_theory_project "$unknown_project" '[actions.MissingTheory]
cache = false'
if (cd "$unknown_project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" build ATheory) > "$tmpdir/unknown.log" 2>&1; then
  echo "unknown action policy target was accepted" >&2
  exit 1
fi
require_grep "action policy references unknown target unknown_policy:MissingTheory" "$tmpdir/unknown.log"

missing_dep_project="$tmpdir/missing_declared_dep"
make_theory_project "$missing_dep_project" '[actions.ATheory]
deps = ["Missing"]'
if (cd "$missing_dep_project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" build ATheory) > "$tmpdir/missing-dep.log" 2>&1; then
  echo "unresolved action dependency was accepted" >&2
  exit 1
fi
require_grep "unresolved action dependency Missing" "$tmpdir/missing-dep.log"
