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

cache=$tmpdir/cache
mkdir -p "$cache/tmp/oldtmp" "$cache/blobs" "$cache/actions/live" "$cache/actions/old" "$cache/actions/nomani" "$cache/locks/action-stale.lock"
: > "$cache/blobs/live"
: > "$cache/blobs/dead"
printf 'holbuild-cache-action-v1\nblob sig live\n' > "$cache/actions/live/manifest"
printf 'holbuild-cache-action-v1\nblob=old\n' > "$cache/actions/old/manifest"
touch -d '10 days ago' \
  "$cache/tmp/oldtmp" \
  "$cache/blobs/live" \
  "$cache/blobs/dead" \
  "$cache/actions/old/manifest" \
  "$cache/actions/nomani" \
  "$cache/locks/action-stale.lock"

env -u HOLDIR -u HOLBUILD_HOLDIR HOLBUILD_CACHE="$cache" "$HOLBUILD_BIN" cache gc > "$tmpdir/cache-gc.log"

require_file "$cache/blobs/live"
[[ ! -e "$cache/blobs/dead" ]] || { echo "unreferenced blob survived" >&2; exit 1; }
[[ ! -e "$cache/actions/old" ]] || { echo "old action survived" >&2; exit 1; }
[[ ! -e "$cache/actions/nomani" ]] || { echo "stale incomplete action survived" >&2; exit 1; }
[[ ! -e "$cache/tmp/oldtmp" ]] || { echo "stale tmp survived" >&2; exit 1; }
[[ ! -e "$cache/locks/action-stale.lock" ]] || { echo "stale action lock survived" >&2; exit 1; }
