# Checkpoints and goalfrag

## What goalfrag does

When goalfrag is enabled (default), holbuild instruments modern theorem declarations at the AST level:

1. Parses source with `HOLSourceParser` before expansion
2. Identifies `Theorem ... Proof ... QED` declarations and their tactic spans
3. Rewrites source to insert theorem-boundary markers and load the goalfrag runtime
4. At runtime, the goalfrag runtime parses tactic text into `TacticParse` fragments, plans per-fragment execution, and runs through the proof manager step by step

This enables:
- Per-tactic timeouts (`--tactic-timeout`)
- PolyML checkpoint saves at theorem boundaries
- Proof-step failure diagnostics with goal state

## What's NOT instrumented

Simple theorem forms are **not** checkpoint-instrumented in v1:
- `Theorem name = thm` (no proof body)
- `store_thm`, `save_thm`, `Q.store_thm` calls
- `Resume` / `Finalise` declarations

These still execute normally during build, just without theorem-context or end-of-proof checkpoints.

## Checkpoint lifetime

During a theory build, checkpoints may be created at syntactic boundaries:

| Checkpoint | After | Purpose |
|------------|-------|---------|
| `deps_loaded.save` | All resolved ancestors loaded in topological order | Resume from dependency context |
| `<thm>_context.save` | Theorem stored in theory context | Resume from before next declaration |
| `<thm>_end_of_proof.save` | Goalfrag proof replay complete, before `drop_all` | Proof navigation (not successor-ready) |
| `final_context.save` | Generated theory sig/sml loaded; successor-ready | Resume dependents from this point |

**Successful builds remove all checkpoint files** after artifacts and metadata are written.

Failed/interrupted builds may leave `.save` + `.save.ok` files as debug breadcrumbs.

## Checkpoint validity

`.ok` metadata contains:
- Schema version (`holbuild-checkpoint-ok-v2`)
- Checkpoint kind (`deps_loaded`, `theorem_context`, `end_of_proof`, `final_context`)
- Dependency context key
- Source prefix hash
- Checkpoint key

Replay eligibility requires exact match on deps_key, prefix_hash, and checkpoint_key.

## `--skip-checkpoints`

Runs goalfrag theorem proofs through the proof manager path without saving `.save` files at all. No `deps_loaded`, no `final_context`, no theorem checkpoints. Theory artifacts are still built normally.

## `--skip-goalfrag`

Opts out of all theorem instrumentation. Source is sent to `hol run` as-is. No checkpoints, no timeouts, no goalfrag runtime.

**Incompatible with `--tactic-timeout`** — the timeout requires the goalfrag runtime.

## Tactic timeout flow

```
--tactic-timeout 2.5   (default)
--tactic-timeout 60    for slow simplification steps
--tactic-timeout 0     disables timeout entirely
```

On timeout:
1. `smlTimeout` raises `FunctionTimeout`
2. Marker file written with tactic label and timeout duration
3. holbuild reports timed-out tactic and **does not retry** through the plain non-goalfrag fallback
4. Build fails

For production builds of large projects: use `--tactic-timeout 0`.

## Checkpoint replay

On a rebuild after source edit:
1. holbuild computes theorem boundaries from the source AST
2. Checks for valid existing checkpoints (deps_loaded first, then theorem-context)
3. If a valid checkpoint exists for an earlier theorem boundary whose source prefix is byte-identical and whose dependency context matches, resumes from that checkpoint
4. Only the suffix after the checkpoint boundary is re-executed

`always_reexecute = true` disables checkpoint replay entirely — every build starts fresh.

## Checkpoint paths

```
.holbuild/checkpoints/<package>/<relative-path>/
  .deps/<deps_key>/deps_loaded.save[.ok]
  .theorems/<deps_key>/<prefix_hash>/
    <safe_name>_context.save[.ok]
    <safe_name>_end_of_proof.save[.ok]
  .final_context.save[.ok]
```

These are local project state, never the semantic identity of a build.

## Goalfrag execution pipeline

For a modern `Theorem name: goal Proof tac QED`:

1. `holbuild_begin_theorem(name, tactic_text, context_path, context_ok, end_of_proof_path, end_of_proof_ok, has_attrs)`
2. `Tactical.set_prover goalfrag_prover` redirects theorem proofs
3. If `has_proof_attrs` or empty tactic text → atomic `TAC_PROOF` (no step-by-step)
4. Otherwise → `goalfrag_prove`:
   - Set goalfrag with the goal
   - Parse tactic text into fragments
   - Execute fragments step by step through proof manager
   - Per-step timeout wraps each fragment
   - On completion: save `end_of_proof` checkpoint, then `drop_all`
   - Save `theorem_context` checkpoint after theorem is stored

## Environment variables

| Variable | Effect |
|----------|--------|
| `HOLBUILD_SHARE_COMMON_DATA` | Override `PolyML.shareCommonData` default for checkpoint saves |
| `HOLBUILD_CHECKPOINT_TIMING` | `1`/`true` = print checkpoint save timing to stderr |
| `HOLBUILD_ECHO_CHILD_LOGS` | `1`/`true` = echo child `hol run` log to stdout |
| `HOLBUILD_STATUS` | `1`/`true` = enable status display, `0`/`false` = disable |
| `HOLBUILD_TIMING_LOG` | Path for structured timing data (tool + phase lines) |
| `HOLBUILD_GOALFRAG_RUNTIME` | Override path to `goalfrag_runtime.sml` |
