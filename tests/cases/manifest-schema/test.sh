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
  local name=$1
  mkdir -p "$tmpdir/$name/src"
}

expect_context_failure() {
  local project=$1
  local pattern=$2
  local log=$tmpdir/$project.log
  if (cd "$tmpdir/$project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" context) > "$log" 2>&1; then
    echo "manifest unexpectedly accepted: $project" >&2
    exit 1
  fi
  require_grep "$pattern" "$log"
}

make_project valid
cat > "$tmpdir/valid/holproject.toml" <<'TOML'
[holbuild]
schema = 1

[project]
name = "valid"

[build]
members = ["src"]
TOML
(cd "$tmpdir/valid" && "$HOLBUILD_BIN" --holdir "$HOLDIR" context) > "$tmpdir/valid.log"
require_grep "name: valid" "$tmpdir/valid.log"

make_project bad_schema
cat > "$tmpdir/bad_schema/holproject.toml" <<'TOML'
[holbuild]
schema = 2

[project]
name = "bad_schema"
TOML
expect_context_failure bad_schema "unsupported holproject schema: 2"

make_project unknown_top
cat > "$tmpdir/unknown_top/holproject.toml" <<'TOML'
[project]
name = "unknown_top"

[mystery]
value = "nope"
TOML
expect_context_failure unknown_top "unknown field in holproject.toml: mystery"

make_project typo_build
cat > "$tmpdir/typo_build/holproject.toml" <<'TOML'
[project]
name = "typo_build"

[build]
member = ["src"]
TOML
expect_context_failure typo_build "unknown field in build: member"

make_project bad_exclude_type
cat > "$tmpdir/bad_exclude_type/holproject.toml" <<'TOML'
[project]
name = "bad_exclude_type"

[build]
exclude = "selftest.sml"
TOML
expect_context_failure bad_exclude_type "exclude must be a string array"

make_project no_paths_includes
cat > "$tmpdir/no_paths_includes/holproject.toml" <<'TOML'
[project]
name = "no_paths_includes"

[paths]
includes = ["src"]
TOML
expect_context_failure no_paths_includes "unknown field in holproject.toml: paths"

make_project bad_type
cat > "$tmpdir/bad_type/holproject.toml" <<'TOML'
[project]
name = 123
TOML
expect_context_failure bad_type "name must be a string"

make_project bad_dependency
cat > "$tmpdir/bad_dependency/holproject.toml" <<'TOML'
[project]
name = "bad_dependency"

[dependencies.dep]
path = "../dep"
branch = "main"
TOML
expect_context_failure bad_dependency "unknown field in dependencies.dep: branch"

make_project bad_action_field
cat > "$tmpdir/bad_action_field/holproject.toml" <<'TOML'
[project]
name = "bad_action_field"

[actions.FooTheory]
extra_input = ["foo.dat"]
TOML
expect_context_failure bad_action_field "unknown field in actions.FooTheory: extra_input"

make_project bad_action_type
cat > "$tmpdir/bad_action_type/holproject.toml" <<'TOML'
[project]
name = "bad_action_type"

[actions.FooTheory]
cache = "no"
TOML
expect_context_failure bad_action_type "cache must be a boolean"

make_project bad_action_abs_input
cat > "$tmpdir/bad_action_abs_input/holproject.toml" <<'TOML'
[project]
name = "bad_action_abs_input"

[actions.FooTheory]
extra_inputs = ["/tmp/generated.dat"]
TOML
expect_context_failure bad_action_abs_input "extra_inputs must be package-root-relative"

make_project bad_config
cat > "$tmpdir/bad_config/holproject.toml" <<'TOML'
[project]
name = "bad_config"
TOML
cat > "$tmpdir/bad_config/.holconfig.toml" <<'TOML'
[overrides.dep]
path = "../dep"
branch = "main"
TOML
expect_context_failure bad_config "unknown field in overrides.dep: branch"
