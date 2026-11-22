# AdaUI paint-only updates

Status: approved for the Canvas prototype.

## Goal

Avoid replacing AdaUI's root for appearance-only changes with stable geometry. The Release benchmark at `00bafc3e6` measured 285.97 ms median to replace the root and recolor 5,000 fixed-size rows; 92–93% of measured work occurred inside the root update. This is a synthetic CPU workload, not a Studio frame-rate measurement.

## Design

Borrow GPUI's distinction between dirty views and reusable paint output, not its element architecture. Keep the tree mounted and use AdaUI's existing revision-based `Canvas` and local redraw path for an explicitly paint-only input. A changed paint value advances the affected layer's drawing revision and requests redraw. Keep the normal invalidation path for geometry, structure, environment with unknown impact, focus, hit testing, and accessibility. Do not infer paint-only behavior from arbitrary closures or introduce a new public API.

Start with a mounted benchmark prototype; migrate a Studio caller only if profiling confirms it routes a paint-only change through broad invalidation. Keep root replacement as a control. This design does not make arbitrary root replacement cheaper, or change how user code declares views. If no real caller matches, report prototype evidence only. An internal change with no public API or workflow change needs no user-guide update; revisit if scope expands.

## Verification

- Assert updated colors, unchanged unaffected output, preserved mounted identity and geometry, and no content rebuild or ancestor layout for paint-only changes. Verify resize and keyed reorder still follow normal layout.
- Compare Release p50/p95 for unchanged, one-row, and all-row updates at 100, 1,000, and 5,000 rows. Keep output and viewport matched and validate output outside timers. Report CPU time, not FPS.
- Run focused AdaUI tests, contributor validation, and independent review. If a Studio caller is migrated, verify the actual interaction, appearance, and input/focus behavior.
