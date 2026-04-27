# A modern, human- and agent-friendly build system for HOL4

`holbuild` is an experimental project-aware build frontend for HOL4.

This repository is an external prototype for the design in HOL issue #1916:
`holproject.toml` as a project manifest, logical build targets, project-level
artifacts, and a future in-tree `hol build` implementation.

## Current scope

This prototype is intentionally small:

- reads the nearest `holproject.toml`
- establishes a shared project context for `build`, `run`, and `repl`
- reuses HOL's existing SML TOML parser from `$HOLDIR/tools/Holmake/toml`
- accepts logical build targets such as `MyTheory`, not object filenames such as `MyTheory.uo`
- owns source discovery and maps outputs to project-level `.hol/`
- extracts simple theory dependencies from source text and orders dry-run build plans
- parses transitive dependency manifests and local `.holconfig.toml` path overrides
- materializes dependency plans under project `.hol/deps/<package>/`
- computes prototype source/resolved-dependency input keys for planned actions
- schedules build actions serially by default or in DAG-ready parallel order with `-jN`
- executes simple theory-script builds into project `.hol/` without Holmake
- records local action metadata and skips unchanged actions
- publishes/restores simple theory semantic artifacts through the global cache
- includes the explicit HOL base state/toolchain in prototype action keys
- saves local theory checkpoints: dependencies-loaded, theorem end-of-proof, theorem context, and successor-ready final context
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

The compiler loads HOL's existing SML TOML parser from `$(HOLDIR)` and embeds it
in `bin/holbuild`. Tests live under `tests/cases/*/test.sh` so they can move into
HOL's selftest layout with minimal reshaping; `tests/run.sh` is the repo-local
runner and can run cases in parallel with `HOLBUILD_TEST_JOBS`. Current cases
cover simple theory builds, package overrides, conservative invalidation,
theorem checkpoint replay, cache restoration/corruption fallback, parallel
diamonds, explicit heaps, object-target rejection, and cache GC.

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
resolution, project-local `.hol/` materialization, action-key invalidation, and
an optional global cache that never changes build semantics.

## Example `holproject.toml`

```toml
[project]
name = "example"
version = "0.1.0"

[build]
members = ["src", "examples"]

[dependencies.foo]
git = "https://github.com/acme/foo"
rev = "abc123"

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

## Notes

The user-facing model should not expose `.uo`, `.ui`, `.dat`, or other HOL
object filenames as targets. `holbuild build MyTheory` is the intended shape.

`holbuild` should produce the same logical artifacts as Holmake (`.uo`, `.ui`,
`.dat`, generated theory files, etc.) while allowing their physical storage to
move under a project-level `.hol/` directory. `.uo` and `.ui` files are internal
ML artifacts; users should request logical targets only. The prototype may also
write auxiliary path-stable load copies such as `.dat.load` while the generated
HOL theory source is being rebased into the project layout.

Theory scripts are modeled as pure build actions for now: no user-specified side
effects are part of the v1 contract. A future manifest schema may mark selected
files as always re-execute or explicitly impure.

Incremental correctness is action-key based. `holbuild` does not use
`hol buildheap` as its default build primitive; it builds contexts directly by
loading resolved ancestors and saving PolyML checkpoints at syntactic boundaries:
dependencies loaded, theorem end-of-proof boundaries, theorem context boundaries,
and successor-ready final context, stored locally under `.hol/checkpoints/`. When
a script is dirty but a previous theorem-context prefix still matches exactly,
holbuild can replay from that checkpoint instead of from the dependency-loaded state. Explicit
`holbuild heap NAME` targets build their declared logical objects, load the
generated theory modules, and save the requested heap with PolyML SaveState.

The optional global cache stores simple theory semantic artifacts by action key:
`Theory.sig`, a path-rebased `Theory.sml` template, and `Theory.dat`. On a cache
hit, holbuild materializes those artifacts into local `.hol/`, writes local load
manifests, and recreates local checkpoints from the generated theory module.
`holbuild cache gc` removes stale temporary entries, stale action manifests, and
old unreferenced blobs after 7 days by default.

`holbuild run` and `holbuild repl` generate `.hol/holbuild-run-context.sml`
in the project root before loading `[run].loads` and user-supplied arguments.

`hol debug` is deliberately out of scope for this prototype.
