# ECS batch spawn

Local comparison, 2026-10-09.

## API and semantics

```swift
let entities = world.spawnBatch(count: 10_000, name: "Particles") { index in
    Position(x: Float(index), y: 0)
    Velocity(x: 1, y: 0)
}
```

The batch API has two phases:

1. Evaluate the indexed builder and required factories for every row, in index order, using the existing world-local spawn-plan cache. Pending batch entities are not visible to these callbacks. Computed requirements, runtime IDs, registration changes and constructor side effects stay supported.
2. Allocate a contiguous ID range after preparation, reserve metadata capacity, group rows by archetype and fill available chunks. Register all entity locations/world links and added tracking before sending DidAddEntity notifications in input order.

Every row receives the current tick at insertion, after preparation finishes. Event handlers see the complete registered batch and may spawn or mutate the world. This visibility/tick/ID policy is explicitly documented on the API; it differs from a loop that publishes each entity before constructing the next one. Nonpositive counts return an empty array without invoking the builder.

The returned array and per-archetype row order preserve input order. The named overload assigns the same name to every batch entity. Different layouts and logical runtime schemas are supported; grouping does not reorder events or returned entities.

## Storage changes

- One atomic ID-range reservation replaces one allocation-counter increment per entity.
- Archetype/entity-map capacities are reserved once per group. SparseSet's package-scoped reserve helper prepares both its dense array and sparse dictionary.
- Chunks fills each free chunk before looking up the next one, including partial chunks and holes left by removals.
- Column owners are resolved once per chunk. Before reusing them, each row's ordered component IDs/count are checked: equal archetype masks can still contain different component order or duplicate counts. Incompatible rows use the existing ordinary row writer.
- World location-map insertion holds its existing lock once for the batch. No cache/raw pointer is held across builders, factories or event callbacks.
- Staged component owners are released after storage borrows and entity registration finish. Duplicate and stored payloads retain normal destruction/ownership behavior.

The implementation does not change the ordinary spawn path or add raw-memory operations; it uses existing BlobArray insertion and initialized-slot tracking. Batch preparation stages O(N) component values and metadata, so its transient memory cost exceeds a streaming loop. This is intended for bulk creation, not a universal replacement for ordinary spawn.

## Validation

- **199 tests in 28 suites** pass in the isolated package: all AdaECSTests and AdaUtilsTests. This includes 14 new batch tests.
- Covered: bounds, index/name/ID/location mapping, partial/empty chunk reuse, migration, heterogeneous layouts, component-order/duplicate differences under one mask, required/default factories, registration changes, dynamic requirements, runtime schema order, staging lifetime, duplicate lifetime, metadata snapshots, recursive preparation/event spawning, complete-batch event visibility, and insertion ticks.
- The actual opt-in package-benchmark suite builds and all **seven smoke cases** run successfully, including AdaECS.SpawnBatch.
- SwiftLint reports no new runtime/test/benchmark violations. Existing warnings remain for ComponentLayout.Entry's explicit memberwise initializer and the benchmark's unchanged matrix argument formatting. git diff --check passes.

Validation uses an isolated AdaECS/AdaUtils/Math adapter, local dependency sources and the existing macro helper. The production batch API is imported from a separate executable benchmark client. This is focused engine/downstream-client validation, not a full engine/editor or physical-device run.

## Measurement method

Exact harness: [ECSBatchSpawnProbe.swift](ECSBatchSpawnProbe.swift).

- Apple arm64 macOS, Swift 6.2.4, Release, default allocator, SWIFT_DETERMINISTIC_HASHING=1.
- World sizes 4,000 / 16,000 / 64,000; three warmups and 30 samples for each mode/scenario. Two complete runs of the final binary.
- The same final executable measures both an ordinary spawn loop and spawnBatch. Both return/retain a complete entity array; the loop reserves its result array before spawning.
- Native: two Int-pair components. Registered/static requirement: one parent plus a velocity factory/default. Runtime: two logical schemas using one carrier. Mixed: positions/velocities with an alternating tag layout.
- World creation/registration setup, validation and cleanup are outside timing. Builder/component construction, preparation, metadata/column allocation, location updates and event sends are included.
- Every returned entity's values and original index are validated, including both runtime schemas. The same semantic fixtures run in both modes.
- CPU is process user + system time from getrusage; wall time uses DispatchTime. Sorted-sample medians and p25/p75 are saved per whole batch. Other development activity ran on the host, so ranges are observations across runs, not confidence intervals or FPS claims.
- The published SpawnBatch smoke benchmark creates empty entities. Its returned array cost is included; the existing Spawn case does not collect a result array. Use the standalone comparison below for like-for-like collection workloads. Smoke samples validate execution, not performance conclusions.

