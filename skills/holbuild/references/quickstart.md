# holbuild quickstart

## Prerequisites

A HOL4 checkout or installation. Set `HOLDIR` (or `HOLBUILD_HOLDIR`) to point to it.

## Build holbuild

```sh
make HOLDIR=/path/to/HOL
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
holbuild build FooTheory
```

## Core workflow

```sh
holbuild build FooTheory          # build one target
holbuild build Foo BarTheory      # build multiple targets
holbuild build                    # build all (or roots if configured)
holbuild build --dry-run          # show plan without building
holbuild context                  # show manifest info
```

## Build flags

- `-jN` / `--jobs N` — parallel workers. Default: `.holconfig.toml [build].jobs` or `max(1, nproc/2)`
- `--no-cache` — skip global cache restore/publish; local `.holbuild/` up-to-date checks still work
- `--skip-checkpoints` — no `.save` checkpoint files (goalfrag still runs)
- `--skip-goalfrag` — no theorem instrumentation (no checkpoints, no timeouts)
- `--tactic-timeout SECONDS` — per-tactic timeout for root package (default 2.5s, `0` disables)
- `--holdir PATH` — override HOLDIR for this invocation

**Incompatible**: `--skip-goalfrag` + `--tactic-timeout` (timeout requires goalfrag).

## Cache maintenance

```sh
holbuild cache gc                        # default 7-day retention
holbuild cache gc --retention-days 30    # custom retention
```

## Build output layout

```
.holbuild/
  gen/          generated Theory.sig, Theory.sml
  obj/          .uo, .ui, .dat artifacts
  dep/          action metadata (.key files with input_key)
  checkpoints/  transient PolyML .save files (removed after success)
  heap/         exported heaps
  logs/         retained failure logs
  stage/        temporary build staging (removed after success)
  locks/        project write lock
```

Never request `.uo`/`.ui`/`.dat` as build targets — use logical names like `FooTheory`.

## Theory naming convention

`src/FooScript.sml` → logical target `FooTheory`

The `Script.sml` suffix is mandatory for theory scripts. Source discovery automatically ignores existing `*Theory.sml` / `*Theory.sig` in the tree.
