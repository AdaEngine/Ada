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
