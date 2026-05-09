# Root HOL manifest sketch

This directory sketches how root HOL can enter project mode without interpreting
Holmakefiles.

`holproject.toml` is intended to be read with package root equal to a HOL
checkout/install root. It enumerates explicit `src/*` members and excludes known
non-build/test/tooling variants that currently collide on logical names or have
side effects.

The current sketch is a planning boundary, not a bootstrap recipe. The actual
reserved `HOLDIR` dependency uses the equivalent manifest compiled into holbuild,
so users only set `--holdir`, `HOLBUILD_HOLDIR`, or `HOLDIR`; no HOLDIR shim
manifest file is required.

Probe shape:

```sh
tmp=$(mktemp -d)
cat > "$tmp/holproject.toml" <<EOF
[project]
name = "probe"

[build]
members = []

[dependencies.HOLDIR]
EOF

(cd "$tmp" && /path/to/holbuild --holdir "$HOLDIR" build --dry-run)
```

Last audit result: with the exclude list in this sketch, dry-run planning over
an audited HOL checkout resolved 1461 HOL package nodes. Remaining work is to
turn this planning boundary into executable bootstrap/tool phases and explicit
action policies for generated, impure, or source-implicit dependency actions.
Use `[actions.<logical>].deps` for explicit logical predecessors; do not infer
Holmakefile ordering in project mode.
