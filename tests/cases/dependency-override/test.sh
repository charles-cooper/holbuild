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
val a_thm = store_thm("a_thm", ``T``, ACCEPT_TAC TRUTH);
val _ = export_theory();
SML

cat > "$project/holproject.toml" <<'TOML'
[project]
name = "consumer"

[build]
members = ["src"]

[dependencies.dep]
git = "https://example.invalid/dep.git"
rev = "test"
TOML
cat > "$project/.holconfig.toml" <<TOML
[overrides.dep]
path = "$dep"
TOML
cat > "$project/src/BScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
open ATheory;
val _ = new_theory "B";
val b_thm = store_thm("b_thm", ``T``, ACCEPT_TAC ATheory.a_thm);
val _ = export_theory();
SML

(cd "$project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" build BTheory)

require_file "$project/.holbuild/deps/dep/gen/src/ATheory.sig"
require_file "$project/.holbuild/deps/dep/gen/src/ATheory.sml"
require_file "$project/.holbuild/deps/dep/obj/src/ATheory.dat"
if find "$project/.holbuild/checkpoints/dep" -name '*.save' -print -quit 2>/dev/null | grep -q .; then
  echo "dependency package should not create retained checkpoints by default" >&2
  exit 1
fi
require_file "$project/.holbuild/gen/src/BTheory.sig"
require_file "$project/.holbuild/gen/src/BTheory.sml"
require_file "$project/.holbuild/obj/src/BTheory.dat"

second_log=$tmpdir/second.log
(cd "$project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" build BTheory) > "$second_log"
require_grep "ATheory is up to date" "$second_log"
require_grep "BTheory is up to date" "$second_log"
