# holbuild build model

## Dependency inference

holbuild infers source dependencies from the resolved project graph:

1. **Holdep scanning** — `load "X"` / `open X` in source, plus `HOLSource` headers (e.g. `Theory Foo` / `Ancestors Bar`), resolved against the project graph + HOL toolchain `sigobj/`
2. **Action `deps`** — explicit logical dependencies declared in `[actions.*]`
3. **Action `loads`** — explicit loadable module stems; resolved in project DAG first, then HOL toolchain
4. **Companion signatures** — `Foo.sml` implicitly depends on same-package `Foo.sig`

Unresolved `load` directives or `deps` entries → build error.

## Source `use "file"` is rejected

Project build actions cannot use `use "file"`. It's an arbitrary path input outside the resolved package graph. Declare a project module and `load` it instead.

## Build plan

Topological sort of the resolved dependency DAG. Cycle detection with full path reported.

Build order: dependencies loaded first, then dependents. Parallel-ready: `-jN` workers pull from the ready frontier.

## Source kinds & artifacts

| Source | Logical name | Generated | Objects | Data |
|--------|-------------|-----------|---------|------|
| `FooScript.sml` | `FooTheory` | `FooTheory.sig`, `FooTheory.sml` | `FooScript.uo`, `FooTheory.ui`, `FooTheory.uo` | `FooTheory.dat` |
| `Foo.sml` (no sig) | `Foo` | — | `Foo.ui`, `Foo.uo` | — |
| `Foo.sig` | `Foo` | — | `Foo.ui` | — |
| `Foo.sml` + `Foo.sig` | `Foo` (companion pair) | — | `Foo.ui`, `Foo.uo` | — |

All artifact paths are under `.holbuild/`, with `HOLFileSys` remap copies under nested `.hol/objs/`.

## Action keys (invalidation)

Each action has an input key derived from:

```
hash(
  schema version,
  action kind (theory/sml/sig),
  logical target name,
  source package + relative path,
  source content SHA-1,
  dependency input keys (recursively),
  declared action policy (deps, loads, extra_inputs, cache, always_reexecute),
  extra input file hashes,
  toolchain key (hol binary + hol.state hashes)
)
```

**Any source byte change** (including comments/proof edits) changes the action key and cascades to all dependents. This is conservative — v1 does not attempt semantic equivalence of generated outputs.

## Up-to-date check

A node is up-to-date when:
1. All output files exist and are non-empty (for theory scripts)
2. Local metadata `.key` file has matching `input_key`

The check is intentionally cheap — does not recompute dependency-context closures for unchanged nodes.

## Cache

Global cache path: `$HOLBUILD_CACHE` > `$XDG_CACHE_HOME/holbuild` > `~/.cache/holbuild/`

Layout:
```
actions/<action-key>/manifest   # cache manifest (sig/sml-template/dat blob hashes + mldeps)
blobs/<content-hash>            # content-addressed storage
tmp/                            # temporary files
locks/                          # publish + GC locks
```

Cache publish: after a source build, theory artifacts (sig, sml-template, dat) are stored as blobs. The `.sml` is a template with the `.dat` path replaced by a placeholder.

Cache restore: on action-key match, blobs are materialized into local `.holbuild/`, `.sml` template is rebased with local `.dat` path, `HOLFileSys` remap copies are created, `.uo/.ui` load manifests are written.

**A bad cache hit is worse than a missed cache hit.** Validation:
- Action key must match
- All referenced blobs must exist with correct content hashes
- Manifest must have no transient stage paths in mldeps
- On any validation failure: warn, delete local outputs, rebuild from source

`--no-cache` disables both restore and publish but preserves local `.holbuild/` up-to-date checks.

Cache GC: `holbuild cache gc [--retention-days N] [--cache-dir PATH]`. Default 7 days. Removes stale tmp, expired action manifests, unreachable blobs. Serializes with `locks/gc.lock`.

## Build root/dependency tactic timeout

`--tactic-timeout` applies only to the **root package**. Dependency packages build with no tactic timeout. This prevents a consumer's proof-debug timeout from breaking dependency builds.

## Project write lock

`build` and `heap` commands take a coarse project write lock at `.holbuild/locks/project.lock`. Concurrent holbuild processes mutating the same `.holbuild/` are serialized. Stale locks (same host, dead PID) are auto-removed.
