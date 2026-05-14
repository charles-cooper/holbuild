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
nested=$tmpdir/nested
project=$tmpdir/project
shimdir=$tmpdir/shims
mkdir -p "$dep/src" "$nested/src" "$project/src" "$shimdir"

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

cat > "$nested/holproject.toml" <<'TOML'
[project]
name = "nested"

[build]
members = ["src"]
TOML
cat > "$nested/src/CScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
val _ = new_theory "C";
val c_thm = store_thm("c_thm", ``T``, ACCEPT_TAC TRUTH);
val _ = export_theory();
SML

cat > "$shimdir/dep-shim.toml" <<'TOML'
[project]
name = "dep"

[build]
members = ["src"]

[dependencies.nested]
manifest = "$HOLBUILD_TEST_SHIMDIR/nested-shim.toml"
TOML
cat > "$shimdir/nested-shim.toml" <<'TOML'
[project]
name = "nested"

[build]
members = ["src"]
TOML

cat > "$project/holproject.toml" <<'TOML'
[project]
name = "consumer"

[build]
members = ["src"]

[dependencies.dep]
manifest = "${HOLBUILD_TEST_SHIMDIR}/dep-shim.toml"
TOML
cat > "$project/.holconfig.toml" <<'TOML'
[overrides.dep]
path = "$HOLBUILD_TEST_DEP"

[overrides.nested]
path = "${HOLBUILD_TEST_NESTED}"
TOML
export HOLBUILD_TEST_SHIMDIR="$shimdir"
export HOLBUILD_TEST_DEP="$dep"
export HOLBUILD_TEST_NESTED="$nested"
cat > "$project/src/BScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
open ATheory CTheory;
val _ = new_theory "B";
val b_thm = store_thm("b_thm", ``T``, ACCEPT_TAC ATheory.a_thm);
val c_thm = store_thm("c_thm", ``T``, ACCEPT_TAC CTheory.c_thm);
val _ = export_theory();
SML

(cd "$project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" build BTheory)

require_file "$project/.holbuild/deps/dep/gen/src/ATheory.sig"
require_file "$project/.holbuild/deps/dep/gen/src/ATheory.sml"
require_file "$project/.holbuild/deps/dep/obj/src/ATheory.dat"
# checkpoints persist after successful builds for incremental rebuilds
require_file "$project/.holbuild/gen/src/BTheory.sig"
require_file "$project/.holbuild/gen/src/BTheory.sml"
require_file "$project/.holbuild/obj/src/BTheory.dat"

second_log=$tmpdir/second.log
(cd "$project" && "$HOLBUILD_BIN" --verbose --holdir "$HOLDIR" build BTheory) > "$second_log"
require_grep "ATheory is up to date" "$second_log"
require_grep "BTheory is up to date" "$second_log"

masked_dep=$tmpdir/masked-dep
masked_project=$tmpdir/masked-project
mkdir -p "$masked_dep" "$masked_project"
cat > "$masked_dep/holproject.toml" <<'TOML'
[project]
name = "masked"

[build]
members = []
TOML
cat > "$masked_project/holproject.toml" <<'TOML'
[project]
name = "masked_consumer"

[build]
members = []

[dependencies.masked]
path = "$HOLBUILD_TEST_UNSET_MASKED_PATH"
TOML
cat > "$masked_project/.holconfig.toml" <<'TOML'
[overrides.masked]
path = "../masked-dep"
TOML
env -u HOLBUILD_TEST_UNSET_MASKED_PATH \
  "$HOLBUILD_BIN" --source-dir "$masked_project" --holdir "$HOLDIR" context \
  > "$tmpdir/masked-context.log"
require_grep "dependency: masked" "$tmpdir/masked-context.log"
require_grep "local=.*masked-dep" "$tmpdir/masked-context.log"

no_override_project=$tmpdir/no-override-project
mkdir -p "$no_override_project"
cat > "$no_override_project/holproject.toml" <<'TOML'
[project]
name = "no_override_consumer"