## Results

| Entities | Scenario | CPU run 1 single → batch (ms) | CPU run 2 single → batch (ms) | CPU reduction range |
| ---: | --- | ---: | ---: | ---: |
| 4000 | native | 6.910 → 5.956 | 7.366 → 5.927 | 13.8–19.5% |
| 4000 | registeredRequirement | 6.678 → 5.697 | 6.467 → 5.502 | 14.7–14.9% |
| 4000 | staticRequirement | 6.813 → 5.790 | 6.507 → 5.887 | 9.5–15.0% |
| 4000 | runtime | 8.959 → 7.511 | 8.768 → 8.102 | 7.6–16.2% |
| 4000 | mixed | 9.469 → 8.489 | 9.453 → 8.102 | 10.3–14.3% |
| 16000 | native | 28.667 → 24.858 | 27.247 → 23.854 | 12.5–13.3% |
| 16000 | registeredRequirement | 26.503 → 22.776 | 25.847 → 21.924 | 14.1–15.2% |
| 16000 | staticRequirement | 27.494 → 23.397 | 27.906 → 23.226 | 14.9–16.8% |
| 16000 | runtime | 35.994 → 31.179 | 34.660 → 29.731 | 13.4–14.2% |
| 16000 | mixed | 38.670 → 34.008 | 40.263 → 35.154 | 12.1–12.7% |
| 64000 | native | 119.680 → 98.836 | 115.461 → 100.554 | 12.9–17.4% |
| 64000 | registeredRequirement | 108.286 → 91.549 | 113.679 → 89.962 | 15.5–20.9% |
| 64000 | staticRequirement | 113.498 → 94.520 | 115.763 → 93.297 | 16.7–19.4% |
| 64000 | runtime | 145.489 → 125.997 | 149.127 → 127.397 | 13.4–14.6% |
| 64000 | mixed | 176.735 → 138.966 | 166.959 → 133.780 | 19.9–21.4% |

Grouping by archetype improves the alternating-layout workload as well as homogeneous creation. Results reflect the entire two-phase batch operation, including staging allocations, not only the storage writer. The original pre-change ordinary-loop baseline and an intermediate contiguous-run experiment are archived locally; neither is mixed into this same-binary table.

[ECSBatchSpawn.csv](ECSBatchSpawn.csv) preserves raw CPU/wall medians and quartiles for both runs.

## Evidence and reproduction

`/private/tmp/adaecs-storage-20261009/batch-evidence` contains the original/final source snapshots, executable binaries, JSON results, manifest/probe, full test/build/lint logs and the seven-case package-benchmark smoke output. Dependency/module/build caches remain task-owned; the shared repository .build is only read for dependency sources and the macro helper.

The adapter defines BATCH_SPAWN_PROBE on the standalone target to enable both modes:

```bash
swift build --package-path /tmp/adaecs-storage-20261009 --disable-sandbox -c release --product ECSBatchProbe
SWIFT_DETERMINISTIC_HASHING=1 /tmp/adaecs-storage-20261009/.build/release/ECSBatchProbe /tmp/adaecs-storage-20261009/batch-evidence/repeat.json
swift test --package-path /tmp/adaecs-storage-20261009 --disable-sandbox --parallel
ADAENGINE_BENCHMARK_SMOKE=1 swift package --package-path /tmp/adaecs-storage-20261009 --disable-sandbox --allow-writing-to-package-directory benchmark run --target AdaECSBenchmarks --no-progress
```
