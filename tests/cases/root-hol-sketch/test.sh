#!/usr/bin/env bash
set -euo pipefail

HOLBUILD_BIN=$1
HOLDIR=$2
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$SCRIPT_DIR/../../.." && pwd)
# shellcheck source=../../lib.sh
source "$SCRIPT_DIR/../../lib.sh"

tmpdir=$(make_temp_dir)
cleanup() { rm -rf "$tmpdir"; }
trap cleanup EXIT
export HOLBUILD_CACHE="$tmpdir/cache"

project=$tmpdir/project
mkdir -p "$project"
cat > "$project/holproject.toml" <<TOML
[project]
name = "root_hol_probe"

[build]
members = []

[dependencies.HOL]
path = "$HOLDIR"
manifest = "$ROOT/examples/root-hol/holproject.toml"
TOML

(cd "$project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" build --dry-run) > "$tmpdir/dry.log"

require_grep "KernelTypes (sml, package HOL)" "$tmpdir/dry.log"
require_grep "boolTheory (theory, package HOL)" "$tmpdir/dry.log"
require_grep "listTheory (theory, package HOL)" "$tmpdir/dry.log"

if grep -Eq 'source: HOL:.*/selftest\.sml|source: HOL:.*/examples/|source: HOL:.*/tests/|source: HOL:.*/theory_tests/|source: HOL:src/emit/MLton/|source: HOL:src/portableML/(mlton|mosml)/|source: HOL:src/tracing/no/|source: HOL:src/num/reduce/conv-old/' "$tmpdir/dry.log"; then
  echo "root-HOL sketch included an excluded source" >&2
  exit 1
fi

(cd "$project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" build KernelTypes) > "$tmpdir/kerneltypes.log"
require_file "$project/.holbuild/deps/HOL/obj/src/0/KernelTypes.uo"
require_file "$project/.holbuild/deps/HOL/obj/src/0/KernelTypes.ui"
base_count=$(find "$project/.holbuild/checkpoints/_base" -name '*.save' | wc -l)
if [[ "$base_count" -lt 1 ]]; then
  echo "root-HOL SML probe did not create a project base checkpoint" >&2
  exit 1
fi
