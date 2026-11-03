# Sponza windowed demo

Fetch the external dataset first with `python script/fetch_benchmark_scene.py` from the engine root.
The original assets and licenses stay in `.build-codex/benchmark-assets/intel-sponza`.

Run `swift run --package-path Demos/Sponza -c release SponzaDemo`.
`ADAENGINE_SPONZA_ASSETS` can override the prepared assets directory.
On Windows, use the same Swift/Dawn/Tint configuration as the native renderer benchmark.

WASD moves, Q/E changes world height, hold the right mouse button to look, and Shift increases speed.
Escape releases mouse capture until the right button is released. Yaw uses world Y and pitch uses local X;
there is no roll. The toolbar selects atrium, corridor, gallery or outside and toggles Hi-Z.
There is no collision controller. PBR textures, three shadow cascades and +3 EV match the benchmark profile.

Set `ADAENGINE_SPONZA_PROFILE_OUTPUT` to an absolute JSON filename to measure actual SceneView publication
intervals without image readback. After loading, the profiler visits atrium, gallery and outside with three
alternating pairs of shadow-on/off measurements (one second warmup, two seconds measured per case).
Keep window size constant during the entire run; discard a case if its size changes. Camera input is disabled
while profiling. The profiler restores shadows and the outside viewpoint when it finishes.
Graph records contain CPU encoding times, not GPU timestamp measurements. Use the opt-in rendering tests
for the reproducible meshlet benchmark, and the window profile to investigate interactive frame pacing.

`ADAENGINE_WEBGPU_LEGACY_COMPLETION=1` selects the old native callback polling path for diagnostic comparisons.
Leave it unset during normal use.

For moving-camera measurements, also set `ADAENGINE_SPONZA_PROFILE_MOTION=1`.
This compares the stationary gallery pose, a 0–3 metre translation along gallery X, and a full 360-degree
turn with a small pitch sweep. Motion follows a six-second wall-clock cycle through the same ECS camera
component write path as interactive movement. Each case has one second warmup and six seconds measured;
three alternating shadow-on/off pairs are recorded for each motion. `motion` and `cameraUpdates` identify
what actually moved. Use `stationary`, `translation` or `rotation` instead of `1` to run only that motion.
The scripted motion does not emulate native mouse events or an arbitrary user flight path.

## Lighting and path tracing

The window now has three explicit presets: full 8.81M-triangle raster geometry, raster lighting LOD,
and path tracing on the same lighting LOD. The default interactive preset is full-scene raster with the 12 local lights.
`ADAENGINE_SPONZA_RENDER_PRESET=fullRaster|lodRaster|pathTracing` selects startup mode.
The light button cycles 0 / 4 / 12 local lights; the sun stays enabled.
Four warm gallery spots cast shadows; eight warm/cool point fill lights do not.
The demo now defaults to 2048 pixels per sun cascade and 1024 per local-light face/tile.
Sun-shadow coverage also increases from 30 to 80 metres with closer cascade splits (lambda 0.85).
The shadow button switches back to the earlier 1024/512, 30-metre setting. Other scenes retain their defaults.
Raster local-shadow budget remains four lights; the renderer selects nearby shadow-casting sources,
including the moving test light, within that budget. PT shadow rays do not use this raster atlas budget.
The separate flying-light button enables a shadow-casting point light on a twelve-second gallery orbit.
It starts enabled for interactive testing, independently of the 0 / 4 / 12 stationary lights.
Turn it off to inspect static PT accumulation; moving light intentionally resets that accumulation.

The portable shader-BVH tracer supports at most 131072 triangles. Prepare the distinct lighting LOD first:
`python script/prepare_sponza_path_tracing.py --gltfpack <gltfpack-1.3 executable>`.
The current preparation yields 122286 source triangles, preserving image references and keeping the originals.
The tool records output hashes and its executable hash in `assets/lighting-pt-receipt.json`.
Pinned tool source: https://github.com/zeux/meshoptimizer/releases/tag/v1.3 ; Windows archive SHA-256:
`f6e9c09d66af23da3da71b86f0652d2413e81c734e0aecd1cd3d0e6e6e8645c0`.
This is a strongly simplified geometry preset; UVs and normals participate in attribute-aware simplification.
The relative geometric error is limited to 1%, with a larger triangle allocation for architecture than ivy.
Preparation rejects a result that loses an entire source material group. The former 100% error profile
discarded the floor and wall groups and must be regenerated. This LOD does not reproduce full-scene geometric detail.

