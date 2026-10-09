# ECS query iteration: metadata field projection and chunk binding

Local comparison, 2026-10-09.

## Change

`FilterQueryIterator.next()` used to load a whole `Archetype` value for every row, retaining all of its nested CoW metadata. It now projects only the fields needed for cursor checks, chunk/entity IDs and entity lookup. Whole archetype/chunk values are passed to a scoped `borrowing` helper only when binding column fetches for a new chunk. The unowned `Archetypes` owner is resolved once per `next()` call.

The change stays in `Sources/AdaECS/Query/Query.swift`. It adds no raw pointers or metadata caches across calls. Existing query-target interfaces, entity lookup, filter/access declarations, state refresh and change tracking stay in use. The `entityId → location → Entity` lookup remains a separate optimization candidate; avoiding it requires a compatible component-only fetch path.

## Release SIL evidence

The exact compiler probe is [ECSQueryIterationSIL.swift](ECSQueryIterationSIL.swift), compiled with Swift 6.2.4, `-O -whole-module-optimization -emit-sil` against each revision's Release modules.

- Before, the specialized `FilterQueryIterator.next()` loads a full archetype and issues `retain_value` before checking `needsUpdateData`, on the normal per-row path.
- After, the ordinary row path uses field addresses/projections. Full metadata loads and aggregate retains appear under the `needsUpdateData` branch for chunk binding.
- Static `strong_copy_unowned_value` instruction sites in this specialization drop from three to two: one for `Archetypes` and one for `Entities`.
- Some array/entity retains and the entity-location lookup remain. Static instruction sites are not runtime ARC counts; no claim of an ARC-free iterator is made.

Full SIL and extracted `next()` bodies are archived with the local evidence.

## Validation

- Six new semantic tests passed against the original iterator before changes.
- All **119 tests in 19 AdaECSTests suites** pass against the final implementation, including seven new query iteration tests.
- Coverage includes multiple archetypes/chunks, deletion and migration, empty chunks/archetypes, `Ref` mutation and added/changed ticks, archetype and row filters, optional targets, and a custom target that receives `Entity` and returns nil for selected rows.
- A callback removes/reinserts an entity while traversing the same archetype; it verifies metadata borrows end before control returns to the caller and the following `next()` calls see the updated rows.
- SwiftLint reports no violations in the changed runtime/test files; `git diff --check` passes.

The validation package includes the current AdaECS, AdaUtils and Math sources, the entire AdaECSTests target, local dependency sources and the existing macro helper. Compilation outputs/module caches are isolated. The separate executable probe imports only the public AdaECS API. This is focused ECS/downstream-client validation, not a full engine/editor or physical-device run.

## Method

- Apple arm64 macOS host, Swift 6.2.4, Release, default allocator.
- Exact harness: [ECSQueryIterationProbe.swift](ECSQueryIterationProbe.swift).
- Four nonempty archetypes with equal populations; chunk capacity 250; world sizes 4,000 / 16,000 / 64,000 entities.
- Each sample performs eight complete query passes. There are three warmups and 30 measured samples for every case/revision.
- World creation, query-state update, tick fixture setup, checksum validation, mutation verification and cleanup are outside measurement. Iterator creation/binding and row fetches are included.
- Read/Entity/Optional/Write visit all rows. `With` selects two archetypes (half the world). `Changed` evaluates rows in all four archetypes and selects half. Writes run after the other scenarios so they do not alter the Changed fixture.
- Position and velocity each contain two `Int` fields. Reads accumulate a checked checksum. Writes increment position.y through `Ref` and verify the stored values after all samples; they also preserve the read checksum.
- CPU time is process user + system time from `getrusage`; wall time uses `DispatchTime`. Values are sorted-sample medians. The table divides batch medians by eight to report CPU time per pass.
- Both source revisions use identical harness/settings. Each saved binary is measured twice. Pair 1 compares the initial baseline with the final implementation; pair 2 runs the original/final saved binaries consecutively. Only the final implementation is represented below.
- Other development activity ran on the host. Absolute CPU and wall timings changed between runs; CPU savings below are observed ranges across two comparisons, not confidence intervals or universal speedups. These are workload microbenchmarks, not FPS measurements.

