# Sponza: moving shadowed lights and frame spikes — 2026-11-08

Windows, RTX 4070, WebGPU/Dawn D3D12, release + `-enable-testing`, 1280×720,
`sponza-base` PBR, 300 measured frames per route, one round. Benchmark:
`Render3DGPUTests/SponzaBenchmark` with the new `ADAENGINE_SPONZA_FLYING_LIGHTS=N`
(N shadow-casting point lights, range 10 m, circling the camera at 2.5 m).

## Moving lights cost CPU encoding, not GPU

| Route | No flying lights | 4 flying lights | CPU update p50 (none → 4) |
| --- | ---: | ---: | ---: |
| atrium | 8.2 ms | 15.5 ms | 6.3 → 14.0 ms |
| ground-floor-corridor | 9.2 ms | 16.5 ms | 7.8 → 14.7 ms |
| upper-gallery | 9.8 ms | 17.6 ms | 7.7 → 15.5 ms |

A moving light changes all six face matrices every frame, so every face is
re-culled and redrawn: 24 faces per frame for 4 lights. Stall probes
(`ADAENGINE_STALL_PROBE=1`, 1 ms threshold, atrium) show local shadows at
7.4 ms/frame: `LocalShadow.EncodeDraws` 5.0 ms for ~2,250 draws (~2.2 µs each)
and `LocalShadow.PrepareFaces` 1.6 ms. Bind groups are already cached and an
unchanged pipeline is not re-set, so the cost is the draw count times ordinary
per-draw encoding work.

**Change made:** faces whose volume intersects neither the camera frustum nor
the dynamic-irradiance surface bounds are skipped and marked stale (they redraw
once sampled). This is lossless but saved only 0.2–5% of faces here, because
lights near the camera reach the view through almost every face.

## Spikes: synchronous pipeline compilation

The same run shows six `WGPU.CreateRenderPipeline.Flat 3D Pipeline` compiles of
364–389 ms each (2.2 s total) on first use, plus ~28 ms per directional/local
shadow pipeline variant, and three directional-shadow recompiles when Hi-Z is
toggled. Any variant first used mid-flight blocks a frame for hundreds of
milliseconds. There is no persistent pipeline cache: every launch recompiles.
Swan exposes Dawn's `DawnCacheDeviceDescriptor` (load/store callbacks), so a
disk cache is feasible.

### Persistent pipeline cache (implemented 2026-11-09)

Native WebGPU now passes Dawn a disk-backed blob cache (`PipelineDiskCache`,
`<caches>/AdaEngine/PipelineCache/<adapter>`), so translated and compiled shaders
survive restarts. Same benchmark (atrium, no flying lights, stall threshold 20 ms),
two launches against one initially empty cache folder:

| | Cold launch (empty cache) | Warm launch |
| --- | ---: | ---: |
| Pipeline-creation stalls > 20 ms | 8, 1,505 ms total (worst: Flat 3D 571 ms, SSR composite 499 ms) | 0 |
| First rendered frame | 1,211 ms | 635 ms |
| Later whole-frame stalls | 148 ms, 184 ms | 39 ms |
| Cache size | 63 files, 1.7 MB | — |

The remaining first-frame time is the first submit and GPU completion
(`WGPU.SubmitCPU`, `WGPU.CompletionLatency`, initial uploads), not compilation.
Average frame times of these single-round runs (8.6–11.4 ms) are within run-to-run
noise and are not a cache effect. A cold launch (new machine, new driver, Dawn or
shader change) still compiles synchronously; option 2 below addresses that.

### Batched shadow encoding (2026-11-09)

Both CPU-bound: 320×180 is no faster than 720p (base 7.9 vs 8.4 ms, 4 lights 17.9 vs
16.0 ms). Temporary per-step timers in the local-shadow loop (2,330 draws/frame,
4 lights) split 5.5 ms of encoding into pipeline/material selection 2.1 ms, bind-group
commit + draw 1.6 ms, buffer binds 0.8 ms, material resource sets 0.6 ms.

`ShadowBatchEncoder3D` (directional cascades and local faces) now resolves each batch's
pipeline and bindings once per frame, groups a face's draws by state (shadow depth is
order-independent), binds the instance buffer once per face and selects batches with
`drawIndexed(firstInstance:)`; the WebGPU encoder skips redundant index-buffer binds.

| atrium, 720p | Before | After |
| --- | ---: | ---: |
| No flying lights | 8.4 ms | 7.6 ms |
| 4 flying lights | 16.0 ms | 12.8 ms |

Lossless check: the full WebGPU GPU validation run (344 tests) fails the same 25 issues
with identical differing-pixel counts on the committed renderer and with this change;
those golden mismatches are pre-existing on this machine.

### GPU-driven shadow batching (2026-11-09)

[Design](../Designs/gpu-driven-shadow-batching.md). Static casters are registered once, their geometry is
copied into shared buffers per vertex layout, one compute pass culls them for every shadow view, and each
view draws them with one multi-draw per draw group (`multi-draw-indirect` is available on this RTX 4070 /
D3D12 adapter). Same benchmark, 300 frames, Hi-Z off unless stated:

| atrium, 720p | ms/frame |
| --- | ---: |
| No flying lights (2 rounds) | 7.25, 7.43 (mean 7.34) |
| 4 flying lights, GPU path + multi-draw (2 rounds) | 8.34, 8.51 (mean 8.42) |
| 4 flying lights, GPU culling, one indirect draw per mesh | 14.07 |
| 4 flying lights, GPU path off (`ADAENGINE_SHADOW_GPU=0`) | 14.57 |

Four moving shadowed lights now add about 1.1 ms instead of 5.2 ms (design target: 1.0 ms). Without
multi-draw the gain disappears here, because Sponza's ~100 parts per face still mean ~100 draw calls per
face. This session's run has more shadow faces per measurement than the 2026-11-09 batching run above
(7,075 vs 5,659 drawn), so compare within one table only.

Lossless check: the full WebGPU validation (348 tests) gives the same issue list and differing-pixel counts as
the committed renderer with the GPU path on, with multi-draw forced off, and with the GPU path off; a new scene
test compares GPU-path and CPU-path frames exactly across light and caster motion and partial face reuse.

## Options (need a decision)

1. Persistent Dawn pipeline/shader cache on disk: removes repeat-launch compiles;
   first launch unchanged.
2. Asynchronous pipeline creation with load-time warm-up of known variants:
   removes mid-flight compile spikes; a not-yet-ready variant must either wait
   or be skipped for a frame.
3. Time-sliced updates for moving lights (e.g. redraw a bounded number of faces
   per light per frame, most relevant first): bounds CPU cost; shadows of moving
   lights lag by up to a few frames.
4. Lower per-draw cost by preparing draw state once per item per frame and
   sharing it across the faces that draw the item (lossless, gain unmeasured).
