#!/usr/bin/env bash
set -euo pipefail

HOLBUILD_BIN=$1
HOLDIR=$2
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../../lib.sh
source "$SCRIPT_DIR/../../lib.sh"

unused_real_holdir=$HOLDIR

tmpdir=$(make_temp_dir)
cleanup() { rm -rf "$tmpdir"; }
trap cleanup EXIT

fake_holdir=$tmpdir/fake-hol
mkdir -p "$fake_holdir/bin" "$fake_holdir/sigobj" "$fake_holdir/src/ext/.hol/objs"
printf 'fake hol executable\n' > "$fake_holdir/bin/hol"
printf 'fake hol state\n' > "$fake_holdir/bin/hol.state"
chmod +x "$fake_holdir/bin/hol"

cat > "$fake_holdir/src/ext/ExtLib.sml" <<'SML'
val _ = load "ExtDepTheory";
fun ext_value () = 1;
SML
: > "$fake_holdir/src/ext/.hol/objs/ExtLib.uo"
ln -s "$fake_holdir/src/ext/.hol/objs/ExtLib.uo" "$fake_holdir/sigobj/ExtLib.uo"
: > "$fake_holdir/src/ext/.hol/objs/ExtDepTheory.uo"
printf 'ext-dep-cachekey-v1\n' > "$fake_holdir/src/ext/.hol/objs/ExtDepTheory.cachekey"
ln -s "$fake_holdir/src/ext/.hol/objs/ExtDepTheory.uo" "$fake_holdir/sigobj/ExtDepTheory.uo"

project=$tmpdir/project
mkdir -p "$project/src"
cat > "$project/holproject.toml" <<'TOML'
[project]
name = "external-key-test"

[build]
members = ["src"]
TOML
cat > "$project/src/BScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
val _ = load "ExtLib";
val _ = new_theory "B";
val _ = export_theory();
SML

input_key() {
  (cd "$project" && "$HOLBUILD_BIN" --holdir "$fake_holdir" build --dry-run BTheory) |
    awk '/input_key:/ {print $2; exit}'
}

key_v1=$(input_key)
printf 'changed compiled object bytes\n' > "$fake_holdir/src/ext/.hol/objs/ExtLib.uo"
key_after_artifact_change=$(input_key)
if [[ "$key_after_artifact_change" != "$key_v1" ]]; then
  echo "external HOL key should not hash .uo/.ui artifact bytes" >&2
  exit 1
fi

printf 'ext-dep-cachekey-v2\n' > "$fake_holdir/src/ext/.hol/objs/ExtDepTheory.cachekey"
key_after_dep_cachekey_change=$(input_key)
if [[ "$key_after_dep_cachekey_change" == "$key_v1" ]]; then
  echo "external HOL key ignored transitive root-HOL cachekey/source graph" >&2
  exit 1
fi

cat > "$fake_holdir/src/ext/ExtLib.sml" <<'SML'
val _ = load "ExtDepTheory";
fun ext_value () = 2;
SML
key_after_lib_source_change=$(input_key)
if [[ "$key_after_lib_source_change" == "$key_after_dep_cachekey_change" ]]; then
  echo "external HOL key ignored non-bootstrap external library source" >&2
  exit 1
fi