PT uses 1 sample per pixel, 2 interactions and up to 128 accumulated static frames.
Without DLSS the quality button selects 1/2 width and height or the faster 1/4 preview.
With DLSS it selects Quality (2/3 input scale) or Performance (1/2); PT traces at that input size,
without a second internal resolution reduction. DLSS Super Resolution is enabled by default when available.
Its separate status line reports actual encoded frames and fallback frames. Unsupported devices retain
the ordinary rendering path and report that DLSS is unavailable.
Camera/light changes reset accumulation. It is software BVH traversal, not hardware RTX.
The demo uses 512-pixel PT material tiles (the engine default remains 128); raster still samples the
original textures. The comparison is a renderer workload comparison, not an equal-image-quality benchmark.
The status line reports actual encoded geometry, lights, ray-image size or a tracing failure.

For the lighting benchmark set `ADAENGINE_SPONZA_PROFILE_LIGHTING=1` along with the profile output,
`ADAENGINE_SPONZA_RENDER_PRESET=lodRaster`, and optionally `ADAENGINE_SPONZA_PROFILE_MOTION=rotation`.
It measures the LOD in raster and path tracing with 0, 4 and 12 local lights, three rounds of six seconds
per case after one second warmup. Cold BVH/atlas construction is outside measurement and has a 180-second
readiness deadline. PT cases require actual encoded-frame progress, expected light count and no failure;
a fallback image does not count as a path-tracing result. Profiling disables DLSS and the flying light
to preserve the explicit stationary-light cases. Full-scene legacy profiles retain 0 local lights.

For Windows DLSS builds, prepare and stage the matching native NGX runtime using
[Documentation/DLSS.md](../../Documentation/DLSS.md). This demo uses Super Resolution, not Frame Generation
or Ray Reconstruction. DLSS cannot recover geometry removed during asset preparation.

Native camera history is retained while offscreen render targets are being prepared; removal of the actual
camera releases that history. GPU regression coverage exercises this lifecycle. During movement, this
experimental tracer resets accumulation; it has no temporal reprojection or production denoiser.
The current static PT image still has substantial visual defects even after accumulation and is not a
production-quality reference. See the accepted workload measurements and remaining limits in
[the lighting report](../../Documentation/Performance/SponzaLightingPerformance-2026-11-03.md).

## Meshlets and cluster map

Prepare clusters without simplifying the source scene:

```text
python script/build_meshlet_tool.py
python script/prepare_meshlets.py <assets>/main_sponza/benchmark-pbr.gltf --builder native
python script/prepare_meshlets.py <assets>/pkg_b_ivy/benchmark-pbr.gltf --builder native
```

Keep each `.gltf.meshlets` file beside its source. Repeat preparation for `lighting-pt.gltf` to use
the smaller raster LOD. Missing or invalid sidecars retain ordinary geometry. The builder pins
meshoptimizer 1.3; no offline C++ dependency enters the runtime. See [Tools/Meshlets](../../Tools/Meshlets/README.md).

The meshlet button cycles **disabled → cpuReference → gpu**. The engine default stays disabled;
this diagnostic demo explicitly selects GPU mode. `ADAENGINE_SPONZA_MESHLETS` overrides the startup mode.
GPU v1 conservatively culls prepared static opaque singleton draws by frustum and compacts their indices,
issuing one indirect draw per original coarse draw. Existing instancing, MASK/BLEND, deformed/graph/parallax
surfaces, force-visible meshes, unknown draw passes and unsupported devices retain the original path.
Custom passes must explicitly adopt `MeshletGeometryDrawPass` to promise static vertex coverage and consume
the main-pass geometry override. Hi-Z uses the existing
legacy path; combined meshlet Hi-Z/cone culling is not enabled in this version.
Fully contained parts bypass classification/index copying and use their complete original draw; `целиком`
reports this fast path separately from unsupported fallbacks. Partial parts use workgroup-parallel prefix
scan and three batched compute passes per view, preserving source primitive order.

