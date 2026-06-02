#!/usr/bin/env bash
set -euo pipefail

HOLBUILD_BIN=$1
HOLDIR=$2
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/../../lib.sh"

tmpdir=$(make_temp_dir)
trap 'rm -rf "$tmpdir"' EXIT
export HOLBUILD_CACHE="$tmpdir/cache"

git_identity() { git -C "$1" config user.email test@example.com; git -C "$1" config user.name 'Holbuild Test'; git -C "$1" config commit.gpgsign false; }
commit_repo() { git -C "$1" add .; git -C "$1" commit -q -m initial; git -C "$1" rev-parse HEAD; }

hol=$tmpdir/hol
mkdir -p "$hol"
git -C "$hol" init -q
git_identity "$hol"
mkdir -p "$hol/bin"
echo '#!/usr/bin/env sh' > "$hol/bin/hol"
echo 'fake hol.state' > "$hol/bin/hol.state"
chmod +x "$hol/bin/hol"
hol_rev=$(commit_repo "$hol")

b=$tmpdir/b
mkdir -p "$b/src"
git -C "$b" init -q
git_identity "$b"
cat > "$b/holproject.toml" <<TOML
[holbuild]
schema = 2

[project]
name = "b"

[build]
members = ["src"]

[dependencies.hol]
git = "$hol"
rev = "$hol_rev"
TOML
cat > "$b/src/Foo.sml" <<'SML'
structure Foo = struct
  val value = true
end
SML
b_rev=$(commit_repo "$b")

a=$tmpdir/a
mkdir -p "$a"
git -C "$a" init -q
git_identity "$a"
cat > "$a/holproject.toml" <<TOML
[holbuild]
schema = 2

[project]
name = "a"

[dependencies.hol]
git = "$hol"
rev = "$hol_rev"

[dependencies.b]
git = "$b"
rev = "$b_rev"
TOML
a_rev=$(commit_repo "$a")

root=$tmpdir/root
mkdir -p "$root"
cat > "$root/holproject.toml" <<TOML
[holbuild]
schema = 2

[project]
name = "root"

[dependencies.a]
git = "$a"
rev = "$a_rev"
TOML

dry_log=$tmpdir/dry.log
(cd "$root" && env -u HOLDIR -u HOLBUILD_HOLDIR "$HOLBUILD_BIN" build --dry-run Foo) > "$dry_log"
require_grep "Foo (sml, package b)" "$dry_log"

if (cd "$root" && "$HOLBUILD_BIN" --holdir "$HOLDIR" build --dry-run Foo) > "$tmpdir/holdir.log" 2>&1; then
  echo "schema 2 build unexpectedly accepted --holdir" >&2
  exit 1
fi
require_grep 'not supported for schema 2 projects' "$tmpdir/holdir.log"

[ -d "$root/.holbuild/src/b/.git" ]
[ ! -d "$root/.holbuild/src/b/.holbuild" ]
[ ! -d "$root/.holbuild/packages/a/.holbuild" ]
[ ! -d "$root/.holbuild/packages/a/.holbuild/src/b" ]
