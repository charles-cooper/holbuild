# A modern, human- and agent-friendly build system for HOL4

`holbuild` is an experimental project-aware build frontend for HOL4.

This repository is an external prototype for the design in HOL issue #1916:
`holproject.toml` as a project manifest, logical build targets, project-level
artifacts, and a future in-tree `hol build` implementation.

## Current scope

This prototype is intentionally small:

- reads and schema-checks the nearest `holproject.toml`
- establishes a shared project context for `build`, `run`, and `repl`
- reuses HOL's existing SML TOML parser from `$HOLDIR/tools/Holmake/toml`
- accepts logical build targets such as `MyTheory`, not object filenames such as `MyTheory.uo`
- owns source discovery and maps outputs to project-level `.holbuild/`
- extracts simple theory dependencies from source text and orders dry-run build plans
- parses transitive dependency manifests and local `.holconfig.toml` path overrides
- materializes dependency plans under project `.holbuild/deps/<package>/`
- rejects duplicate logical theory/module names across the resolved graph, except
  local `.sig`/`.sml` companion pairs
- includes project `load "Module"` SML/SIG dependencies in build plans and internal load manifests
- rejects source-level `use "file"` in project build actions; declare/load project modules instead
- supports per-action policy for explicit extra inputs, cache disabling, and always-rerun actions
- computes prototype source/resolved-dependency input keys for planned actions
- schedules build actions serially by default or in DAG-ready parallel order with `-jN`
- executes simple theory-script builds into project `.holbuild/` without Holmake
- records local action metadata and skips unchanged actions
- publishes/restores simple theory semantic artifacts through the global cache
- includes the explicit HOL base state/toolchain in prototype action keys
- saves local theory checkpoints: dependencies-loaded, AST-derived theorem end-of-proof/context checkpoints for modern theorem declarations, and successor-ready final context
- exports explicit project heap targets from `[[heap]]` entries using local SaveState
- exposes `holbuild cache gc` with a 7-day default global-cache retention policy
- does not delegate build semantics to Holmake
- treats `.uo`/`.ui` as internal ML artifacts, never user-requestable targets
- delegates execution to `$HOLDIR/bin/hol run` / `hol repl` for now

It requires an already-configured HOL checkout or installation.

## Build

```sh
make HOLDIR=/path/to/HOL
make HOLDIR=/path/to/HOL test
HOLBUILD_TEST_JOBS=16 make HOLDIR=/path/to/HOL test
```

Optional install:

```sh
make HOLDIR=/path/to/HOL install
```

This installs only the `holbuild` executable to `$HOME/.local/bin/holbuild` by
default. Override with `PREFIX`, `BINDIR`, or `DESTDIR` if needed. Runtime HOL
selection still uses `--holdir PATH`, `HOLBUILD_HOLDIR`, or `HOLDIR`.

The compiler loads HOL's existing SML TOML parser from `$(HOLDIR)` and embeds it
in `bin/holbuild`. Tests live under `tests/cases/*/test.sh` so they can move into
HOL's selftest layout with minimal reshaping; `tests/run.sh` is the repo-local
runner and can run cases in parallel with `HOLBUILD_TEST_JOBS`. Current cases
cover simple theory builds, package overrides, cross-package SML load
resolution, dependency cycle rejection, conservative invalidation, theorem
checkpoint replay, logical-name conflict rejection, cache
restoration/corruption/concurrency fallback, parallel diamonds, same-project
write locking, explicit heaps, object-target rejection, manifest schema
validation, and cache GC.

## Usage

```sh
export HOLBUILD_HOLDIR=/path/to/HOL
bin/holbuild build MyTheory
bin/holbuild -j4 build MyTheory
```

Useful inspection/maintenance commands:

```sh
bin/holbuild context
bin/holbuild build --dry-run MyTheory
bin/holbuild cache gc
```

Additional prototype commands exist for project-context execution and explicit
heap exports:

```sh
bin/holbuild run someScript.sml
bin/holbuild repl
bin/holbuild heap main
```

`--holdir PATH` can be used instead of `HOLBUILD_HOLDIR` at runtime for HOL
commands. `-jN`, `-j N`, or `--jobs N` controls build parallelism for `build`
and for the build phase of `heap` targets; the default is `-j1`. `cache gc` uses
`$HOLBUILD_CACHE`, `$XDG_CACHE_HOME/holbuild`, or `$HOME/.cache/holbuild` and
does not require a HOL toolchain.