The separate **Карта мешлетов** button displays stable colors from actual local cluster IDs. Gray means
ordinary fallback geometry, not a missing surface. The map selects full-scene raster, disables DLSS for
sharp diagnostic colors and preserves the source silhouette. Its cached diagnostic vertex streams are
bounded to 768 MiB and created only when requested. Exact partition display uses one draw per eligible part;
adaptive LOD display coalesces the selected node ranges. Neither path issues one draw per cluster.
this diagnostic allocation/draw path is excluded from performance measurements and bypasses unused GPU
visibility compaction. Unsupported or over-budget
parts remain gray. Set `ADAENGINE_SPONZA_MESHLET_MAP=1` to start in this view.

These meshlets retain the full source triangles and are separate from the simplified PT lighting LOD.
The raster visibility processor does not accelerate the software path tracer's BVH.

`ADAENGINE_SPONZA_PROFILE_MESHLETS=1` with an absolute `ADAENGINE_SPONZA_PROFILE_OUTPUT` runs
disabled/CPU/GPU comparisons in gallery rotation and a stationary outside view: three alternating rounds,
one second warmup and four seconds measured per case. It fixes full geometry, disables DLSS, local/flying
lights, Hi-Z and the map, and leaves sun shadows enabled. The run first warms the outside overview for
three seconds and a complete gallery turn for six seconds. CPU-known cluster counts, fully visible and
fallback triangles are separate from GPU-submitted index counts, which are read back only after each
measured interval. SceneView publication
and CPU graph times are not GPU timestamps. The run ends in the full-scene meshlet map.

The current Windows/RTX 4070 gallery benchmark does **not** meet the acceleration gate: about 103 FPS
in GPU mode versus 123 FPS in disabled mode at 1890×843 without local lights or DLSS. Keep the mode
explicit while investigating this cost. Correctness, raw measurements and remaining platform limits:
[implementation report](../../Documentation/Performance/MeshletsImplementation-2026-11-03.md).

## Adaptive meshlet LOD

The original visibility-only meshlets do not simplify geometry. Prepare the additional hierarchy to let
groups of clusters use coarser parents with distance:

```text
python script/build_meshlet_tool.py
python script/prepare_meshlet_lod.py <assets>/main_sponza/benchmark-pbr.gltf
python script/prepare_meshlet_lod.py <assets>/pkg_b_ivy/benchmark-pbr.gltf
```

Keep `.gltf.meshletlod` beside the source model; `.gltf.meshlets` remains the exact v1 partition.
The builder preserves source vertex identities and exact group boundary edges; it does not cross materials.
Missing/stale/corrupt hierarchy retains the original geometry or v1 culling. Unreducible groups remain exact
forest roots instead of inventing parent levels. The prepared full architecture has L0–L4, Ivy L0–L1.

The **LOD** button cycles Off / 1 / 2 / 4 / 8 output pixels of allowed approximation error; the demo starts at 2.
`ADAENGINE_SPONZA_MESHLET_LOD=0|1|2|4|8` sets startup quality. Engine settings default to zero, and the
meshlet `disabled` mode still uses original geometry. Different source regions choose levels independently.
In the map, actual selected parents replace their children: L1 is tinted cyan, L2 orange, L3 pink, L4 purple;
L0 retains the original cluster-ID colors. The status reports selected levels/triangles for the diagnostic
cut. Ordinary GPU mode reports active LOD items; it does not synchronously read GPU triangle counts.

At the coarsest complete forest, opaque architecture changes from 3,738,878 to 2,172,290 triangles,
Ivy from 5,065,558 to 4,455,592. These are offline lower bounds, not expected counts at every camera position.
Shadow/contact passes retain full source geometry. Temporal motion guides use independent immutable indices
and the same LOD cut, including previous object transforms; they do not borrow a completed GPU frame's buffer.

`ADAENGINE_SPONZA_PROFILE_MESHLET_LOD=1` compares GPU LOD Off / 2 / 8 with the same two camera paths and
three alternating rounds. It fixes the new 2048/1024 shadow quality with 80-metre sun coverage, disables DLSS, local/flying lights,
Hi-Z and the map during timing, and records the explicit LOD/shadow settings. Profiling fixes the SceneView
to 1120×400 logical points so maximizing the native window cannot change the measured resolution.
Historical profiles keep
LOD off and 1024/512 shadows. `ADAENGINE_SPONZA_SHADOW_QUALITY=baseline` selects old startup shadows.

[LOD, shadows and final validation](../../Documentation/Performance/MeshletLODAndShadows-2026-11-03.md).
