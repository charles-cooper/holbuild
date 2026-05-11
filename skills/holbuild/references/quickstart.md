# holbuild quickstart

## Prerequisites

A HOL4 checkout or installation. Select it with `--holdir PATH`, `HOLBUILD_HOLDIR`, or `HOLDIR`.

## Build holbuild

```sh
make HOLDIR=/path/to/HOL
make HOLDIR=/path/to/HOL test
```

## Minimal project

```toml
# holproject.toml
[project]
name = "myproject"

[build]
members = ["src"]
```

With `src/FooScript.sml` containing a standard theory script, build with:

```sh
holbuild --holdir /path/to/HOL build FooTheory
```

## Core workflow

```sh
holbuild build FooTheory                 # build one target
holbuild build Foo BarTheory             # build multiple targets
holbuild build                           # build all, or roots if configured
holbuild build --dry-run FooTheory       # show plan without building
holbuild context                         # show manifest info
holbuild execution-plan FooTheory:thm    # static proof-IR plan
holbuild goalfrag-plan FooTheory:thm     # static legacy GoalFrag plan
holbuild build --force --goalfrag-trace FooTheory
holbuild --json build FooTheory          # JSON events/errors for build output
```

## Global flags

- `--holdir PATH` — HOL checkout/install; fallback envs: `HOLBUILD_HOLDIR`, `HOLDIR`
- `--source-dir PATH` — source tree for manifest discovery; `.holbuild/` artifacts are written under the shell cwd
- `--maxheap MB` / `--max-heap MB` — pass Poly/ML max heap to child HOL processes
- `-jN` / `--jobs N` — parallel workers. Default: `.holconfig.toml [build].jobs` or `max(1, nproc/2)`
- `--json` — newline-delimited JSON `message`, `node_started`, `node_finished`, `node_failed`, `build_finished`, and `error` events (build only; not dry-run/plan/repl-on-failure)
- `--verbose` — node start and per-node elapsed logs when the live TTY status line is disabled

## Build flags

- `--force` — ignore local up-to-date state and cache restore so requested nodes execute from source; cache publication still happens unless `--no-cache`
- `--no-cache` — skip global cache restore/publish; local `.holbuild/` up-to-date checks still work
- `--skip-checkpoints` — no `.save`/`.ok` checkpoint files; theorem instrumentation still runs
- `--skip-goalfrag` — no theorem instrumentation/proof IR, hence no tactic timeout/plan/trace support
- `--goalfrag` — use the legacy HOL GoalFrag runtime instead of default proof IR
- `--tactic-timeout SECONDS` — per-step timeout for root package (default 2.5s, `0` disables)
- `--repl-on-failure` — serial build; on theory failure, start `hol repl` from failed-prefix or replay/deps checkpoint (requires checkpoints; no JSON)

**Incompatible**: `--skip-goalfrag` + `--tactic-timeout`/`--goalfrag-plan`/`--goalfrag-trace`; `--json` + dry-run/plan/repl-on-failure.

## Maintenance

```sh
holbuild gc                                      # project clean + global cache GC; default 7-day retention
holbuild gc --retention-days 30                 # custom retention
holbuild gc --max-checkpoints-gb 10             # size cap for project checkpoints
holbuild gc --clean-only                        # project .holbuild residue only
holbuild gc --cache-only --cache-dir /path      # global cache only; no project/HOLDIR needed
holbuild cache gc                               # legacy cache-only form still exists
```

## Build output layout

```
.holbuild/
  gen/          generated Theory.sig, Theory.sml
  obj/          .uo, .ui, .dat artifacts
  dep/          action metadata (.key files with input_key)
  checkpoints/  local PolyML replay/debug checkpoints, budgeted by gc
  heap/         exported heaps
  logs/         retained failure/trace logs
  stage/        temporary build staging
  locks/        project write/gc lock
```

Never request `.uo`/`.ui`/`.dat` as build targets — use logical names like `FooTheory`.

## Theory naming convention

`src/FooScript.sml` → logical target `FooTheory`

The `Script.sml` suffix is mandatory for theory scripts. Source discovery automatically ignores existing `*Theory.sml` / `*Theory.sig` in the tree and skips symlinked directories.
