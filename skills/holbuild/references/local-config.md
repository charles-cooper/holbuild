# .holconfig.toml local config

Uncommitted per-user overrides. Lives at the project root. Schema-checked — unknown fields are errors.

```toml
[overrides.depname]
path = "../dep-dev"    # local override for dependency "depname"; $VAR/${VAR} allowed

[build]
exclude = ["worktrees/*"]   # appends to manifest excludes
jobs = 16                   # default -j when not specified on CLI
tactic_timeout = 30.0       # root-package per-step timeout (overrides manifest [build].tactic_timeout)
```

## Override semantics

`[overrides.X]` changes where package `X` is found locally. It does **not** change the package identity — the override path must still contain `X`'s manifest (own `holproject.toml` or consumer-supplied shim).

Overrides take priority over `[dependencies.X].path` from the manifest. Override paths support `$VAR` and `${VAR}` expansion; unset variables are errors.

## Build excludes

`[build].exclude` in `.holconfig.toml` is **appended** to the manifest `[build].exclude`, not a replacement. Use it for workstation-specific paths (worktrees, local scratch) that shouldn't affect the committed manifest.

## Build jobs and timeout

Jobs priority: CLI `-jN`/`--jobs N` > `.holconfig.toml [build].jobs` > `max(1, nproc/2)`.

Tactic-timeout priority for root-package theorem instrumentation: CLI `--tactic-timeout` > `.holconfig.toml [build].tactic_timeout` > manifest `[build].tactic_timeout` > default `2.5`. `0` disables the timeout. Dependency packages build with no tactic timeout.

## Not committed

`.holconfig.toml` is for local machine setup. Add to `.gitignore`. It references local paths and workstation preferences that don't belong in version control.
