# holbuild design

`holbuild` is a project-level build model for HOL4. The goal is to make HOL
projects understandable to humans and agents: explicit manifests, logical
targets, deterministic dependency resolution, hidden implementation artifacts,
and cacheable builds that never require users to reason about the cache.

## Principles

- Build targets are logical names, not files: `FooTheory`, not `FooTheory.uo`.
- `.uo` and `.ui` are internal ML load artifacts. Users must never request them.
- Project mode is manifest based. `Holmakefile` semantics are not interpreted.
- The source tree is user-owned; build products live under project `.holbuild/`.
- Build actions do not use configured/global HOL heaps such as `hol.state` as
  semantic bases. A host tool state may run holbuild itself, but target build
  contexts are produced by holbuild from declared sources, predecessor
  checkpoints, or validated shared dependency state.
- The cache is an optional accelerator. Local `.holbuild/` is the authoritative
  materialized build view.
- When unsure, rebuild. A bad cache hit is worse than a missed cache hit.

## Packages and manifests

Every package in the resolved graph has a manifest. A source file can enter the
build graph only through a declared package root. Manifests are schema-checked:
unknown fields in recognized tables are rejected, and an optional schema marker
must name a supported schema:

```toml
[holbuild]
schema = 1
```

Omitting `[holbuild]` currently means schema 1 for transition convenience.

Package roots are declared by one of:

- the current project's `holproject.toml`
- a dependency's own `holproject.toml`
- an explicit shim manifest supplied by the consumer
- the built-in/root HOL manifest

Committed manifests describe what dependency is required. They should not rely on
ambient search paths such as `HOLPATH`. Per-user local paths are supplied by an
uncommitted `.holconfig.toml` override file instead:

```toml
# holproject.toml
[dependencies.foo]
git = "https://github.com/acme/foo"
rev = "abc123"
```

```toml
# .holconfig.toml, not committed
[overrides.foo]
path = "../foo-dev"
```

An override changes where package `foo` is found on this machine; it does not
change the package identity. The override path must still validate as `foo`,
either by containing `foo`'s `holproject.toml` or by using the configured shim
manifest for that dependency. Local config is schema-checked too; unknown fields
in `.holconfig.toml` are errors rather than silently ignored.

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
The prototype still requires `HOLDIR` so it can reuse HOL implementation pieces
while the model is incubated. That is a host/tool dependency, not the semantic
state of the target build. `HOLDIR/bin/hol.state` may be used to run holbuild's
own helper code during the external prototype, but target package actions should
not load it as their base context. Root HOL and user dependencies should be
ordinary manifest-resolved package nodes whose contexts are produced by holbuild.
The initial build context is a declared bootstrap context; later actions start
from predecessor checkpoints or validated shared dependency state.

Target workflow: after `git pull` in a HOL checkout, `hol build` should be able
to rebuild any invalidated bootstrap/base context hermetically into the checkout's
own `.holbuild/` state, or restore a validated equivalent from the global cache.
It should not require the user to run a separate global HOL rebuild first, and it
should not silently depend on a stale configured heap from before the pull.

The root-HOL transition should be explicit rather than inferred from existing
Holmakefiles. A plausible first in-tree/default manifest has package identity
`HOL` (or another reserved built-in id), enumerates major source roots as normal
manifest members, and declares bootstrap/tool phases as manifest concepts rather
than as ambient directory conventions. External HOL theory dependencies should
become normal resolved package nodes with the same action-key and cache rules as
user packages; they should not be satisfied by loading a configured full HOL heap.
Any HOL subtree that cannot yet be expressed by the manifest model should use an
explicit shim/adaptor package boundary, not Holmakefile interpretation in project
mode.

The default manifest must also preserve the duplicate-logical-name invariant:
root HOL cannot rely on load-path order to distinguish two `FooTheory` or `Foo`
modules. If historical layout contains such ambiguity, the transition has to make
that identity explicit or keep the subtree outside project mode until resolved.

A source audit of `$HOLDIR/src` with `HOLSourceParser` plus a
comment/string-aware token pass parsed all 1166 non-generated `.sml` files and
found 356 theory scripts. The scripts contain 23,179 modern
`Theorem ... Proof ... QED` declarations, 1,701 simple `Theorem name = thm`
declarations, 10 `Resume` declarations, and 7 `Finalise` declarations. Literal or
dynamic `load`/`use` calls did not appear in theory scripts; older theorem APIs
are present but much smaller in scripts (`store_thm`: 27 calls, `save_thm`: 23,
`Q.store_thm`: 1). This makes AST-derived modern-theorem checkpointing the
highest-value proof-navigation target for root HOL; simple theorem and
`store_thm`-style declarations should remain ordinary build replay until there is
an AST/proof-state model for them.

