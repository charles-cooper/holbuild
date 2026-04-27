#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
HOLBUILD_BIN=${HOLBUILD_BIN:-"$ROOT/bin/holbuild"}
HOLDIR=${HOLDIR:-${HOLBUILD_HOLDIR:-}}

if [[ -z "$HOLDIR" ]]; then
  echo "Set HOLDIR=/path/to/HOL or HOLBUILD_HOLDIR" >&2
  exit 2
fi

for test_script in "$ROOT"/tests/cases/*/test.sh; do
  name=$(basename "$(dirname "$test_script")")
  echo "== $name =="
  "$test_script" "$HOLBUILD_BIN" "$HOLDIR"
done

echo "all holbuild tests passed"
