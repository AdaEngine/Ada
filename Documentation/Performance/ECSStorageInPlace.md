# ECS storage: in-place mutation and component lifetime

Local comparison, 2026-10-08.

## Change

- Mutate archetype and chunk metadata in place instead of extracting, mutating, and writing back value copies.
- Borrow two distinct archetypes through a scoped buffer helper; indices are checked and the outer collection cannot resize during the closure.
- Destroy previous component values on replacement and removed component columns during archetype transitions.
- Track initialized blob slots so public insert can initialize partial columns or replace live values; added ticks are preserved on replacement.
- Transfer initialization state during row movement and reallocation; shrinking copies only the retained range and destroys truncated values.

Initialization flags cost one byte per allocated slot. Slot accesses follow the same externally synchronized contract as the existing raw values.

## Method

- Apple arm64 host, 12 cores, 36 GiB RAM; Swift 6.2.4, Release, package-benchmark 1.29.11, jemalloc 5.3.1.
- Same benchmark harness from PR #109 with entity counts set to 1,000 / 2,000 / 4,000.
- Three warmup iterations and 30 measured samples per case/revision, scaling factor one, 120-second duration limit.
- Values below are HDR histogram p50 per batch. Fixture creation and documented cleanup are outside measurement.
- Before includes the previously implemented local ownership annotations; after adds this storage/lifetime change.
- Measurements ran locally without isolating the machine from other development activity. Wall-clock speedup is workload-specific; CPU time and ARC/allocation counts provide additional evidence.
- This is not an FPS measurement or a physical-device comparison. Lifetime fixes and CoW changes are measured together.

## Results

| Entities | Scenario | Wall before → after (ms) | CPU before → after (ms) | Retains before → after | Allocations before → after |
| ---: | --- | ---: | ---: | ---: | ---: |
| 1000 | Spawn | 11.297 → 1.524 | 10.740 → 1.253 | 536,499 → 17,011 | 8,037 → 2,103 |
| 1000 | AddRemove | 43.647 → 6.824 | 42.566 → 5.485 | 2,303,006 → 120,006 | 32,001 → 6,001 |
| 1000 | InsertCoW | 21.791 → 7.930 | 21.348 → 3.555 | 1,152,502 → 56,502 | 18,000 → 5,000 |
| 2000 | Spawn | 36.667 → 3.514 | 35.979 → 2.511 | 2,088,995 → 34,023 | 16,044 → 4,146 |
| 2000 | AddRemove | 194.380 → 18.907 | 174.588 → 10.576 | 8,734,006 → 240,006 | 64,001 → 12,001 |
| 2000 | InsertCoW | 88.736 → 10.019 | 83.362 → 6.304 | 4,369,002 → 113,002 | 36,000 → 10,000 |
| 4000 | Spawn | 301.466 → 4.747 | 179.175 → 4.428 | 8,241,987 → 68,047 | 32,055 → 8,225 |
| 4000 | AddRemove | 630.718 → 22.839 | 592.445 → 20.234 | 33,980,006 → 480,006 | 128,001 → 24,001 |
| 4000 | InsertCoW | 328.729 → 12.665 | 299.368 → 10.134 | 16,994,002 → 226,002 | 72,000 → 20,000 |

Retain counts after the change grow approximately proportionally to entity count over these three sizes. The former archetype/entity-array copying dominates the before ARC counts.

## Validation

- Lifecycle tests failed before the fix: previous values and columns removed during migration were not destroyed.
- Focused ECS validation: 65 tests passed.
- Full engine package: 1,369 tests in 249 suites passed.
- Regression coverage includes replacement, partial columns, added/changed ticks, distinct archetype/chunk swap locations, metadata snapshots, absent-component removal, noncopyable values, and blob growth/shrink.
- All nine before and nine after benchmark measurements completed, with 30 samples each.

## Local evidence and reproduction

The exact measurement harness, runner, before/after source snapshots, raw baselines, CSV, and extraction program are saved under `/private/tmp/adaengine-inplace-evidence`. The harness differs from the published smoke configuration: it reads `ADAENGINE_BENCHMARK_ENTITIES`, uses three warmups, 30 samples, and a 120-second cap. Use these same settings and the same allocator/toolchain on both revisions.

Benchmark cases: `AdaECS.Spawn`, `AdaECS.AddRemove`, and `AdaECS.InsertCoW`. The published benchmark PR remains separate from this local optimization.
