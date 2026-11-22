# AdaECS benchmarks

The suite uses `package-benchmark` on macOS and Linux. It is opt-in so normal
engine builds, documentation builds, Windows, and cross-platform exports do not
resolve or compile the benchmark dependency.

On macOS, install the allocator required for allocation metrics:

```sh
HOMEBREW_NO_INSTALL_CLEANUP=1 brew install jemalloc
```

On Linux, install your distribution's jemalloc development package and
`pkg-config` (for example, `libjemalloc-dev` and `pkg-config` on Ubuntu).

Run from the repository root:

```sh
ADAENGINE_BENCHMARKS=1 swift package --allow-writing-to-package-directory benchmark run --target AdaECSBenchmarks --no-progress
```

The plugin builds the benchmark executable in **Release**. Fixtures and query
creation run before measurement. Each sample measures one batch; results are
per batch, not per entity. Metrics include wall-clock time, CPU time, allocation
count, retain count, and release count where supported by the host.

| Scenario | Default workload | Measured operation |
| --- | --- | --- |
| Spawn | 100,000 entities | Spawn empty entities; world creation and cleanup are excluded. |
| SpawnBatch | 100,000 entities | Spawn empty entities through the batch API, including its returned entity array; world creation and cleanup are excluded. |
| SimpleIter | 100,000 entities | Update position from velocity through a typed mutable query. |
| FragmentedIter | 100,002 entities in three archetypes | Update one shared component across all archetypes. |
| HeavyCompute | 1,000 entities, 100 rotations each | Rotate matrix columns and write the result through a mutable query. |
| AddRemove | 100,000 entities | Add velocity to every entity, then remove it, restoring the fixture. |
| InsertCoW | 100,000 entities | Allocate and insert components containing an array and a heap-backed string; removal is excluded. |

The CoW workload exercises ownership transfer through `World.insert` and chunk
storage. It provides a workload for comparing ownership changes, without making
an FPS claim or comparing unrelated engines.

## Smoke run

```sh
ADAENGINE_BENCHMARKS=1 ADAENGINE_BENCHMARK_SMOKE=1 swift package --allow-writing-to-package-directory benchmark run --target AdaECSBenchmarks --no-progress
```

Smoke mode reduces workloads to approximately 1,000 entities (100 for heavy
compute), one warmup, and at most three measured samples. It validates fixture
sizes and resulting mutations outside measurement. Use this for build/runtime
checks, not performance conclusions. The `ECS Benchmark Smoke` workflow runs
all seven scenarios and uploads its output.

## Compare revisions

On the same machine and toolchain, with smoke mode **unset**, save a baseline:

```sh
ADAENGINE_BENCHMARKS=1 swift package --allow-writing-to-package-directory benchmark baseline update before --target AdaECSBenchmarks --no-progress
```

After changing the engine, record a second baseline by replacing
`before` with `after` in the update command, then compare:

```sh
ADAENGINE_BENCHMARKS=1 swift package benchmark baseline compare before after --target AdaECSBenchmarks --no-progress
```

Keep workload sizes, allocator settings, compiler, hardware, and background
load consistent. Never compare a smoke baseline with a default-size baseline.
`InsertCoW` intentionally includes payload construction, so its timing is an
end-to-end insertion workload rather than an isolated parameter-passing cost.

If jemalloc is unavailable, `BENCHMARK_DISABLE_JEMALLOC=1` runs without allocator
metrics. Keep that setting identical on both sides of a comparison.

## AdaSprite extraction benchmarks

`AdaSpriteBenchmarks` measures the render-world extract stage for sprites on 50,000 and
100,000 untextured visible sprites (500 and 1,000 in smoke mode):

| Scenario | Measured operation |
| --- | --- |
| `AdaSprite.ExtractSprite.50k` / `.100k` | `runScheduler(.extract)` with `ExtractSpriteSystem`: executor, `Extract<Query>` over the main world and the `ExtractedSprites` rebuild. The first extraction runs in setup so measured runs reuse `SparseSet` capacity. |
| `AdaSprite.ExtractQueryOnly.50k` / `.100k` | The same `Query<Entity, Sprite, GlobalTransform, Transform, Visibility>` iterated without building `ExtractedSprite` values; the difference to the scenario above is the extraction/rebuild cost. |

`PrepareSprites` is measured on top of the extraction: `AdaSprite.PrepareSprites.1cam.50k`, `.2cam.50k` and
`.1cam.100k` run `PrepareSpritesSystem` (`runScheduler(.preUpdate)`) over pre-extracted sprites that are all
visible to every camera, so the system emits one `Transparent2DRenderItem` per sprite per camera. The render
items are reset outside the measurement. The benchmark uses the headless render backend, so no GPU is needed
and only CPU-side preparation is measured.

Run it like the ECS suite, selecting the target:

```sh
ADAENGINE_BENCHMARKS=1 swift package --allow-writing-to-package-directory benchmark run --target AdaSpriteBenchmarks --no-progress
```

Sprites have no texture, so `sprite.texture?.asset` resolution is not covered. The
benchmark uses the package-visible `MainWorld` resource to stand in for the main world.

## AdaScript query benchmarks

`AdaScriptingBenchmarks` runs the same `position += velocity` update over 100,000 entities (1,000 in smoke
mode) through the layers of the scripting stack, so the cost of the bridge is visible:

| Scenario | Measured operation |
| --- | --- |
| `AdaScripting.SimpleIter.Typed` | A typed `Query<Ref<Position>, Velocity>`, AdaECS's own fast path. |
| `AdaScripting.SimpleIter.NativeCursor` | The `DynamicQueryCursor` the bridge drives, reading and writing through reflected field thunks, without the VM. |
| `AdaScripting.SimpleIter.Gravity` | One `update` of a script system looping `for (var row in rows)` and updating two fields per row. |
| `AdaScripting.QueryOnly.Gravity` | The same loop reading only `row.id`, isolating iteration from field access. |

```sh
ADAENGINE_BENCHMARKS=1 swift package --allow-writing-to-package-directory benchmark run --target AdaScriptingBenchmarks --no-progress
```

A reference run (Apple M-series, 12 cores, release, 100,000 entities, jemalloc disabled, wall clock per
frame): typed query 14 ms, native cursor 30 ms, Gravity iteration only 0.40 s, Gravity update 1.6 s. The
typed Swift query is therefore about 115 times faster than the equivalent script, and about
three quarters of the script's time is bridge and VM work per field access rather than iteration. Treat these as
a baseline for comparing changes on the same machine, not as a portable figure.

## AdaUI interaction benchmarks

- [Split editor resize](SplitEditor/README.md) measures visible divider motion while resizing an editable code pane and a file panel.