The same token pass found non-script examples and libraries with literal/dynamic
`load` calls, dynamic `use` calls, file writes, process calls, and other side
effects. A root-HOL manifest should classify such tooling/examples/tests
explicitly instead of treating them as pure cacheable theory-script actions.

A first root-HOL manifest should therefore start with the stable pure theory and
library package roots that already obey project-mode constraints, and push
non-build tooling/examples/tests behind explicit package/action boundaries.
`examples/root-hol/holproject.toml` is the current sketch: it enumerates HOL
`src/*` members, excludes selftests/examples/tool variants that collide on
logical names, and dry-run planned 1461 HOL package nodes in the audited checkout.
A follow-up regression test dry-runs that sketch against `$HOLDIR`. Attempting to
source-build core theories against `$HOLDIR/bin/hol.state` is intentionally wrong:
that state already contains those theories. Executable root-HOL bootstrap needs
manifest-level bootstrap/checkpoint phases that holbuild can rebuild or restore
on demand, not any preconfigured global HOL heap.
A smaller illustrative fragment:

```toml
[project]
name = "HOL"
version = "bootstrap"

[build]
members = [
  "src/bool", "src/num", "src/list", "src/coretypes",
  "src/pred_set", "src/finite_maps", "src/integer",
]
exclude = ["*/selftest.sml", "*/examples/*", "*/theory_tests/*"]

[actions.SomeGeneratedTheory]
extra_inputs = ["path/to/generated-input"]
cache = false

[actions.SomeImpureSelftest]
impure = true
```

This is deliberately not a Holmakefile translation. Historical directories that
need dynamic `use`, generated files, external solvers, process/file-system side
effects, or platform-variant modules should either be modeled with explicit
action policy / package boundaries or stay outside the initial project-mode root
package until their inputs and outputs are declared.

## Source model

`[build].members` admits package-root-relative source files or directories.
`[build].exclude` is an explicit package-root-relative glob filter applied during
source discovery. It is intended for excluding tests, examples, generated files,
or platform variants from a package boundary; it does not add search paths or
change dependency resolution.

Standard theory convention:

```text
src/FooScript.sml -> FooTheory
```

A theory target owns the logical artifacts:

```text
.holbuild/gen/src/FooTheory.sml
.holbuild/gen/src/FooTheory.sig
.holbuild/obj/src/FooTheory.dat
.holbuild/obj/src/FooTheory.uo
.holbuild/obj/src/FooTheory.ui
```

Theory scripts are modeled as pure build actions by default in v1: no
user-specified side effects are part of the default contract. The manifest can
mark exceptions explicitly:

```toml
[actions.FooTheory]
extra_inputs = ["data/table.txt"]
cache = false
always_reexecute = true
impure = true
```

`extra_inputs` are package-root-relative paths whose exact bytes are hashed into
the action key. `cache = false` disables global-cache restore/publish for the
action. `always_reexecute = true` disables local up-to-date skipping and dirty
checkpoint replay for the action. `impure = true` is a conservative shorthand for
no cache and always re-execute. These fields are intended for audited exceptions
such as generated data or tool/example side effects; they are not include paths
and do not make arbitrary `use "file"` directives resolvable.

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

This rejection is intentional. HOL/PolyML process state has global theory and ML
module names; two packages exporting different `FooTheory` or `Foo` modules
cannot safely coexist by relying on load-path order. `holbuild` should reject the
resolved graph before build execution instead of choosing whichever artifact
happens to appear first. The only same-logical-name exception in v1 is a local
`.sig`/`.sml` companion pair for the same package/module, which together describe
one module artifact.

## Parallel builds

`holbuild` accepts global job control:

```text
holbuild -j4 build FooTheory
holbuild --jobs 4 heap main
```

The build scheduler runs over the resolved DAG inside one holbuild process.
Actions become ready only after all direct project dependencies complete. Each
action builds in a private staging directory and installs its own outputs/metadata;
dependents are scheduled after successful completion. Separate holbuild processes
must not concurrently mutate the same project `.holbuild/`; build and heap commands
take a coarse project write lock with an owner file for diagnostics. If the lock
owner is on the same host and its recorded process no longer exists, holbuild
removes the stale lock and retries. The default remains `-j1` because HOL/PolyML
heaps can be memory-heavy and path-sensitive artifact installs need conservative
discipline. Heap targets use `-j` for their declared object build phase, then
export the heap serially from the resolved holbuild-produced base context.

## Artifacts and local materialization

Holmake and HOL tooling already use `.hol` conventions, especially `.hol/objs`
for `HOLFileSys` remapped object paths. To avoid top-level collisions with
Holmake-managed source trees, holbuild owns `.holbuild/` as its project-local
state directory. Any `.hol/objs` directories written by holbuild are nested inside
`.holbuild/` artifact directories as compatibility remap copies, not as the
project root convention.

