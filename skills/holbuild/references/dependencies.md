# Dependency management

## Declaring dependencies

```toml
# holproject.toml
[dependencies.foo]
git = "https://github.com/acme/foo"
rev = "abc123"
```

Fields per dependency:

| Field | Required | Purpose |
|-------|----------|---------|
| `git` | No | Source repository URL (informational in v1) |
| `rev` | No | Git commit (informational in v1) |
| `path` | No | Local path to dependency root (relative to manifest dir; `$VAR`/`${VAR}` expanded) |
| `manifest` | No | Explicit manifest file path when dep lacks `holproject.toml` (relative to consumer manifest dir; env expanded) |

At least `path` (or a `.holconfig.toml` override) must resolve for the dependency to be found locally, except reserved `[dependencies.HOLDIR]`.

## Built-in HOLDIR dependency

The dependency key `HOLDIR` is reserved. If `[dependencies.HOLDIR]` has no explicit `manifest`, holbuild uses a built-in manifest:

```toml
[dependencies.HOLDIR]
# no path/manifest needed for the built-in manifest case
```

The package root defaults to the configured HOL tree (`--holdir`,
`HOLBUILD_HOLDIR`, or `HOLDIR`) unless a local `path`/override is provided. This
avoids maintaining a shim manifest for HOL itself.

Scope: the built-in `HOLDIR` manifest is for root HOL sources, not every file in
the HOL checkout. It deliberately excludes examples, tests, manuals, and
non-default tool variants. If a build fails with an undeclared example structure
such as:

```text
Structure (keccakTheory) has not been declared
```

declare the example subtree as a separate dependency:

```toml
# holproject.toml
[dependencies.HOLDIR]

[dependencies.HOL_keccak]
path = "$HOLDIR/examples/Crypto/Keccak"
manifest = "shims/keccak.toml"
```

```toml
# shims/keccak.toml
[project]
name = "HOL_keccak"

[build]
members = ["."]

[dependencies.HOLDIR]
```

Downstream packages can depend on `HOL_keccak` directly or get it transitively
from another dependency's manifest. The same pattern applies to other HOL example
subtrees until they grow their own `holproject.toml` files.

## Local overrides

```toml
# .holconfig.toml (not committed)
[overrides.foo]
path = "../foo-dev"   # $VAR/${VAR} allowed
```

Override takes priority over `path` in the manifest. The override path must still validate as package `foo` (manifest with matching `project.name`). Env vars in override paths are expanded; unset variables are errors.

## Shim manifests

When a dependency doesn't have its own `holproject.toml`:

```toml
# holproject.toml consumer side
[dependencies.legacy_lib]
path = "../legacy-lib"
manifest = "shim.toml"
```

```toml
# shim.toml at the dependency or consumer
[project]
name = "legacy_lib"

[build]
members = ["src"]
```

The `manifest` path is resolved relative to the consumer's manifest directory.

## Dependency resolution flow

1. Parse `holproject.toml` and `.holconfig.toml`
2. For each dependency: check override path → fallback to declared path; reserved `HOLDIR` can resolve from the configured HOL tree
3. Find manifest: built-in `HOLDIR` manifest → `manifest` field (if set) → dependency's own `holproject.toml` → error
4. Validate: dependency manifest `project.name` must match dependency key name
5. Resolve dependency's own dependencies recursively (transitive closure)
6. Each package gets artifacts under the root project's `.holbuild/deps/<package-name>/`
7. Build the full resolved graph

## Transitive dependencies

Dependencies of dependencies are resolved automatically. No need to declare transitive deps in the root project — they're discovered through the dependency's own manifest.

## Duplicate name rejection

The resolved graph must have exactly one artifact per logical name. If two packages (even transitively) export the same `FooTheory` or `Foo` module, holbuild rejects the graph before building.

Same-package `.sig`/`.sml` companion pairs are the only exception.

## Source-level imports

`load "Foo"` and `open Foo` in source files are resolved against:
1. Project graph (matched by logical name)
2. HOL toolchain `sigobj/` (external toolchain libraries)

If a `load` directive can't be resolved to either, it's an error. Unresolved `[actions.*].deps` entries are also errors.

## Dependency build policy

Dependencies build with default settings:
- Goalfrag enabled
- No tactic timeout (consumer's `--tactic-timeout` does not affect dependencies)
- Checkpoints enabled (unless `--skip-checkpoints` globally)

Dependencies' artifact roots are under the root project's `.holbuild/deps/<package>/`, not inside the dependency's own directory.
