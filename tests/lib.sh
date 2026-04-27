#!/usr/bin/env bash

require_file() {
  local path=$1
  [[ -f "$path" ]] || { echo "missing expected file: $path" >&2; exit 1; }
}

require_grep() {
  local pattern=$1
  local path=$2
  grep -q "$pattern" "$path" || {
    echo "missing expected pattern '$pattern' in $path" >&2
    exit 1
  }
}

make_temp_dir() {
  mktemp -d "${TMPDIR:-/tmp}/holbuild-test.XXXXXX"
}