See `DESIGN.md` for the intended long-term model: manifest-based package
resolution, project-local `.holbuild/` materialization, action-key invalidation,
root-HOL migration through an explicit/default HOL manifest, and an optional
global cache that never changes build semantics.

## Example `holproject.toml`

```toml
[holbuild]
schema = 1

[project]
name = "example"
version = "0.1.0"

[build]
members = ["src", "examples"]

[dependencies.foo]
git = "https://github.com/acme/foo"
rev = "abc123"

[actions.MyTheory]
extra_inputs = ["data/table.txt"]
cache = false

[run]
heap = "build/main.heap"
loads = ["MyProjectLib"]

[[heap]]
name = "main"
output = "build/main.heap"
objects = ["MyProjectLib"]
```

## Local dependency overrides

Use an uncommitted `.holconfig.toml` when a declared dependency lives at a
different local path on your machine:

```toml
[overrides.foo]
path = "../foo-dev"
```

The override changes only where the package is found locally. The package still
needs its own `holproject.toml` or an explicit shim manifest from the consumer.
There is no `.holpath`, ambient `HOLPATH`, or user-facing include-path schema in
project mode; dependency locations are resolved through manifests plus local
overrides. Both `holproject.toml` and `.holconfig.toml` reject unknown fields in
recognized tables so typos fail early.

## Notes

The user-facing model should not expose `.uo`, `.ui`, `.dat`, or other HOL
object filenames as targets. `holbuild build MyTheory` is the intended shape.

`holbuild` should produce the same logical artifacts as Holmake (`.uo`, `.ui`,
`.dat`, generated theory files, etc.) while allowing their physical storage to
move under a project-level `.holbuild/` directory. The top-level directory is not
`.hol/` because Holmake/HOL tooling already uses `.hol` conventions. Any
`.hol/objs` directories written by holbuild are nested compatibility remap copies
inside `.holbuild/`, not the project state root. `.uo` and `.ui` files are internal
ML artifacts; users should request logical targets only. The prototype rejects
ambiguous graphs where two sources export the same logical theory/module name;
the intended exception is a same-package `.sig`/`.sml` companion pair. The
prototype also writes auxiliary `HOLFileSys` remap copies under `.hol/objs` for
path-sensitive internal loads while preserving canonical artifacts in the project
layout.

Theory scripts are modeled as pure build actions by default: no user-specified
side effects are part of the default v1 contract. If a real action has declared
non-source inputs or must not be cached/skipped, make that explicit:

```toml
[actions.MyTheory]
extra_inputs = ["data/table.txt"]
cache = false
always_reexecute = true
# impure = true is shorthand for no cache and always re-execute
```

`extra_inputs` are hashed exactly and included in the action key. `cache = false`
disables global-cache restore/publish for that action. `always_reexecute = true`
prevents local up-to-date skipping and checkpoint replay for that action. These
are escape hatches, not ambient include/search paths.

Incremental correctness is action-key based. `holbuild` does not use
`hol buildheap` as its default build primitive; it builds contexts directly by
loading resolved ancestors and saving PolyML checkpoints at syntactic boundaries:
dependencies loaded, AST-derived theorem end-of-proof/context boundaries for
modern `Theorem ... Proof ... QED` declarations, and successor-ready final
context, stored locally under `.holbuild/checkpoints/`. Simple theorem-producing
forms such as `Theorem name = thm` still build normally but are not theorem
checkpoint boundaries in v1. When a script is dirty but a previous theorem-context
prefix still matches exactly, holbuild can replay from that checkpoint instead
of from the dependency-loaded state. Explicit
`holbuild heap NAME` targets build their declared logical objects, load the
generated theory modules, and save the requested heap with PolyML SaveState.

The optional global cache stores simple theory semantic artifacts by action key:
`Theory.sig`, a path-rebased `Theory.sml` template, and `Theory.dat`. On a cache
hit, holbuild materializes those artifacts into local `.holbuild/`, writes local load
manifests, and recreates local checkpoints from the generated theory module.
`holbuild cache gc` removes stale temporary entries, stale action manifests, and
old unreferenced blobs after 7 days by default.

`holbuild run` and `holbuild repl` generate `.holbuild/holbuild-run-context.sml`
in the project root before loading `[run].loads` and user-supplied arguments.

`hol debug` is deliberately out of scope for this prototype.
