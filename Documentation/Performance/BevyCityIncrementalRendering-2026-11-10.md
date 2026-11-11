# Bevy City incremental rendering on Windows

The standalone AdaEngine port ran on Windows with a Ryzen 9 7900X and GeForce RTX 4070 through Dawn WebGPU on D3D12. Both Release binaries used Swift 6.3.1, a 1920×1080 render target, seed 42, a 30×30 city, and 5% car density. The scene contained 45,700 mesh entities, 30,784 LOD alternatives, and 1,327 moving cars. Frustum and distance culling, mesh LOD, contact shadows, and three effective 2048-pixel directional cascades were enabled. The directional light's shadow distance was 100 units.

The benchmark resizes the native client area and verifies the reported render target and captured PNG dimensions. Each run waits for at least five seconds and 15 rendered frames, then samples for at least 15 seconds. The fixed-camera run keeps traffic moving. The orbiting camera follows the same time-based route in both versions.

## Results

Two alternating runs per build and camera mode produced these ranges. Both builds used the original appearance settings.

| Camera | Baseline FPS | Candidate FPS | Baseline p95, ms | Candidate p95, ms |
| --- | ---: | ---: | ---: | ---: |
| Fixed | 3.66–3.77 | 22.85–23.43 | 273.18–286.39 | 46.01–59.08 |
| Orbiting | 5.46–5.88 | 12.80–12.99 | 184.51–238.63 | 81.89–83.34 |

An earlier isolated fixed-camera run on the same baseline binary measured 5.91 FPS. Use the paired ranges with this baseline variability in mind.

In separately instrumented fixed-camera runs, median CPU render-world extraction went from 49.56 ms to 1.11 ms and median directional shadow node time went from 85.28 ms to 2.57 ms. Fixed 1080p frames rendered with traffic disabled matched byte for byte across the two builds.

The standalone benchmark keeps the source JSON, PNGs, and profiles in `AdaBevyCity/results/incremental-*`. The two measured executable SHA-256 values were `5C1A5BEBB366810A297B893E77522D8860A2B39499C9A1B8A945B8938115D7B2` and `683F05AD3091FC1CB24F72811DD1034264C781375F66B9555C07C599270EECD2`, respectively.

Eleven focused Windows checks passed, including a rendered WebGPU shadow comparison. The full WebGPU suite reported 26 issues. Of those, 25 reproduce issue lines from the prior shadow-batching run and one concerns transient attachment lifetime. The broader contributor review remains open.

## Scope

Extraction retains ordinary mesh records and consumes a bounded stream of transform changes. Shared standard PBR material revisions are checked once per material, and changed pipelined snapshots update dependent records. Structural edits, specialized geometry, and untracked mutation paths trigger the full extractor.

Directional shadow preparation partitions stable and moving CPU casters. A fixed view can reuse prepared stable cascade lists while moving casters update separately. A moving view recomputes visibility and LOD. Every frame still draws the shadow atlas. A moving GPU-eligible caster can trigger full GPU registry reconciliation. The journal holds up to 32,768 entries, and the retained CPU caster lists and per-cascade batches add storage proportional to the participating casters. This comparison does not measure the incremental memory cost separately.
