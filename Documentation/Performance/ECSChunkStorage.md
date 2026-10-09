# ECS chunk locations, capacity and availability

Local comparison, 2026-10-09.

## Changes

- Route deletion through the same location bookkeeping as migration. Remove the deleted entity from `Chunks.entities` and update the chunk-local swap survivor's row.
- Pass an entity-slot count to `ComponentsData`. `BlobArray` already multiplies by the stored value's stride; multiplying by the existential component metatype stride allocated 16 times too many slots on this host.
- Replace `getFreeChunkIndex`'s scan with a stack of candidate indices and a membership array. Full candidates are discarded lazily; lookup does not reserve a slot. Removal, migration and public subscript mutation restore availability. `clear()` resets availability while retaining the existing chunks.

Under structural operations through `Chunks`, each candidate is pushed/popped at most once per full/non-full cycle: lookup is amortized O(1). A single lookup can discard several stale full candidates. The cache uses one `Int` entry and one membership flag per chunk at most, rather than one entry per freed entity.

## Correctness evidence

The original source failed three new regression tests:

- Removing an entity left its location in the map and left the swap survivor pointing to its old row. Repeated deletion could report success, and insertion into the survivor wrote the wrong row.
- Deleting entity 0 from a 520-entity world, then adding a component to entity 249, changed its surviving integer component from 249 to 0. Chunk-local and archetype-global swaps involve different entities in this case.
- A chunk configured for three entities allocated 48 slots in each component/tick buffer, including initialization flags.

After the change, all eight new regression tests pass. They also cover repeated lookups, reuse after migration/deletion, clear/repopulate, public chunk replacement and mixed structural changes across multiple chunks.

All **112 tests in 18 AdaECSTests suites** pass, including the existing component lifetime, noncopyable ownership, change-tick, query and scheduler tests. SwiftLint reports no violations in the changed runtime/test files.

Validation uses an isolated package containing the current AdaECS, AdaUtils and Math sources and the entire AdaECSTests target. Dependency sources and the macro helper are read from the existing checkout/build; all compilation outputs and module caches are task-owned. This does not constitute a full engine/editor package validation.

AddressSanitizer instrumentation builds successfully, but runtime validation is blocked on this host. The default XCTest helper rejects the sanitizer dylib under macOS platform policy. With XCTest disabled, the Swift Testing helper hangs during `__asan::AsanInitInternal` / `InitializeShadowMemory`: sampling shows a recursive sanitizer initialization lock before test code runs. The task-owned helper was stopped; no ASan pass is claimed. The helper sample and both logs are archived with the evidence.

## Measurement method

- Apple arm64 macOS host; Swift 6.2.4, Release; default allocator. Sanitizers are disabled for measurements.
- Exact harness: [ECSChunkStorageProbe.swift](ECSChunkStorageProbe.swift). Two scenarios spawn fresh empty entities or entities with two components, each containing two `Float` values.
- Entity counts: 1,000 / 4,000 / 16,000 / 64,000; three warmups and 30 samples per scenario/revision.
- World construction, entity-count checks, column-byte accounting and `clear()` are outside the timed region. Allocation of chunks/columns during spawn is included.
- Wall time uses `DispatchTime`; process CPU time uses `getrusage` user + system time. Results are sorted-sample p50, without HDR histogram quantization.
- Before and after run sequentially from separate saved binaries with identical toolchain, settings and harness. Only `Chunks.swift` differs in the compiled engine sources.
- The host also ran other development activity. These are local workload microbenchmarks, not FPS or physical-device results. Before wall-time quartiles show substantial scheduling noise; do not interpret the large wall-time ratios as an established speedup. CPU comparisons are observations from this run, without a controlled repeated A/B study.

## Results

| Entities | Scenario | CPU p50 before → after (ms) | CPU reduction | Column buffers before → after (bytes) |
| ---: | --- | ---: | ---: | ---: |
| 1000 | SpawnEmpty | 1.469 → 0.976 | 33.6% | 0 → 0 |
| 4000 | SpawnEmpty | 6.226 → 4.771 | 23.4% | 0 → 0 |
| 16000 | SpawnEmpty | 27.312 → 20.887 | 23.5% | 0 → 0 |
| 64000 | SpawnEmpty | 113.403 → 93.547 | 17.5% | 0 → 0 |
| 1000 | SpawnComponents | 3.193 → 2.689 | 15.8% | 864,000 → 54,000 |
| 4000 | SpawnComponents | 13.636 → 10.032 | 26.4% | 3,456,000 → 216,000 |
| 16000 | SpawnComponents | 56.900 → 46.932 | 17.5% | 13,824,000 → 864,000 |
| 64000 | SpawnComponents | 241.307 → 202.611 | 16.0% | 55,296,000 → 3,456,000 |

Column-buffer accounting sums allocated payload/tick bytes and initialization flags for every column. It excludes entities, maps, allocator overhead, the availability cache and other world storage; it is **not total RSS**. These buffers shrink by exactly 16 times (93.75%) for this layout/toolchain. Runtime changes are measured together, so this comparison does not attribute CPU savings separately to capacity and availability.

All CPU/wall medians, wall quartiles and column bytes are preserved in [ECSChunkStorage.csv](ECSChunkStorage.csv).

## Local evidence and reproduction

`/private/tmp/adaecs-storage-20261009/evidence` contains the isolated package manifest, exact probe, before/after source snapshots and binaries, JSON results, build/test logs and lint output. The local package loads the existing macro executable, enables testing for internal column-byte accounting and shares dependency sources, but does not write to the repository's shared `.build`.

Build the probe as an executable depending on AdaECS and AdaUtils, with testable AdaECS modules, using the same isolated manifest/settings on both source revisions. Run each saved Release binary with an output JSON path. The archived local package can be invoked with:

```bash
swift build --package-path /tmp/adaecs-storage-20261009 --disable-sandbox -c release --product ECSStorageProbe
/tmp/adaecs-storage-20261009/.build/release/ECSStorageProbe /tmp/adaecs-storage-20261009/evidence/repeat.json
swift test --package-path /tmp/adaecs-storage-20261009 --disable-sandbox --parallel
```

Source snapshot SHA-256:

- Before: `d692cd733fc645575e5d32e5efaa19678c7d2f88533f5ea74b678d6ec6ef6404`
- After: `573254576f3a4f7946eebe7ee4a7666be1812498b580c869fcaea78080558b27`
