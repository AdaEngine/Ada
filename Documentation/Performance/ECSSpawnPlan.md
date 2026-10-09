# ECS spawn plan cache

Local comparison, 2026-10-09.

## Implementation

`World` keeps a bounded cache of spawn preparation metadata:

- Keys preserve the ordered input component IDs, including each payload's logical runtime ID. They do not use only the carrier metatype or an unordered component mask.
- A plan contains snapshots of registered requirement factories per input, the actual expanded output signature, ComponentLayout and archetype index. Constructed component values are never stored in the cache.
- The last-used plan is checked directly against input IDs, avoiding signature allocation/hashing for repeated bundles. Other signatures use a dictionary. On insertion of a new signature when 256 entries are present, the dictionary is cleared while retaining capacity.
- Native/runtime required-component registration and `World.clear()` invalidate the cache and increment its revision. Copies start with a fresh cache while retaining their copied registrations.
- Factories run separately for every entity and preserve input/requirement order. Computed `requiredComponents` getters and default factories are evaluated at the same point on every spawn; their results are not frozen.
- If a factory changes registration, later inputs resolve current registrations instead of using the old snapshot. A plan from a spawn that changed the registry is not published. Cache accesses do not hold mutable borrows across user callbacks.
- Actual generated output IDs/count and the current archetype layout are checked before reusing an index. Dynamic getter results or factories returning another logical runtime schema fall back to resolving the actual layout.
- The expanded value array is allocated lazily only when requirements produce components. Otherwise the original input array is passed through.

Entity allocation, chunk insertion, locations, ticks, added-entity tracking and DidAddEntity emission remain in the established insertion path. No public API, raw pointers or new synchronization escape hatches are introduced. Mutation follows the existing externally synchronized World contract.

## Validation

- Eleven new semantic tests passed against the original spawn before implementation.
- Final validation passes **131 tests in 20 AdaECSTests suites**, including 12 spawn-plan tests.
- Coverage: fresh factory payloads, value destruction, registration additions/replacements, constructor-capture release, per-world registrations/copy/clear, dynamic type requirements including disappearance, logical runtime schemas, varying factory output topology, registration changes between inputs, recursive spawn, explicit-value ordering, initialized ticks/events, and signature churn beyond cache capacity.
- SwiftLint reports no violations in the changed runtime/test files; `git diff --check` passes.

Tests run in the isolated AdaECS/AdaUtils/Math package adapter with the entire AdaECSTests target, local dependency sources and the existing macro helper. The separate benchmark executable uses the public AdaECS API. This is focused ECS/downstream-client validation, not a full engine/editor or physical-device validation.

## Measurement

Exact harness: [ECSSpawnPlanProbe.swift](ECSSpawnPlanProbe.swift).

- Apple arm64 macOS, Swift 6.2.4, Release, default allocator, `SWIFT_DETERMINISTIC_HASHING=1` on both revisions.
- Sizes: 4,000 / 16,000 / 64,000 entities; three warmups and 30 samples per case/revision.
- Native: two components with two Int fields each. Registered requirement: one input parent and a registered velocity factory. Static requirement: one parent with a type-declared velocity default. Runtime: two logical schemas using RuntimeComponentPayload.
- Each sample creates a fresh World outside timing and configures its registrations. **Cold start** has no prepared target archetype/plan; the timed batch's first spawn creates them, and later spawns can hit the plan. It is not a cache miss on every entity. **Warm start** spawns/removes one fixture entity before timing, retaining its archetype/chunk and (after the change) its plan.
- Fixture setup, validation and cleanup are outside timing. Creating component values, spawning, allocating further chunks, metadata lookup and callbacks inside spawn are included.
- Native/required cases validate query counts, values and checksums. Runtime cases validate both logical schema values for every entity.
- Process CPU time uses getrusage user + system time; wall time uses DispatchTime. Sorted-sample p50 and p25/p75 are recorded per complete batch.
- Two comparisons use the original saved binary and the final saved binary with identical harness/settings. The second executes the original/final binaries consecutively. Intermediate implementations are not included in the table.
- Other development activity ran on the host. Absolute timings and small differences vary; reduction ranges are observations from these two comparisons, not confidence intervals or FPS claims. Cache lookup/validation overhead is included, and savings cannot be attributed independently to constructor snapshots, layout reuse and lazy expansion.

## Results

