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
use_case_cache "$tmpdir/cache"

project=$tmpdir/project
dep=$tmpdir/lib
mkdir -p "$project/src" "$dep/src"
{
  write_schema2_prelude
  cat <<'TOML'
[project]
name = "lib"

[build]
members = ["src"]
TOML
} > "$dep/holproject.toml"
cat > "$dep/src/Foo.sig" <<'SML'
signature FOO = sig
  val value : bool
end
SML
cat > "$dep/src/Foo.sml" <<'SML'
structure Foo : FOO = struct
  val value = true
end
SML
dep_rev=$(init_git_repo "$dep")
{
  write_schema2_prelude
  cat <<TOML
[project]
name = "app"

[build]
members = ["src"]

[dependencies.lib]
git = "$dep"
rev = "$dep_rev"
TOML
} > "$project/holproject.toml"
cat > "$project/src/Bar.sml" <<'SML'
load "Foo";

structure Bar = struct
  val witness = Foo.value
end
SML
cat > "$project/src/AScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;

load "Bar";
val _ = if Bar.witness then () else raise Fail "dependency module did not load";

val _ = new_theory "A";
val a_thm = store_thm("a_thm", ``T``, ACCEPT_TAC TRUTH);
val _ = export_theory();
SML

dry_log=$tmpdir/dry.log
(cd "$project" && "$HOLBUILD_BIN" build --dry-run ATheory) > "$dry_log"
require_grep "Foo (sig, package lib)" "$dry_log"
require_grep "Foo (sml, package lib)" "$dry_log"
require_grep "Bar (sml, package app)" "$dry_log"
require_grep "ATheory (theory, package app)" "$dry_log"

(cd "$project" && "$HOLBUILD_BIN" build ATheory)
require_file "$project/.holbuild/packages/lib/obj/src/Foo.ui"
require_file "$project/.holbuild/packages/lib/obj/src/Foo.uo"
require_file "$project/.holbuild/obj/src/Bar.uo"
require_file "$project/.holbuild/obj/src/ATheory.dat"
require_grep ".holbuild/packages/lib/obj/src/Foo" "$project/.holbuild/obj/src/Bar.uo"
require_grep ".holbuild/obj/src/Bar" "$project/.holbuild/obj/src/AScript.uo"
if grep -q ".holbuild/obj/src/Bar" "$project/.holbuild/obj/src/ATheory.uo"; then
  echo "source-only cross-package load leaked into generated theory load manifest" >&2
  exit 1
fi

cat > "$tmpdir/load-internal-theory.sml" <<SML
load "$project/.holbuild/obj/src/ATheory";
val _ = ATheory.a_thm;
SML
"$HOLDIR/bin/hol" run --noconfig --holstate "$HOLDIR/bin/hol.state" "$tmpdir/load-internal-theory.sml"

rm -rf "$project/.holbuild"
restore_log=$tmpdir/restore.log
(cd "$project" && "$HOLBUILD_BIN" build ATheory) > "$restore_log"
require_grep "ATheory restored from cache" "$restore_log"
require_grep ".holbuild/packages/lib/obj/src/Foo" "$project/.holbuild/obj/src/Bar.uo"
