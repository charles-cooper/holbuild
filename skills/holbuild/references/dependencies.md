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
| `path` | No | Local path to dependency root (relative to manifest dir) |
| `manifest` | No | Explicit manifest file path when dep lacks `holproject.toml` |

At least `path` (or a `.holconfig.toml` override) must resolve for the dependency to be found locally.

## Local overrides

```toml
# .holconfig.toml (not committed)
[overrides.foo]
path = "../foo-dev"
```

Override takes priority over `path` in the manifest. The override path must still validate as package `foo` (manifest with matching `project.name`).

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
2. For each dependency: check override path → fallback to declared path
3. Find manifest: `manifest` field (if set) → dependency's own `holproject.toml` → error
4. Validate: dependency manifest `project.name` must match dependency key name
5. Resolve dependency's own dependencies recursively (transitive closure)
6. Each package gets artifacts under `.holbuild/deps/<package-name>/`
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
