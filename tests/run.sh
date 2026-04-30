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
declare -a completed_names=()
declare -a completed_durations=()
declare -a failed_names=()

now_ms() { date +%s%3N; }

suite_start_ms=$(now_ms)
echo "running holbuild tests with HOLBUILD_TEST_JOBS=$HOLBUILD_TEST_JOBS"

run_case() {
  local test_script=$1
  local name=$2
  local log=$log_dir/$name.log
  local duration_file=$log_dir/$name.duration
  local start_ms end_ms duration_ms

  start_ms=$(now_ms)
  echo "== $name ==" > "$log"
  if "$test_script" "$HOLBUILD_BIN" "$HOLDIR" >> "$log" 2>&1; then
    end_ms=$(now_ms)
    duration_ms=$((end_ms - start_ms))
    echo "$duration_ms" > "$duration_file"
    echo "PASS $name (${duration_ms} ms)" >> "$log"
  else
    local status=$?
    end_ms=$(now_ms)
    duration_ms=$((end_ms - start_ms))
    echo "$duration_ms" > "$duration_file"
    echo "FAIL $name (exit $status, ${duration_ms} ms)" >> "$log"
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

running_index_for_pid() {
  local pid=$1
  local i
  for i in "${!running_pids[@]}"; do
    if [[ ${running_pids[$i]} == "$pid" ]]; then
      echo "$i"
      return 0
    fi
  done
  echo "unknown completed test pid: $pid" >&2
  exit 2
}

wait_one() {
  local completed_pid
  local status=0
  wait -n -p completed_pid "${running_pids[@]}" || status=$?

  local index
  index=$(running_index_for_pid "$completed_pid")
  local name=${running_names[$index]}
  local duration
  duration=$(cat "$log_dir/$name.duration" 2>/dev/null || echo 0)
  completed_names+=("$name")
  completed_durations+=("$duration")
  if [[ $status -ne 0 ]]; then
    failed_names+=("$name")
  fi
  cat "$log_dir/$name.log"
  remove_running_at "$index"
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

print_timing_summary() {
  local suite_end_ms total_ms i
  suite_end_ms=$(now_ms)
  total_ms=$((suite_end_ms - suite_start_ms))
  echo "holbuild test timing summary (total ${total_ms} ms):"
  for i in "${!completed_names[@]}"; do
    printf '%8d ms %s\n' "${completed_durations[$i]}" "${completed_names[$i]}"
  done | sort -nr | head -10
}

print_timing_summary

if [[ ${#failed_names[@]} -gt 0 ]]; then
  echo "failed holbuild tests: ${failed_names[*]}" >&2
  exit 1
fi

echo "all holbuild tests passed"
