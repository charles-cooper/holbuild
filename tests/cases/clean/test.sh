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

project=$tmpdir/project
cache=$tmpdir/cache
mkdir -p \
  "$project/.holbuild/stage/old-stage" \
  "$project/.holbuild/logs" \
  "$project/.holbuild/checkpoints/pkg/src/theory.deps/key" \
  "$cache/tmp/old" \
  "$cache/actions/old" \
  "$cache/blobs"

cat > "$project/holproject.toml" <<'TOML'
[project]
name = "clean"

[build]
members = []
TOML

printf 'stage residue\n' > "$project/.holbuild/stage/old-stage/file"
printf 'old log\n' > "$project/.holbuild/logs/old.log"
printf 'checkpoint\n' > "$project/.holbuild/checkpoints/pkg/src/theory.deps/key/deps_loaded.save"
printf 'ok\n' > "$project/.holbuild/checkpoints/pkg/src/theory.deps/key/deps_loaded.save.ok"
printf 'meta\n' > "$project/.holbuild/checkpoints/pkg/src/theory.deps/key/deps_loaded.save.meta"
printf 'prefix\n' > "$project/.holbuild/checkpoints/pkg/src/theory.deps/key/deps_loaded.save.prefix"
printf 'tmp\n' > "$cache/tmp/old/file"
printf 'holbuild-cache-action-v1\nblob dat deadbeef\n' > "$cache/actions/old/manifest"
printf 'blob\n' > "$cache/blobs/deadbeef"

clean_log=$tmpdir/clean.log
(cd "$project" && env -u HOLDIR -u HOLBUILD_HOLDIR HOLBUILD_CACHE="$cache" \
  "$HOLBUILD_BIN" clean --retention-days 0 --cache-dir "$cache") > "$clean_log" 2>&1

require_grep "project clean: removed" "$clean_log"
require_grep "cache gc: removed" "$clean_log"
[[ ! -e "$project/.holbuild/stage/old-stage" ]] || { echo "clean left stale stage dir" >&2; exit 1; }
[[ ! -e "$project/.holbuild/logs/old.log" ]] || { echo "clean left stale log" >&2; exit 1; }
if find "$project/.holbuild/checkpoints" -type f -print -quit 2>/dev/null | grep -q .; then
  echo "clean left stale checkpoint artifacts" >&2
  exit 1
fi
[[ ! -e "$cache/tmp/old" ]] || { echo "clean left stale cache tmp" >&2; exit 1; }
[[ ! -e "$cache/actions/old" ]] || { echo "clean left stale cache action" >&2; exit 1; }
[[ ! -e "$cache/blobs/deadbeef" ]] || { echo "clean left stale cache blob" >&2; exit 1; }
