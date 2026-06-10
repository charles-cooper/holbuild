#!/usr/bin/env bash
set -euo pipefail

HOLBUILD_BIN=$1
_HOLDIR=$2
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../../lib.sh
source "$SCRIPT_DIR/../../lib.sh"

tmpdir=$(make_temp_dir)
cleanup() { rm -rf "$tmpdir"; }
trap cleanup EXIT
use_case_cache "$tmpdir/cache"

project=$tmpdir/project
mkdir -p "$project/src"
{
  write_schema2_prelude
  cat <<'TOML'
[project]
name = "override_rejected"

[build]
members = ["src"]
TOML
} > "$project/holproject.toml"
cat > "$project/.holconfig.toml" <<'TOML'
[overrides.dep]
path = "../dep"
TOML
cat > "$project/src/AScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
val _ = new_theory "A";
val _ = export_theory();
SML

log=$tmpdir/override.log
if (cd "$project" && "$HOLBUILD_BIN" context) > "$log" 2>&1; then
  echo "local dependency override unexpectedly accepted" >&2
  exit 1
fi
require_grep "local dependency overrides are not supported" "$log"
