---
name: holbuild
Build HOL4 projects with holbuild. Use when working with holproject.toml manifests, building theory targets like FooTheory, managing dependencies, configuring proof IR/GoalFrag or checkpoint behavior, using the holbuild CLI, generated source, JSON output, tactic timeouts, cache/gc, or heap exports.
---

# holbuild

Project-aware build frontend for HOL4. Logical targets, not object files.

## Core workflow

```sh
holbuild build FooTheory                 # build a theory target
holbuild build Foo BarTheory             # multiple targets
holbuild build                           # all, or [build].roots closure if configured
holbuild build --dry-run FooTheory       # show plan without building
holbuild context                         # show manifest info
holbuild execution-plan FooTheory:thm    # static proof-IR plan for one theorem
holbuild build --force --goalfrag-trace FooTheory
holbuild gc                              # clean project residue + global cache
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
| `--holdir PATH` | HOL checkout/install; fallback envs: `HOLBUILD_HOLDIR`, `HOLDIR` |
| `--source-dir PATH` | Source tree for manifest discovery; artifacts still under the shell cwd `.holbuild/` |
| `-jN` / `--jobs N` | Parallel workers (default: `.holconfig.toml [build].jobs` or `max(1, nproc/2)`) |
| `--force` | Ignore local up-to-date state and cache restore; still publishes cache unless `--no-cache` |
| `--no-cache` | Skip global cache restore/publish; local up-to-date checks still work |
| `--skip-checkpoints` | No `.save`/`.ok` checkpoint files; theorem instrumentation still runs |
| `--skip-goalfrag` | No theorem instrumentation/proof IR; incompatible with timeout/plan/trace flags |
| `--goalfrag` | Use legacy HOL GoalFrag runtime instead of default proof IR |
| `--tactic-timeout SECONDS` | Root-package per-step timeout (default 2.5s, `0` disables); also manifest/local-config settable |
| `--json` | Newline-delimited JSON build events/errors; not supported for dry-run/plan/repl-on-failure |
| `--verbose` | Node start and per-node elapsed logs in non-TTY output |

## Output layout

All under `.holbuild/`: `gen/` (generated theory files), `obj/` (artifacts), `dep/` (metadata), `checkpoints/` (local replay/debug state), `heap/`, `logs/`, `stage/` (temporary), `locks/`.

## Key constraints

- `use "file"` rejected in project builds — declare a module and `load` it
- Duplicate logical names across packages → error (except same-package `.sig`/`.sml` companion)
- Unknown manifest/local-config fields → error (schema-checked)
- `--tactic-timeout` applies only to root package; dependencies build with no timeout
- Proof engine/checkpoint/timeout/trace flags are execution/debug policy, not final artifact action-key inputs
- Reserved dependency `[dependencies.HOLDIR]` uses holbuild's built-in HOL manifest; no shim needed

## References

- [quickstart.md](references/quickstart.md) — setup, full command/flag reference, theory naming
- [manifest.md](references/manifest.md) — `holproject.toml` schema, source discovery, generators, action policies, HOLSource headers
- [local-config.md](references/local-config.md) — `.holconfig.toml` overrides, excludes, jobs, timeout
- [build-model.md](references/build-model.md) — dependency inference, action keys, invalidation, cache, write locks, gc
- [checkpoints-goalfrag.md](references/checkpoints-goalfrag.md) — proof IR/GoalFrag, checkpoint lifecycle, tactic timeouts, replay, env vars
- [dependencies.md](references/dependencies.md) — declaring deps, built-in HOLDIR, shim manifests, transitive resolution
- [heaps-and-run.md](references/heaps-and-run.md) — `[[heap]]` exports; `run`/`repl` prototype status