Project `.holbuild/` is the complete local build view:

```text
project/.holbuild/
  gen/          generated source/signature files
  obj/          local ML/theory artifacts
  dep/          action metadata and dependency facts
  heap/         project-local heaps
  checkpoints/  materialized PolyML SaveState checkpoints
```

Path-sensitive files are generated or rebased for this local layout. In
particular, `.uo`/`.ui` files and generated `Theory.sml` files may contain paths
and should not be treated as portable semantic truth. Project SML/SIG modules are
built as internal load manifests: `load "Module"` references are resolved against
the project graph, not against ambient include paths. Source-level `use "file"`
is rejected in project build actions in v1 because it is an arbitrary path/input
outside the resolved package graph; declare a project module and `load` it
instead. `.sml` files get a `.uo` plus an empty companion `.ui` unless a real
`.sig` companion exists, and same-name signatures are implicit dependencies of
their implementation. HOL's current
`HOLFileSys` remaps `.uo`/`.ui` and files ending in
`Theory.dat`/`.sml`/`.sig` through `.hol/objs`, so a project-level layout may
need auxiliary internal load paths or rewritten non-semantic load copies while
preserving canonical artifacts.

## Invalidation and action keys

Each build action has an input key derived from resolved facts, not raw paths:

```text
input_key = hash(
  holbuild action schema version,
  action kind,
  logical target,
  source package id + relative path,
  source content hash,
  resolved dependency input keys,
  relevant manifest action policy and extra input hashes,
  toolchain/base-context key,
  platform/ML-system facts where relevant
)
```

HOL's existing `Holmake --cachekey` work is a useful precedent: it avoids raw
path ordering, ignores path-sensitive `.uo`/`.ui` files, substitutes theory
`.uo`/`.ui` dependencies with the corresponding `.dat`, and sorts by filename
plus content hash. That points at an important distinction for `holbuild`:

```text
input key   = can I reuse a cached build for these sources and resolved deps?
output key  = what semantic artifact did this build actually produce?
```

For v1, downstream invalidation also uses dependency input keys. A target's
input key is effectively the hash of its own source content plus the DAG heads
(input keys) of its resolved dependencies, along with toolchain/config facts.
Therefore any source byte change — including proof edits or comments — changes
that action's input key and changes the input keys of dependents. This is
conservative and avoids relying on semantic equivalence of generated theory
outputs.

A build may record output hashes, such as `FooTheory.dat`, generated theory
interface/source hashes, or checkpoint byte hashes, for diagnostics and future
cache analysis. V1 must not use output hashes to skip rebuilding dependents.

Different absolute paths under the same declared root may normalize to the same
root-relative identity. Arbitrary outside-root paths are rejected or treated as
uncacheable.

If the same input key produces different output keys, that indicates
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
  materialize into local .holbuild/
else:
  build from source into local .holbuild/
  optionally publish bundle to cache
