# holbuild design

`holbuild` is a project-level build model for HOL4. The goal is to make HOL
projects understandable to humans and agents: explicit manifests, logical
targets, deterministic dependency resolution, hidden implementation artifacts,
and cacheable builds that never require users to reason about the cache.

## Principles

- Build targets are logical names, not files: `FooTheory`, not `FooTheory.uo`.
- `.uo` and `.ui` are internal ML load artifacts. Users must never request them.
- Project mode is manifest based. `Holmakefile` semantics are not interpreted.
- The source tree is user-owned; build products live under project `.hol/`.
- The cache is an optional accelerator. Local `.hol/` is the authoritative
  materialized build view.
- When unsure, rebuild. A bad cache hit is worse than a missed cache hit.

## Packages and manifests

Every package in the resolved graph has a manifest. A source file can enter the
build graph only through a declared package root.

Package roots are declared by one of:

- the current project's `holproject.toml`
- a dependency's own `holproject.toml`
- an explicit shim manifest supplied by the consumer
- the built-in/root HOL manifest

Transition rule:

```text
if dependency X has no holproject.toml, the consumer must provide a shim manifest
until X adopts one
```

This keeps resolution explicit without requiring `holbuild` to understand every
legacy `Holmakefile`.

## Root HOL

Root HOL should be built through holbuild's own model, using an in-tree or
default HOL manifest. HOL is not permanently treated as an opaque legacy build.
The prototype still requires an already configured `HOLDIR` so it can reuse HOL
implementation pieces while the model is incubated.

## Source model

Standard theory convention:

```text
src/FooScript.sml -> FooTheory
```

A theory target owns the logical artifacts:

```text
.hol/gen/src/FooTheory.sml
.hol/gen/src/FooTheory.sig
.hol/obj/src/FooTheory.dat
.hol/obj/src/FooTheory.uo
.hol/obj/src/FooTheory.ui
```

Theory scripts are modeled as pure build actions in v1: no user-specified side
effects are part of the contract. Future manifests may add explicit escape
hatches such as `always_reexecute`, `extra_inputs`, `extra_outputs`, or
`cache = false`.

## Dependency resolution

Resolution happens before cache lookup.

```text
manifest graph + source index + imports -> resolved dependency graph
```

The resolved graph must not depend on cache contents. The same project should
resolve the same way with an empty cache.

Important invariant:

```text
one logical theory/module name -> one resolved artifact in a build graph
```

Two packages exporting different `FooTheory`s cannot safely coexist in one HOL
process; `holbuild` should reject that graph rather than rely on load-path order.

## Artifacts and local materialization

Project `.hol/` is the complete local build view:

```text
project/.hol/
  gen/          generated source/signature files
  obj/          local ML/theory artifacts
  dep/          action metadata and dependency facts
  heap/         project-local heaps
  checkpoints/  project-local PolyML SaveState checkpoints
```

Path-sensitive files are generated or rebased for this local layout. In
particular, `.uo`/`.ui` files and generated `Theory.sml` files may contain paths
and should not be treated as portable semantic truth.

## Invalidation and action keys

Each build action has an input key derived from resolved facts, not raw paths:

```text
action_key = hash(
  holbuild action schema version,
  action kind,
  logical target,
  source package id + relative path,
  source content hash,
  resolved dependency action keys,
  relevant manifest fields,
  HOL/toolchain key,
  platform/ML-system facts where relevant
)
```

Different absolute paths under the same declared root may normalize to the same
root-relative identity. Arbitrary outside-root paths are rejected or treated as
uncacheable.

A build may also record an output key, such as hashes of produced semantic
artifacts. If the same input key produces different output keys, that indicates
nondeterminism or undeclared inputs; the safe response is to warn and disable
cache use for that action.

## Global cache

The global cache is optional and immutable:

```text
~/.cache/holbuild/
  actions/<action-key>/manifest
  blobs/<content-hash>
  tmp/
  locks/
```

Cache lookup happens only after resolution and action-key computation.

```text
if exact action key validates:
  materialize into local .hol
else:
  build from source into local .hol
  optionally publish bundle to cache
```

The cache should store semantic bundles and metadata. Local path-sensitive files
are regenerated or rebased during materialization.

Materialization preference:

```text
1. reflink / copy-on-write clone
2. hardlink immutable blobs
3. copy
```

Build actions must never mutate installed cache-linked outputs in place. Write
to staging locations and atomically install validated outputs.

## Cache GC

Global cache retention should be bounded by default. Initial policy:

```text
retain global cache entries for 7 days by default
```

Expose:

```text
holbuild cache gc
```

Future in-tree spelling may be:

```text
hol build --gc
```

GC should remove stale tmp dirs, remove old action manifests, mark blobs still
reachable from complete manifests, and sweep old unreferenced blobs. Races with
builds should degrade to cache misses and source rebuilds.

## Heaps and checkpoints

PolyML heap checkpoints and `.save` files are local project artifacts for now:

```text
.hol/heap/
.hol/checkpoints/
```

They are large, path/session/toolchain sensitive, and can create contention if
shared globally. A future global heap cache needs stricter validation, locking,
and platform/toolchain/root keys. Until then, global cache stores semantic build
artifacts only.

## Legacy transition

Existing projects can keep using Holmake until they opt into project mode. In
project mode:

```text
- no `.holpath`
- no user-facing INCLUDES
- no Holmakefile interpretation
- dependencies require manifests or explicit shims
```

A minimal legacy-standard project manifest can be as small as:

```toml
[project]
name = "foo"

[build]
members = ["."]
```

If a project relies on custom Holmakefile behavior, it should either stay on
legacy Holmake during the transition or provide manifest-level declarations for
those behaviors when the schema grows them.
