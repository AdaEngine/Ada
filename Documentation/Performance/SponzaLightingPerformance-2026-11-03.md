# Sponza lighting and portable path tracing — 2026-11-03

The demo now provides 0, 4 and 12 local lights and separate full-scene raster,
lighting-LOD raster and lighting-LOD path-tracing presets. The PT implementation
is an experimental software shader BVH, not hardware RTX. This work also fixes
discarded camera targets and PT accumulation during offscreen frame backpressure.
The image-quality complaint is **not fully resolved**: the final static image reaches
128 accumulated frames, but remains visibly poor. These results validate workload
execution and frame publication, not production rendering quality.

## Scene and controls

Four gallery spotlights cast shadows, with warm, nearly neutral radiance and range
9 metres. Eight point lights provide mild warm/cool fill, range 8 metres. The sun
remains enabled, so the actual light counts are 1, 5 and 13. The toolbar cycles the
local-light count and switches render presets. The raster local-shadow budget is four.

The full scene retains 8,812,576 triangles. The tracer currently accepts at most
131,072 triangles, so `script/prepare_sponza_path_tracing.py` prepares a separate
attribute-aware gltfpack 1.3 LOD: 114,456 source triangles, 114,454 nondegenerate
triangles actually encoded by PT. It preserves original texture references and
records tool, input and output hashes. The original scene is not overwritten.

PT uses 1 sample per pixel, 2 interactions and a static-history limit of 128 frames.
Interactive quality uses half width and height; a quarter-resolution preview is
available. Motion resets history: there is no temporal reprojection or production
denoiser. The existing PT atlas reduces source textures to 128-pixel tiles while
raster samples the original textures. This aggressive geometry and material
reduction, low sampling and remaining visual defects make PT unsuitable as an
equal-quality replacement for the full-scene renderer. Accumulation alone does
not fix those defects. Further material/atlas, geometry and sampling validation
is required before judging the visual result acceptable.

## History defect and fix

When the SceneView display ring filled, it temporarily retargeted its camera to
the primary window to skip rendering. Embedded scenes prohibit window rendering,
so extraction skipped that camera before registering it as active. Cleanup then
deleted its cached targets and PT history. Deferred extracted proxy entities
could also disappear from the render-node query during graph update. Diagnostics
showed repeated allocate/discard cycles and an encoded-frame counter stuck at 1.

Extraction now records source-camera identities before the window-rendering
guard and retains their cached targets. PT cleanup uses those authoritative
identities instead of transient extracted proxies. Removing the actual source
camera still releases the history. No shader or BVH traversal change was needed.

Two real-GPU regressions cover missing proxy components and temporary window
retargeting. They check target identity, preserved statistics, resumed frame
progress and cleanup after camera removal. In the final interactive run the
counter reached 3495 with static accumulation 128. Thus the retention defect is
fixed, although the final image still fails visual quality expectations.

## Measured workload

RTX 4070, WebGPU/D3D12, driver 32.0.16.1088, Swift 6.3.1. SceneView size was
3810 × 1790 throughout all 18 cases. PT used the quarter-resolution measurement
preset, encoding 952 × 447 rays, 1 spp and 2 interactions. After the run the demo
restored half-resolution interactive quality, 12 lights and the gallery pose.
Directional and local raster shadow passes remain enabled in both presets;
the PT result therefore includes the existing render-graph integration overhead.

Each case turns the camera through 360 degrees in six seconds, with a small pitch
sweep, following wall time. Warmup is one second and measurement six seconds,
three rounds per preset/light count. Light counts run ascending, descending,
then ascending; raster cases precede PT cases. Cold BVH/atlas preparation is
excluded. PT acceptance requires encoded-frame progress, the expected light
count and no reported tracing failure. All 18 cases passed these checks.

| Preset | Local lights | Median throughput | Range across 3 runs | Median P95 interval |
| --- | ---: | ---: | ---: | ---: |
| LOD raster | 0 | 56.6 FPS | 53.9–58.8 | 55.4 ms |
| LOD raster | 4 | 72.5 FPS | 71.3–72.8 | 39.2 ms |
| LOD raster | 12 | 75.6 FPS | 73.3–78.5 | 39.0 ms |
| LOD PT | 0 | 29.2 FPS | 27.3–30.9 | 59.7 ms |
| LOD PT | 4 | 27.5 FPS | 25.0–27.5 | 62.7 ms |
| LOD PT | 12 | 29.8 FPS | 29.2–32.3 | 57.9 ms |

Per-run throughput is 1000 divided by the mean publication interval; the table
then takes the median of three runs. P95 is calculated separately per run using
the sorted sample at floor(0.95 × (N−1)). These are SceneView publication times,
not native Present events or GPU timestamps. Graph diagnostics are CPU encoding
times. Desktop/RTSS overlays were active; no GPU-isolation claim is made.

The faster raster results with more lights and nonmonotonic PT results do not
establish that adding lights improves performance. The measurements include
pacing, scheduling and ordered-run effects. They provide a working diagnostic
baseline; a light-scaling claim needs randomized, longer isolated measurements.
The full 8.81M-triangle scene was not measured in this lighting run, so these
numbers do not establish a fix for the previously reported full-scene flight dips.

## Validation and evidence

The isolated release build completed. Focused native Swift Testing execution
passed **14 tests in 5 suites** in 9.721 seconds, including fresh PT shader
conversion, PT GPU tests, both new history regressions, camera tests and native
command-completion coverage. This used the focused validation package with
`--include-sponza-demo`; the entire engine suite was not repeated for this change.

Evidence: [SponzaLighting-2026-11-03](../../Evidence/Meshlets/SponzaLighting-2026-11-03).
`lighting-complete.json.gz` is the accepted 18-case run; `summary.json` contains
the aggregates above. The final test log, process logs and source hashes are
included. Earlier `initial-*` results used a discarded sloppy LOD and are not
the final benchmark. Earlier history-test logs predate the complete backpressure
regression and are retained only as diagnostic history.

Reproduce asset preparation and demo profiling with the instructions in
[Demos/Sponza/README.md](../../Demos/Sponza/README.md). Set
`ADAENGINE_SPONZA_PROFILE_LIGHTING=1`,
`ADAENGINE_SPONZA_PROFILE_MOTION=rotation`,
`ADAENGINE_SPONZA_RENDER_PRESET=lodRaster` and an absolute
`ADAENGINE_SPONZA_PROFILE_OUTPUT` JSON path. Keep the window size fixed.
