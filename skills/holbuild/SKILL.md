---
name: holbuild
Build HOL4 projects with holbuild. Use when working with holproject.toml manifests, building theory targets like FooTheory, managing dependencies, configuring goalfrag or checkpoint behavior, using the holbuild CLI, or questions about holbuild cache, action policies, tactic timeouts, or heap exports.
---

# holbuild

Project-aware build frontend for HOL4. Logical targets, not object files.

## Core workflow

```sh
holbuild build FooTheory          # build a theory target
holbuild build Foo BarTheory      # multiple targets
holbuild build                    # all (or roots if configured)
holbuild build --dry-run          # show plan without building
holbuild context                  # show manifest info
holbuild cache gc                 # clean cache (7-day default)
```

Never request `.uo`/`.ui`/`.dat` — use logical names like `FooTheory`.

## Minimal project

```toml
[project]
name = "myproject"

[build]
members = ["src"]
```

`src/FooScript.sml` → target `FooTheory`. `Script.sml` suffix is mandatory for theory scripts.

## Key flags

| Flag | Effect |
|------|--------|
| `-jN` | Parallel workers (default: `.holconfig.toml [build].jobs` or `max(1, nproc/2)`) |
| `--no-cache` | Skip global cache restore/publish |
| `--skip-checkpoints` | No `.save` files (goalfrag still runs) |
| `--skip-goalfrag` | No theorem instrumentation (incompatible with `--tactic-timeout`) |
| `--tactic-timeout SECONDS` | Root-package per-tactic timeout (default 2.5s, `0` disables). Also settable via `tactic_timeout` in manifest or `.holconfig`. |

## Output layout

All under `.holbuild/`: `gen/` (generated theory files), `obj/` (artifacts), `dep/` (metadata), `checkpoints/` (transient, removed on success), `heap/`, `logs/`, `stage/` (temporary), `locks/`.

## Key constraints

- `use "file"` rejected in project builds — declare a module and `load` it
- Duplicate logical names across packages → error (except same-package `.sig`/`.sml` companion)
- Unknown manifest fields → error (schema-checked)
- `--tactic-timeout` applies only to root package; dependencies build with no timeout

## References

- [quickstart.md](references/quickstart.md) — setup, full command/flag reference, theory naming
- [manifest.md](references/manifest.md) — `holproject.toml` schema, source discovery, action policies, HOLSource headers
- [local-config.md](references/local-config.md) — `.holconfig.toml` overrides, excludes, jobs
- [build-model.md](references/build-model.md) — dependency inference, action keys, invalidation, cache, write locks
- [checkpoints-goalfrag.md](references/checkpoints-goalfrag.md) — goalfrag pipeline, checkpoint lifecycle, tactic timeouts, replay, env vars
- [dependencies.md](references/dependencies.md) — declaring deps, shim manifests, transitive resolution
- [heaps-and-run.md](references/heaps-and-run.md) — `[[heap]]` exports; `run`/`repl` prototype status
