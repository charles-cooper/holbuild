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
name = "json-output"

[build]
members = ["src"]
TOML

cat > "$project/src/JScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
val _ = new_theory "J";
Theorem j_thm:
  T
Proof
  ACCEPT_TAC TRUTH
QED
val _ = export_theory();
SML

json_log=$tmpdir/json.log
(cd "$project" && "$HOLBUILD_BIN" --json --holdir "$HOLDIR" build JTheory) > "$json_log" 2>&1
require_file "$project/.holbuild/obj/src/JTheory.dat"

python3 - "$json_log" <<'PY'
import json
import sys

path = sys.argv[1]
lines = [line.rstrip('\n') for line in open(path, encoding='utf-8') if line.strip()]
if not lines:
    raise SystemExit('no json output')
events = []
for line in lines:
    if not line.startswith('{'):
        raise SystemExit(f'non-json output: {line!r}')
    events.append(json.loads(line))
if not any(e.get('event') == 'node_finished' and e.get('target') == 'JTheory' and e.get('outcome') == 'built' for e in events):
    raise SystemExit('missing JTheory built node_finished event')
started = [e for e in events if e.get('event') == 'node_started' and e.get('target') == 'JTheory']
finished = [e for e in events if e.get('event') == 'node_finished' and e.get('target') == 'JTheory']
if not started or not finished or started[-1].get('key') != finished[-1].get('key'):
    raise SystemExit('node start/finish keys do not correlate')
for event in started + finished:
    key = event.get('key', '')
    if '\x00' in key or '\\u0000' in key:
        raise SystemExit(f'node key exposes internal NUL-delimited action key: {key!r}')
    if not key.startswith(event.get('target', '') + '#'):
        raise SystemExit(f'node key does not include display target: {key!r}')
    if event.get('package') != 'json-output' or event.get('source') != 'src/JScript.sml':
        raise SystemExit(f'node event lost source metadata: {event!r}')
if not any(e.get('event') == 'build_finished' and isinstance(e.get('elapsed_ms'), int) for e in events):
    raise SystemExit('missing build_finished elapsed event')
if any('\\u0000' in line or '\x1b' in line or '\r' in line for line in lines):
    raise SystemExit('internal keys or status redraw escaped into json output')
PY

if grep -q "JTheory built" "$json_log"; then
  echo "plain status output escaped into json mode" >&2
  exit 1
fi

bad_project=$tmpdir/bad-project
mkdir -p "$bad_project/src"
cp "$project/holproject.toml" "$bad_project/holproject.toml"
cat > "$bad_project/src/BadScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
val _ = new_theory "Bad";
Theorem bad_thm:
  T
Proof
  FAIL_TAC "json failure"
QED
val _ = export_theory();
SML

fail_log=$tmpdir/fail.log
if (cd "$bad_project" && "$HOLBUILD_BIN" --json --holdir "$HOLDIR" build BadTheory) > "$fail_log" 2>&1; then
  echo "expected json failure build to fail" >&2
  exit 1
fi

python3 - "$fail_log" <<'PY'
import json
import sys

path = sys.argv[1]
events = []
for line in open(path, encoding='utf-8'):
    line = line.rstrip('\n')
    if not line:
        continue
    if not line.startswith('{'):
        raise SystemExit(f'non-json failure output: {line!r}')
    events.append(json.loads(line))
errors = [e for e in events if e.get('event') == 'error']
if not errors:
    raise SystemExit('missing structured error event')
message = '\n'.join(e.get('message', '') for e in errors)
if 'failed tactic top input goal:' not in message:
    raise SystemExit('structured error did not include top-goal context')
if 'json failure' not in message:
    raise SystemExit('structured error lost failure detail')
if not any(e.get('log') and e.get('log') in e.get('message', '') for e in errors):
    raise SystemExit('structured error did not expose failure log as separate key')
failed = [e for e in events if e.get('event') == 'node_failed' and e.get('target') == 'BadTheory']
if not failed:
    raise SystemExit('missing node_failed event')
for event in failed:
    if not event.get('log'):
        raise SystemExit(f'node_failed missing log field: {event!r}')
    if event.get('package') != 'json-output' or event.get('source') != 'src/BadScript.sml':
        raise SystemExit(f'node_failed lost source metadata: {event!r}')
    if '\x00' in event.get('key', '') or '\\u0000' in event.get('key', ''):
        raise SystemExit(f'node_failed key exposes internal NUL key: {event!r}')
PY
