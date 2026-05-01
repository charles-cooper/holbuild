# Heap exports

## Declaring heaps

```toml
[[heap]]
name = "main"
output = "build/main.heap"   # path relative to project root
objects = ["MainTheory", "UtilTheory"]  # logical targets (must be theory scripts)
```

## Building a heap

```sh
holbuild heap main
```

Heap export flow:
1. Build declared `objects` with full build pipeline (goalfrag, checkpoints, default tactic timeout 2.5s)
2. Start from base `hol.state` context
3. Load external theories and generated theory modules in build-graph order
4. Save heap with `PolyML.SaveState.saveChild`
5. Output written to the declared `output` path

`-jN` controls parallelism for the object build phase. Heap export itself is serial.

`objects` must currently be theory targets — non-theory objects in heap targets is not yet supported.

## `holbuild run` / `holbuild repl` — prototype status

These commands exist but are incomplete. They generate a context file and pass `[run].loads` as arguments to `hol run`/`hol repl`, but do not set up load paths for built project artifacts. The generated context file is effectively empty (`val _ = ()`). They are not ready for general consumer use.