## Results

| Entities | Scenario | CPU/pass pair 1 (ms) | CPU/pass pair 2 (ms) | CPU reduction range |
| ---: | --- | ---: | ---: | ---: |
| 4000 | Read | 1.590 → 0.634 | 1.076 → 0.619 | 42.5–60.1% |
| 4000 | With | 0.772 → 0.314 | 0.484 → 0.342 | 29.3–59.3% |
| 4000 | Changed | 1.059 → 0.323 | 0.620 → 0.333 | 46.3–69.5% |
| 4000 | Entity | 1.902 → 1.001 | 1.264 → 1.054 | 16.7–47.4% |
| 4000 | Optional | 1.664 → 0.756 | 1.279 → 0.779 | 39.1–54.5% |
| 4000 | Write | 2.064 → 0.882 | 1.649 → 0.925 | 43.9–57.3% |
| 16000 | Read | 6.933 → 2.736 | 4.470 → 2.832 | 36.6–60.5% |
| 16000 | With | 3.265 → 1.491 | 2.186 → 1.554 | 28.9–54.3% |
| 16000 | Changed | 4.368 → 1.536 | 2.945 → 1.865 | 36.7–64.8% |
| 16000 | Entity | 8.305 → 3.893 | 5.954 → 4.883 | 18.0–53.1% |
| 16000 | Optional | 6.945 → 3.979 | 5.977 → 3.493 | 41.6–42.7% |
| 16000 | Write | 8.449 → 4.775 | 6.253 → 4.494 | 28.1–43.5% |
| 64000 | Read | 30.529 → 15.269 | 21.981 → 15.589 | 29.1–50.0% |
| 64000 | With | 15.965 → 7.708 | 11.841 → 6.876 | 41.9–51.7% |
| 64000 | Changed | 18.239 → 8.229 | 13.546 → 7.773 | 42.6–54.9% |
| 64000 | Entity | 36.478 → 22.738 | 31.327 → 22.665 | 27.7–37.7% |
| 64000 | Optional | 33.955 → 21.742 | 27.159 → 18.291 | 32.7–36.0% |
| 64000 | Write | 38.461 → 25.769 | 36.117 → 20.321 | 33.0–43.7% |

Both comparisons show lower CPU medians in every case. At 64,000 entities, reading improves by 29–50%, Ref mutation by 33–44%, and the two filter cases by 42–55%. The ranges expose run-to-run variation rather than selecting the largest result.

[ECSQueryIteration.csv](ECSQueryIteration.csv) preserves raw batch CPU/wall medians and wall quartiles for both comparisons. Use the `iterations` column when normalizing these values.

## Local evidence and reproduction

`/private/tmp/adaecs-storage-20261009/query-evidence` contains the exact probe/manifest, original/final source snapshots, saved binaries, two before/final JSON comparisons, compiler output, SIL, test logs and lint results. The isolated package reuses dependency sources and reads the existing macro executable; it does not write compilation outputs to the repository's shared `.build`.

Build the saved probe as an executable depending on AdaECS, using the same isolated SwiftPM settings and module caches on both revisions. The existing local adapter can be invoked with:

```bash
swift build --package-path /tmp/adaecs-storage-20261009 --disable-sandbox -c release --product ECSQueryProbe
/tmp/adaecs-storage-20261009/.build/release/ECSQueryProbe /tmp/adaecs-storage-20261009/query-evidence/repeat.json
swift test --package-path /tmp/adaecs-storage-20261009 --disable-sandbox --parallel
```

`Query.swift` snapshot SHA-256:

- Before: `ca501e689451de8c7bd5fe4b0544fa5f260a7ae302d7bab690b6121ac521f45c`
- After: `9ced3ac2fda12b74e4ba244b165c419339ec98ec37be415da2f95032b076308b`
