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

project=$tmpdir/project
mkdir -p "$project/src"
cat > "$project/holproject.toml" <<'TOML'
[project]
name = "checkpointinvalid"

[build]
members = ["src"]
TOML
cat > "$project/src/AScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
val _ = new_theory "A";

Theorem first:
  T
Proof
  ACCEPT_TAC TRUTH
QED

val _ = export_theory();
SML

(cd "$project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" build ATheory)

metadata="$project/.holbuild/dep/checkpointinvalid/src/AScript.sml.key"
require_file "$metadata"
old_input_key=$(grep '^input_key=' "$metadata")
require_grep '^dependency_context_key=' "$metadata"
if find "$project/.holbuild/checkpoints" \( -name '*.save' -o -name '*.save.ok' \) -print -quit 2>/dev/null | grep -q .; then
  echo "successful build retained checkpoint files" >&2
  exit 1
fi

context_path="$project/.holbuild/checkpoints/checkpointinvalid/src/AScript.sml.first_context.save"
end_path="$project/.holbuild/checkpoints/checkpointinvalid/src/AScript.sml.first_end_of_proof.save"
mkdir -p "$(dirname "$context_path")"
printf 'not a valid PolyML checkpoint\n' > "$context_path"
printf 'holbuild-checkpoint-ok-v1\n' > "$context_path.ok"
printf 'not a valid PolyML checkpoint\n' > "$end_path"
printf 'holbuild-checkpoint-ok-v1\n' > "$end_path.ok"

prefix_hash=$(python3 - <<PY
from pathlib import Path
src = Path("$project/src/AScript.sml").read_text()
end = src.index("QED") + len("QED")
Path("$tmpdir/prefix").write_text(src[:end])
PY
sha1sum "$tmpdir/prefix" | awk '{print $1}')
printf 'theorem_boundary first %s %s %s\n' "$prefix_hash" "$context_path" "$end_path" >> "$metadata"

printf '\n(* source edit after first theorem invalidates the action key but not the theorem prefix *)\n' >> "$project/src/AScript.sml"

rebuild_log=$tmpdir/rebuild.log
(cd "$project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" build ATheory) > "$rebuild_log" 2>&1
new_input_key=$(grep '^input_key=' "$metadata")
[[ "$old_input_key" != "$new_input_key" ]] || { echo "source edit did not change input key" >&2; exit 1; }
if grep -q "from: theorem-context checkpoint after first\|goalfrag/checkpoint run failed" "$rebuild_log"; then
  echo "invalidated action reused stale theorem checkpoint" >&2
  exit 1
fi
if find "$project/.holbuild/checkpoints" \( -name '*.save' -o -name '*.save.ok' \) -print -quit 2>/dev/null | grep -q .; then
  echo "invalidated rebuild retained stale checkpoint files" >&2
  exit 1
fi

mkdir -p "$(dirname "$context_path")"
printf 'stale checkpoint before cache restore\n' > "$context_path"
printf 'holbuild-checkpoint-ok-v1\n' > "$context_path.ok"
rm -rf "$project/.holbuild/gen" "$project/.holbuild/obj" "$project/.holbuild/dep"
cache_restore_log=$tmpdir/cache-restore.log
(cd "$project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" build ATheory) > "$cache_restore_log" 2>&1
require_file "$project/.holbuild/obj/src/ATheory.dat"
if find "$project/.holbuild/checkpoints" \( -name '*.save' -o -name '*.save.ok' \) -print -quit 2>/dev/null | grep -q .; then
  echo "cache restore retained stale checkpoint files" >&2
  exit 1
fi