```

The cache should store semantic bundles, shareable state bundles, and metadata.
Local path-sensitive files are regenerated or rebased during materialization. The
prototype currently publishes simple theory bundles containing `Theory.sig`,
`Theory.dat`, and a `Theory.sml` template with the `.dat` load path replaced by a
placeholder. The target model also publishes validated successor-ready checkpoint
state for shareable dependencies. On a cache hit, holbuild copies blobs into local
`.holbuild/`, rewrites local path references, writes local `.uo/.ui` load
manifests plus `HOLFileSys` remap copies, and materializes the checkpoint/state
needed by downstream actions. Missing or corrupt cache entries warn and fall back
to source build.

Materialization preference for v1:

```text
1. reflink / copy-on-write clone
2. copy
```

Avoid hardlinking cache blobs into project `.holbuild/`: even if cache blobs are meant
to be immutable, project outputs are the local materialized build view and should
not be able to mutate global cache contents by accident. Build actions must never
mutate installed cache-derived outputs in place. Write
to staging locations and atomically install validated outputs. Concurrent source
builds for the same action key serialize cache publication with a per-action
cache lock; losing publishers skip publication because the local source build has
already succeeded. Cache materialization still treats any missing, locked, or
corrupt entry as a cache miss and falls back to source.

Shared dependency state is keyed by the same resolved action key and
base-context key as the semantic artifacts, not by raw `.save` bytes. Two
projects depending on the same package revision/toolchain can therefore
materialize the same dependency final-context state into their own `.holbuild/`
views. The state bundle is still only an accelerator: if validation, relocation,
or toolchain checks fail, holbuild rebuilds the dependency from source or earlier
validated state.

## Cache GC

Global cache retention should be bounded by default. Initial policy:

```text
retain global cache entries for 7 days by default
```

Expose:

```text
holbuild cache gc
holbuild cache gc --retention-days 7
holbuild cache gc --cache-dir /path/to/cache
```

The cache root is `$HOLBUILD_CACHE`, else `$XDG_CACHE_HOME/holbuild`, else
`$HOME/.cache/holbuild`.

Future in-tree spelling may be:

```text
hol build --gc
```

GC should remove stale tmp dirs, remove old action manifests, mark blobs still
reachable from non-expired manifests, and sweep old unreferenced blobs. Races
with builds should degrade to cache misses and source rebuilds. The prototype
uses a cache-local `locks/gc.lock` directory to avoid concurrent GC runs.

## Heaps and checkpoints

PolyML heap checkpoints and `.save` files are materialized as local project
artifacts:

```text
.holbuild/heap/          optional user-requested exported heaps
.holbuild/checkpoints/   local PolyML replay checkpoints
```

Explicit heap targets are requested with `holbuild heap NAME` from `[[heap]]`
manifest entries. They are exported artifacts, not the normal incremental-build
primitive: holbuild first builds the declared logical objects, then starts from
the resolved holbuild-produced base context, loads generated theory modules in
resolved build-graph order, and saves the requested heap with PolyML SaveState.

Heaps requested by users remain project-local exported artifacts. Checkpoints are
build state: they may be produced locally or restored from the global cache when
their action key, base-context key, schema, toolchain, platform, and relocation
metadata validate. Raw checkpoint bytes are never the semantic identity; they are
the materialized state for an already-resolved graph.

`holbuild` should not use `hol buildheap` as the normal incremental-build
primitive. `buildheap` snapshots a process after loading a closure of `.uo`
modules. In holbuild, loading ancestors in resolved topological order naturally
constructs the same dependency context inside the build process; any checkpoint
after that load is just another syntactic checkpoint, not a separate closure
cache concept.

The relevant checkpointing model is the `Holmake --dumpheap` design: while a
theory script executes, the prover/runtime saves PolyML states at syntactic
boundaries such as:

```text
deps_loaded.save         after resolved ancestors are loaded in topological order
<thm>_context.save       after the theorem has been stored in the theory context
<thm>_end_of_proof.save  after goal-fragment proof replay, for navigation
final_context.save       after the script is successor-ready
```

`final_context.save` must mean successor-ready, not merely immediately after
`export_theory()`. The generated `FooTheory.sig/sml` module must be loaded before
saving so dependents can open/use `FooTheory` when starting from the checkpoint.

Those checkpoints answer a different question from action keys:

```text
action key/cache:        can this whole script action be skipped?
syntactic checkpoint:    if the action changed, where can replay resume?
```

A holbuild checkpoint action keys replay eligibility by the exact source
prefix/boundary identity, resolved dependency-context key, toolchain/base-context
key, and checkpoint schema. Raw `.save` bytes are diagnostic only and must not be
used as stable semantic keys. Shareable checkpoints are cache entries keyed by
those resolved inputs and materialized into `.holbuild/checkpoints/` for the
consuming project.

The prototype currently instruments AST `HOLTheoremDecl` declarations, i.e.
modern goal/proof forms such as `Theorem ... Proof ... QED` (including proof
attributes, with conservative whole-tactic fallback for attributed proofs). It
parses the HOL source AST before expansion to ML, uses theorem/tactic spans to
insert a theorem marker before expansion, then runs the proof through
`proofManagerLib`/`goalFrag` fragments where possible. The
`<thm>_end_of_proof.save` checkpoint is saved before `drop_all`, so it preserves
proof-manager history for navigation; `<thm>_context.save` is saved after the
expanded theorem declaration stores the theorem in the theory context. If a later
source edit leaves an earlier theorem prefix byte-identical and the resolved
dependency context still matches, a dirty rebuild can load the nearest valid
theorem-context checkpoint and replay only the suffix to `export_theory()`.
End-of-proof checkpoints are proof-navigation states, not successor-ready
contexts, and are not used for dependency replay.

Other theorem-producing syntax, such as simple `Theorem name = thm` declarations,
`store_thm` calls, `Resume`, or `Finalise`, is not checkpoint-instrumented in v1.
Those declarations still execute during normal source builds/replays, but they do
not produce theorem-context/end-of-proof checkpoints unless later modeled from the
AST with correct proof-manager state. Do not add ad hoc text-scanned wrappers for
these forms.

## Legacy transition

Existing projects can keep using Holmake until they opt into project mode. In
project mode:

```text
- no `.holpath`
- no `HOLPATH` ambient dependency search
- no user-facing INCLUDES
- no Holmakefile interpretation
- dependencies require manifests or explicit shims
- user-specific dependency locations go in uncommitted `.holconfig.toml`
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
