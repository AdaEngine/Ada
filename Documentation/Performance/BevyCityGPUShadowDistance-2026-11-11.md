# GPU distance culling for directional shadows in Bevy City

The distance stage moves eligible casters with a finite draw distance into the directional WebGPU pass. It supplies the camera position, preserves distance fade in the compacted instance record, and leaves local shadows on their existing registry. The directional registry retains its own geometry pools. Scenes with both local and directional shadows can hold a second copy of the pooled geometry.

The GPU uses the original AABB center or the instance position for unbounded casters. Reconstructing the center from rounded corners can move a caster across the distance cutoff. The WebGPU readback test covers that case, rejection at the cutoff, dither fade, and the view setting that disables distance culling.

## City results

Two alternating Release runs per camera mode used the same sunset scene at 1920×1080 on RTX 4070 and Dawn D3D12. Both builds used 45,700 meshes, 1,327 moving cars, the same seed, culling, LOD, contact shadows, and directional cascades. Each run collected at least 15 seconds after warmup. Both executables used the same borderless client area and Windows process priority.

| Camera | Baseline FPS | Candidate FPS | Baseline p95, ms | Candidate p95, ms |
| --- | ---: | ---: | ---: | ---: |
| Fixed | 23.98–24.51 | 23.73–24.21 | 43.53–45.05 | 44.45–45.53 |
| Orbiting | 12.55–12.80 | 13.08–13.56 | 82.22–87.59 | 80.39–137.78 |

An earlier comparison had overlapping orbit FPS ranges. The final runs show a modest gain in average orbit throughput and mixed p95 results. In a separate instrumented orbit, median CPU wall time for the directional shadow node went from 39.27 ms to 33.51 ms. The candidate's median per-cascade CPU preparation time was 9.84 ms. There is no comparable per-cascade marker in the baseline.

The candidate reported 30,784 CPU sources, 14,916 GPU caster parts, and zero GPU clusters. The scene contains 8,634 distance-only fences and paths. The CPU fallback count in the focused rendered fixture went from two sources to one. The new distance center increases each GPU caster record from 48 to 64 bytes. With 14,916 caster parts, the candidate has about 0.91 MiB of caster metadata and reserves about 8.19 MiB of compacted instance output for three cascades per frame slot before buffer growth. These are logical sizes. GPU uploads, allocated memory, and the extra pool cost in scenes with both shadow types require separate measurement.

The fixed 1080p city captures with traffic paused had identical PNG hashes. Three focused WebGPU tests passed, covering the rendered CPU/GPU comparison, distance and fade readback, and conservative frustum culling. The broader contributor gate is open. The scoped SwiftLint check was blocked.

Raw timings and captures are in `AdaBevyCity/results/gpu-shadow-distance-verified-*`.

## Remaining LOD work

Static casters with mesh LOD alternatives continue through CPU preparation. CPU selection shares hysteresis history across the directional, local, and main passes for a camera and placement. A GPU history updated only by the directional pass can differ when a placement is visible in one pass and enters another near a transition. The LOD stage still needs a compatible history policy, placement-to-part mapping for every supported level, and parity tests at those transitions.

## Shared CPU LOD experiment

A prototype reused the selected level in later passes with identical camera and LOD inputs. The focused regression confirmed one evaluation across two cascades and the main pass, with recalculation after camera, projection, bounds, or frame changes. Rendered tests passed and the fixed 1080p city captures matched byte for byte.

Four alternating 1080p Release runs per build on the same sunset orbit produced baseline results of 11.87, 13.46, 9.45, and 14.88 FPS. The prototype produced 8.39, 13.54, 12.65, and 14.23 FPS. P95 ranged from 70.73 to 196.00 ms on the baseline and from 75.63 to 219.94 ms with the prototype. The separate instrumented orbit showed lower cascade preparation time alongside a similar reduction in extraction time, which the prototype does not modify. The experiment did not establish a repeatable frame-time gain.

The prototype increased the history value from roughly 8 to 64 bytes per placement. It was removed from the renderer and the baseline city executable was restored. Raw results and captures are in `AdaBevyCity/results/shared-lod-*`.
