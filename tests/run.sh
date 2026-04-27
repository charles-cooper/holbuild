#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
HOLBUILD_BIN=${HOLBUILD_BIN:-"$ROOT/bin/holbuild"}
HOLDIR=${HOLDIR:-${HOLBUILD_HOLDIR:-}}
HOLBUILD_TEST_JOBS=${HOLBUILD_TEST_JOBS:-1}

if [[ -z "$HOLDIR" ]]; then
  echo "Set HOLDIR=/path/to/HOL or HOLBUILD_HOLDIR" >&2
  exit 2
fi

case "$HOLBUILD_TEST_JOBS" in
  ''|*[!0-9]*) echo "HOLBUILD_TEST_JOBS must be a positive integer" >&2; exit 2 ;;
esac
if [[ "$HOLBUILD_TEST_JOBS" -lt 1 ]]; then
  echo "HOLBUILD_TEST_JOBS must be a positive integer" >&2
  exit 2
fi

log_dir=$(mktemp -d "${TMPDIR:-/tmp}/holbuild-test-logs.XXXXXX")
cleanup() { rm -rf "$log_dir"; }
trap cleanup EXIT

declare -a running_pids=()
declare -a running_names=()
declare -a failed_names=()

run_case() {
  local test_script=$1
  local name=$2
  local log=$log_dir/$name.log

  echo "== $name ==" > "$log"
  if "$test_script" "$HOLBUILD_BIN" "$HOLDIR" >> "$log" 2>&1; then
    echo "PASS $name" >> "$log"
  else
    local status=$?
    echo "FAIL $name (exit $status)" >> "$log"
    return "$status"
  fi
}

start_case() {
  local test_script=$1
  local name=$2
  run_case "$test_script" "$name" &
  running_pids+=("$!")
  running_names+=("$name")
}

remove_running_at() {
  local index=$1
  local last=$((${#running_pids[@]} - 1))
  running_pids[$index]=${running_pids[$last]}
  running_names[$index]=${running_names[$last]}
  unset 'running_pids[$last]'
  unset 'running_names[$last]'
}

wait_one() {
  local pid=${running_pids[0]}
  local name=${running_names[0]}
  if wait "$pid"; then
    cat "$log_dir/$name.log"
  else
    failed_names+=("$name")
    cat "$log_dir/$name.log"
  fi
  remove_running_at 0
}

wait_all() {
  while [[ ${#running_pids[@]} -gt 0 ]]; do
    wait_one
  done
}

for test_script in "$ROOT"/tests/cases/*/test.sh; do
  name=$(basename "$(dirname "$test_script")")
  start_case "$test_script" "$name"
  if [[ ${#running_pids[@]} -ge "$HOLBUILD_TEST_JOBS" ]]; then
    wait_one
  fi
done
wait_all

if [[ ${#failed_names[@]} -gt 0 ]]; then
  echo "failed holbuild tests: ${failed_names[*]}" >&2
  exit 1
fi

echo "all holbuild tests passed"