| Entities | Scenario | Start | CPU pair 1 before → after (ms) | CPU pair 2 before → after (ms) | CPU reduction range |
| ---: | --- | --- | ---: | ---: | ---: |
| 4000 | native | cold | 7.201 → 6.066 | 6.669 → 6.663 | 0.1–15.8% |
| 4000 | native | warm | 6.873 → 6.186 | 6.543 → 6.318 | 3.4–10.0% |
| 4000 | registeredRequirement | cold | 6.431 → 5.960 | 6.164 → 6.094 | 1.1–7.3% |
| 4000 | registeredRequirement | warm | 6.346 → 5.794 | 6.209 → 6.043 | 2.7–8.7% |
| 4000 | staticRequirement | cold | 6.563 → 6.149 | 6.125 → 5.943 | 3.0–6.3% |
| 4000 | staticRequirement | warm | 6.520 → 6.071 | 6.141 → 5.887 | 4.1–6.9% |
| 4000 | runtime | cold | 9.404 → 7.660 | 8.593 → 7.591 | 11.7–18.5% |
| 4000 | runtime | warm | 9.188 → 7.380 | 8.538 → 7.608 | 10.9–19.7% |
| 16000 | native | cold | 28.311 → 24.724 | 25.895 → 26.457 | -2.2–12.7% |
| 16000 | native | warm | 28.788 → 24.591 | 26.966 → 26.934 | 0.1–14.6% |
| 16000 | registeredRequirement | cold | 26.734 → 23.085 | 25.425 → 24.983 | 1.7–13.6% |
| 16000 | registeredRequirement | warm | 27.704 → 24.090 | 25.748 → 25.564 | 0.7–13.0% |
| 16000 | staticRequirement | cold | 26.145 → 23.746 | 25.283 → 24.926 | 1.4–9.2% |
| 16000 | staticRequirement | warm | 27.232 → 23.757 | 24.722 → 24.518 | 0.8–12.8% |
| 16000 | runtime | cold | 36.726 → 30.396 | 35.307 → 32.594 | 7.7–17.2% |
| 16000 | runtime | warm | 36.514 → 30.471 | 37.275 → 33.143 | 11.1–16.5% |
| 64000 | native | cold | 121.005 → 106.228 | 115.579 → 111.941 | 3.1–12.2% |
| 64000 | native | warm | 123.246 → 105.612 | 121.719 → 105.688 | 13.2–14.3% |
| 64000 | registeredRequirement | cold | 118.101 → 96.797 | 111.267 → 100.795 | 9.4–18.0% |
| 64000 | registeredRequirement | warm | 117.959 → 97.158 | 109.921 → 107.404 | 2.3–17.6% |
| 64000 | staticRequirement | cold | 117.771 → 99.936 | 108.576 → 106.570 | 1.8–15.1% |
| 64000 | staticRequirement | warm | 113.607 → 99.338 | 111.658 → 102.869 | 7.9–12.6% |
| 64000 | runtime | cold | 156.248 → 129.388 | 158.156 → 138.273 | 12.6–17.2% |
| 64000 | runtime | warm | 157.208 → 126.025 | 153.215 → 133.472 | 12.9–19.8% |

The cache yields a smaller improvement than the preceding query/storage changes. The relevant benefit is removing repeated preparation while preserving factory semantics and providing metadata that a future batch path can reuse. See the individual scenarios and quartiles before drawing conclusions about a particular workload.

[ECSSpawnPlan.csv](ECSSpawnPlan.csv) preserves all CPU/wall medians and quartiles for both comparisons.

## Evidence and reproduction

`/private/tmp/adaecs-storage-20261009/spawn-evidence` contains the manifest/probe, original/final source snapshots, saved binaries, both JSON comparisons, build/test/lint logs, and the intermediate cache-only comparison. The adapter reuses dependency sources and reads the macro executable; it writes compilation/module caches only to the task-owned temporary package.

```bash
swift build --package-path /tmp/adaecs-storage-20261009 --disable-sandbox -c release --product ECSSpawnProbe
SWIFT_DETERMINISTIC_HASHING=1 /tmp/adaecs-storage-20261009/.build/release/ECSSpawnProbe /tmp/adaecs-storage-20261009/spawn-evidence/repeat.json
swift test --package-path /tmp/adaecs-storage-20261009 --disable-sandbox --parallel
```

Snapshot SHA-256:

- Original World.swift: `61a498b4b378aa5c20c87b47037346a3e8a7dd4f7a18415b0c7999e425770f76`
- Final World.swift: `2a9065f24561831c91141cf30e37549c5bf2168ddb3f5d92418a980854f66b17`
- New World+SpawnPlan.swift: `a11eb78414776f3750bff0ef8cb4e547f1bedaf86ec8caeba680f8d87417d100`
