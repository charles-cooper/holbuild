# holproject.toml manifest

## Schema

```toml
[holbuild]
schema = 1   # currently only schema 1

[project]
name = "myproject"     # required for dependencies; optional for root
version = "0.1.0"      # optional

[build]
members = ["src", "lib"]   # source dirs/files relative to package root. Default: ["."]
exclude = ["*/selftest.sml", "*/examples/*"]  # glob patterns, package-root-relative
roots = ["src/MainScript.sml"]  # default build targets when no CLI target given

[dependencies.depname]
git = "https://github.com/org/dep"
rev = "abc123"          # git commit
path = "../dep"         # local path (or use .holconfig.toml override)
manifest = "shim.toml"  # explicit manifest path when dep lacks holproject.toml

# [run] — prototype, not yet functional for consumers
# heap = "build/main.heap"
# loads = ["MyLib"]

[[heap]]
name = "main"
output = "build/main.heap"  # heap output path, package-root-relative
objects = ["MainTheory"]    # logical targets to build before saving heap

[actions.TargetName]
deps = ["OtherTheory"]              # extra logical project dependencies
loads = ["ExternalLib"]            # extra loadable modules (project or HOL toolchain)
extra_inputs = ["data/table.txt"]  # package-root-relative, hashed into action key
cache = false                      # disable global cache for this action
always_reexecute = true            # never skip, never replay checkpoints
impure = true                      # shorthand: cache=false + always_reexecute=true
```

## Schema validation

Unknown fields in recognized tables are **errors**, not silently ignored. This catches typos early.

Tables validated: `[holbuild]`, `[project]`, `[build]`, `[run]`, `[dependencies.*]`, `[actions.*]`, `[[heap]]`.

## Dependency resolution

Each dependency must resolve to a manifest:
1. Dependency's own `holproject.toml` in its directory
2. Consumer-supplied `manifest = "shim.toml"` pointing to a manifest file
3. If neither exists, build fails with a "no manifest" error

Dependency `name` in `[dependencies.X]` must match the `project.name` in the resolved manifest. Mismatch is an error.

## Path rules

- `build.members`, `build.exclude`, `build.roots`, `actions.*.extra_inputs` — **package-root-relative**
- Absolute paths and `..` components are rejected in these fields
- Dependency `path` and `manifest` in `[dependencies.*]` are resolved relative to the *consumer's* manifest directory
- No shell expansion (`$HOME`) in any path field

## Source discovery

Members can be files or directories. Directories are walked recursively, skipping:
- Names starting with `.`
- Names equal to `_build`
- Files/folders matching `build.exclude` globs
- Files matching `*Theory.sml` or `*Theory.sig` (generated artifacts)

Recognized source files:
- `*Script.sml` → theory script, logical name = prefix + "Theory" (e.g. `FooScript.sml` → `FooTheory`)
- `*.sml` → SML module, logical name = filename minus `.sml`
- `*.sig` → signature, logical name = filename minus `.sig`

A `.sig`/`.sml` pair with the same base name in the same package is a companion pair (one module), not a conflict.

## HOLSource headers

Theory scripts can use HOLSource headers for explicit dependency declaration:

```sml
Theory Foo
Ancestors Bar
```

These are picked up by the Holdep scanner alongside `load`/`open` for dependency inference. `Ancestors` declares direct theory predecessors; `Theory` declares the theory name (redundant with `new_theory` but used by Holdep).

## Duplicate logical names

One logical name → one resolved artifact across the entire build graph. Two packages exporting `FooTheory` or `Foo` module is an error. The only exception: same-package `.sig`/`.sml` companion pair.

## Action policies

Default policy for any target: `cache = true`, `always_reexecute = false`, `impure = false`, no extra deps/loads/inputs.

| Field | Default | Effect |
|-------|---------|--------|
| `deps` | `[]` | Additional logical project dependencies |
| `loads` | `[]` | Additional loadable module stems |
| `extra_inputs` | `[]` | Files hashed into action key |
| `cache` | `true` | Enable/disable global cache |
| `always_reexecute` | `false` | Never skip up-to-date check or checkpoint replay |
| `impure` | `false` | Shorthand for `cache=false, always_reexecute=true` |

`impure = true` overrides both `cache` and `always_reexecute` — don't set them separately when using `impure`.

Action policy names must resolve to sources in the package. An `[actions.FooTheory]` entry for a target that doesn't exist in the package is an error.