[build]
members = []

[dependencies.no_override]
path = "$HOLBUILD_TEST_UNSET_NO_OVERRIDE"
TOML
if env -u HOLBUILD_TEST_UNSET_NO_OVERRIDE \
  "$HOLBUILD_BIN" --source-dir "$no_override_project" --holdir "$HOLDIR" context \
  > "$tmpdir/no-override-context.log" 2>&1; then
  echo "context unexpectedly succeeded with an unset dependency path env var" >&2
  exit 1
fi
require_grep 'dependencies.no_override.path references unset environment variable HOLBUILD_TEST_UNSET_NO_OVERRIDE' "$tmpdir/no-override-context.log"

override_env_project=$tmpdir/override-env-project
mkdir -p "$override_env_project"
cat > "$override_env_project/holproject.toml" <<'TOML'
[project]
name = "override_env_consumer"

[build]
members = []

[dependencies.override_env]
path = "../masked-dep"
TOML
cat > "$override_env_project/.holconfig.toml" <<'TOML'
[overrides.override_env]
path = "$HOLBUILD_TEST_UNSET_OVERRIDE_PATH"
TOML
if env -u HOLBUILD_TEST_UNSET_OVERRIDE_PATH \
  "$HOLBUILD_BIN" --source-dir "$override_env_project" --holdir "$HOLDIR" context \
  > "$tmpdir/override-env-context.log" 2>&1; then
  echo "context unexpectedly succeeded with an unset override path env var" >&2
  exit 1
fi
require_grep 'overrides.override_env.path references unset environment variable HOLBUILD_TEST_UNSET_OVERRIDE_PATH' "$tmpdir/override-env-context.log"

env_dep=$tmpdir/env-dep
env_project=$tmpdir/env-project
mkdir -p "$env_dep" "$env_project"
cat > "$env_dep/holproject.toml" <<'TOML'
[project]
name = "env_dep"

[build]
members = []
TOML
cat > "$env_project/holproject.toml" <<'TOML'
[project]
name = "env_consumer"

[build]
members = []

[dependencies.env_dep]
path = "$HOLBUILD_TEST_ENV_DEP"
TOML
HOLBUILD_TEST_ENV_DEP="$env_dep" \
  "$HOLBUILD_BIN" --source-dir "$env_project" --holdir "$HOLDIR" context \
  > "$tmpdir/env-context.log"
require_grep "dependency: env_dep" "$tmpdir/env-context.log"
require_grep "local=$env_dep" "$tmpdir/env-context.log"

manifest_mask_dep=$tmpdir/manifest-mask-dep
manifest_mask_project=$tmpdir/manifest-mask-project
mkdir -p "$manifest_mask_dep" "$manifest_mask_project"
cat > "$manifest_mask_project/holproject.toml" <<'TOML'
[project]
name = "manifest_mask_consumer"

[build]
members = []

[dependencies.manifest_mask]
path = "$HOLBUILD_TEST_UNSET_MANIFEST_MASK_PATH"
manifest = "$HOLBUILD_TEST_UNSET_MANIFEST_MASK_MANIFEST/shim.toml"
TOML
cat > "$manifest_mask_project/.holconfig.toml" <<'TOML'
[overrides.manifest_mask]
path = "../manifest-mask-dep"
TOML
if env -u HOLBUILD_TEST_UNSET_MANIFEST_MASK_PATH -u HOLBUILD_TEST_UNSET_MANIFEST_MASK_MANIFEST \
  "$HOLBUILD_BIN" --source-dir "$manifest_mask_project" --holdir "$HOLDIR" context \
  > "$tmpdir/manifest-mask-context.log" 2>&1; then
  echo "context unexpectedly succeeded with an unset explicit manifest env var" >&2
  exit 1
fi
require_grep 'dependencies.manifest_mask.manifest references unset environment variable HOLBUILD_TEST_UNSET_MANIFEST_MASK_MANIFEST' "$tmpdir/manifest-mask-context.log"
