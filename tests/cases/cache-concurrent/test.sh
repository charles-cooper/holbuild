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

make_project() {
  local project=$1
  mkdir -p "$project/src"
  cat > "$project/holproject.toml" <<'TOML'
[project]
name = "concurrent"

[build]
members = ["src"]
TOML
  cat > "$project/src/AScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;

val _ = new_theory "A";
val a_thm = store_thm("a_thm", ``T``, ACCEPT_TAC TRUTH);
val _ = export_theory();
SML
}

run_parallel_builds() {
  local phase=$1
  shift
  local -a pids=()
  local -a logs=()
  local project
  for project in "$@"; do
    local name
    name=$(basename "$project")
    local log="$tmpdir/$phase-$name.log"
    logs+=("$log")
    (cd "$project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" build ATheory) > "$log" 2>&1 &
    pids+=("$!")
  done

  local failed=0
  local i
  for i in "${!pids[@]}"; do
    if ! wait "${pids[$i]}"; then
      failed=1
      cat "${logs[$i]}" >&2
    fi
  done
  if [[ "$failed" -ne 0 ]]; then
    echo "parallel $phase builds failed" >&2
    exit 1
  fi
}

projects=()
for i in 1 2 3 4; do
  project="$tmpdir/project-$i"
  make_project "$project"
  projects+=("$project")
done

run_parallel_builds publish "${projects[@]}"

manifest_count=$(find "$HOLBUILD_CACHE/actions" -mindepth 2 -maxdepth 2 -name manifest | wc -l | tr -d ' ')
[[ "$manifest_count" = "1" ]] || { echo "expected one cache manifest, found $manifest_count" >&2; exit 1; }
if [[ -d "$HOLBUILD_CACHE/locks" ]] && find "$HOLBUILD_CACHE/locks" -mindepth 1 -maxdepth 1 -name 'action-*.lock' | grep -q .; then
  echo "stale action cache lock left behind" >&2
  exit 1
fi

for project in "${projects[@]}"; do
  require_file "$project/.holbuild/obj/src/ATheory.dat"
  rm -rf "$project/.holbuild"
done

run_parallel_builds restore "${projects[@]}"

for project in "${projects[@]}"; do
  name=$(basename "$project")
  require_grep "ATheory restored from cache" "$tmpdir/restore-$name.log"
  require_file "$project/.holbuild/obj/src/ATheory.dat"
done
