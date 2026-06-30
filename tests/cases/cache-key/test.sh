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
mkdir -p "$project/src" "$project/data"
cat > "$project/holproject.toml" <<TOML
$(write_schema2_prelude)
[project]
name = "cache-key-test"

[build]
members = ["src"]
roots = ["src/AScript.sml"]

[[generate]]
name = "copy"
command = ["sh", "-c", "cp data/in.txt src/Generated.sml"]
inputs = ["data/in.txt"]
outputs = ["src/Generated.sml"]
TOML
cat > "$project/data/in.txt" <<'EOF'
val generated_value = 1;
EOF
cat > "$project/src/AScript.sml" <<'SML'
Theory A
Ancestors bool

Theorem a_thm:
  T
Proof
  simp[]
QED
SML
cat > "$project/src/BScript.sml" <<'SML'
Theory B
Ancestors bool

Theorem b_thm:
  T
Proof
  simp[]
QED
SML

key_json() {
  (cd "$project" && "$HOLBUILD_BIN" --json cache-key ATheory)
}

build_key_from_json() {
  python3 -c 'import json,sys; print(json.load(sys.stdin)["build_key"])'
}

components_from_json() {
  python3 -c 'import json,sys; print("\n".join(json.load(sys.stdin)["components"]))'
}

first_json=$tmpdir/first.json
key_json > "$first_json"
first_key=$(build_key_from_json < "$first_json")
components_from_json < "$first_json" > "$tmpdir/components.txt"
require_grep "generate=cache-key-test:copy@" "$tmpdir/components.txt"
require_grep "source=cache-key-test:ATheory:src/AScript.sml@" "$tmpdir/components.txt"
if grep -q "BTheory" "$tmpdir/components.txt"; then
  echo "cache-key for ATheory unexpectedly included unrelated BTheory source" >&2
  cat "$tmpdir/components.txt" >&2
  exit 1
fi
if [[ -e "$project/src/Generated.sml" ]]; then
  echo "cache-key unexpectedly ran generator" >&2
  exit 1
fi

cat >> "$project/holproject.toml" <<'TOML'
# unrelated comment should not affect the semantic cache key
TOML
comment_key=$(key_json | build_key_from_json)
if [[ "$comment_key" != "$first_key" ]]; then
  echo "cache-key changed after manifest comment" >&2
  exit 1
fi

cat > "$project/src/BScript.sml" <<'SML'
Theory B
Ancestors bool

Theorem b_thm:
  T
Proof
  simp[]
QED

Theorem b_thm2:
  T
Proof
  simp[]
QED
SML
b_edit_key=$(key_json | build_key_from_json)
if [[ "$b_edit_key" != "$first_key" ]]; then
  echo "cache-key for ATheory changed after unrelated BTheory edit" >&2
  exit 1
fi

cat > "$project/data/in.txt" <<'EOF'
val generated_value = 2;
EOF
changed_key=$(key_json | build_key_from_json)
if [[ "$changed_key" == "$first_key" ]]; then
  echo "cache-key did not change after generator input edit" >&2
  exit 1
fi
