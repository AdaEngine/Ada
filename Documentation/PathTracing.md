# Portable world-space path tracing

This experimental mode traces actual scene triangles on the SAGA renderer (Vulkan, Metal or WebGPU).
Intersections run in a fragment shader BVH on every backend. On Vulkan devices that support ray queries they run
on the GPU's ray-tracing hardware instead, with the BVH as the fallback; see the DocC article
`HardwarePathTracing` and the `PathTracing3D.intersection` setting. It is a correctness and integration starting
point, not a claim of Doom or Indiana Jones performance or image quality.

```swift
// Prefer the dedicated presentation shader in a tracing-only application.
app.addPlugin(Core3DPlugin(pathTracingPresentation: true))
environment.pathTracing = .init(isEnabled: true, samplesPerPixel: 1,
    maximumBounces: 3, resolutionScale: 0.5, historyLimit: 32)
```

The ordinary plugin also supports enabling tracing on individual environments.
Its environment compositor suppresses SSR, SSAO, SSGI and the procedural ambient
addition only after a view actually encoded the tracing pass. The dedicated
presentation shader retains exposure, bloom, grading, fog and temporal HDR output,
without compiling or evaluating screen-space reflection transport. Disabled
environments allocate no tracing targets, geometry atlas or BVH.

The new node runs after the physical geometry pass and before cosmetic graph
overlays, particles, exposure, bloom and temporal reconstruction. Non-shadow-casting
shader graphs (cloud domes, bullet marks and muzzle cards) use a separate
depth-tested raster pass over the traced HDR. They do not enter the BVH or reset
surface accumulation. The ordinary main pass still owns their appearance when
tracing is disabled; failed tracing views also retain their raster overlays.
Primary, shadow and continuation rays intersect
the unculled world geometry; all valid extracted point, spot and directional
lights participate independently of the raster shadow-atlas budget. A stackless
depth-first BVH uses escape indices and leaves of at most four triangles. Direct
lighting evaluates every extracted light at each interaction, avoiding noise from
randomly selecting between the few authored lights.
Continuation rays sample a diffuse/GGX mixture, with Russian roulette after the
third interaction. Emission and escaped sky radiance contribute to the path.

PBR base color, metallic/roughness, normal and emission maps use a CPU-prepared
128-pixel tile atlas, with UV0/UV1 and per-slot transforms. Animated joint palettes
come from the same current CPU poses used to prepare raster skinning, not GPU
buffer mapping. Cast/receive flags and alpha tests are respected; alpha blending
uses stochastic straight-through coverage, without glass refraction.

## Interactive transport

Enable interactive transport on the camera's existing environment:

```swift
environment.pathTracing = .init(isEnabled: true, samplesPerPixel: 1,
    maximumBounces: 3, resolutionScale: 0.5)
environment.pathTracing.transport = .interactive
environment.pathTracing.radianceCache = true
```

The interactive estimator draws eight direct-light candidates at the first interaction and four at later interactions.
With one analytic light and emissive meshes it draws four candidates at the first interaction and two later.
It samples directional, point and spot lights and emissive mesh triangles. It traces visibility for up to one
candidate per interaction. This reduces shadow-ray work in many-light scenes and can introduce more per-frame
noise. Denoising or accumulation helps the samples converge. `.exhaustive` selects the analytic-light reference
estimator and is the default for saved scenes.

The world-space cache reuses lighting for broad diffuse paths on SAGA Vulkan with ray queries, a raster first hit and at
least three surface interactions. It uses about 4.5 MiB per view and warms over successive frames. The cache
keeps separate estimates for different remaining path lengths. Short segments, sharp lobes, disagreeing normals
and cold cells continue tracing. Camera motion preserves valid cells. Moving objects refresh affected probes against
current visibility, and lighting-only edits gradually refresh compatible probes. Changes to scene structure, sky or
bounce depth replace the cache history. On backends without the cache path, the interactive estimator traces
uncached. Set `radianceCache = false` to compare images or measure the uncached path.

Read `transport`, `radianceCache`, `radianceCacheBytes` and `radianceCacheFallback` on
`Render3DPathTracingStatistics.snapshots` to identify what encoded. Enable `radianceCacheDiagnostics` and call
`try await statistics.radianceCacheCounters(for: camera.id)` to download GPU probe hits, misses and updates on
demand. Counts describe the sampled GPU probes that warm the cache.

## First hit from the G-buffer

On devices with the extra G-buffer outputs, a traced view takes its first hit
from the raster G-buffer: position, normal, roughness and metallic as before, plus base colour and emission,
which the main pass writes for traced views only. Paths start tracing at the first bounce. The image keeps
the full detail of the rasterized model, and the denoisers' guides match the traced light exactly. Pixels the raster
pass left empty show the sky directly, so tracer-only proxies are never visible. Devices without the outputs trace
their primary ray as before.
`Render3DPathTracingStatistics` reports this as `hybridFirstHit`.

Because the first hit comes from raster, a scene can draw a detailed model while the tracer intersects a lighter
proxy for bounces and shadows. `PathTracingGeometry3D` marks an entity and its descendants:

```swift
detailed.components += PathTracingGeometry3D.rasterOnly      // drawn, not traced
proxy.components += PathTracingGeometry3D.pathTracingOnly    // traced, never drawn
```

The Sponza example rasters the full 8.8 M-triangle model and traces its 122 K-triangle lighting LOD this way.

## Denoising

`PathTracing3D.denoiser` selects how a view removes the noise of its few samples per pixel:

| Value | Behaviour |
| --- | --- |
| `.automatic` (default) | DLSS Ray Reconstruction when the camera uses DLSS temporal upscaling on a supported NVIDIA GPU and the G-buffer first hit is available. It traces at the DLSS input size. Other views use `.portable`. |
| `.rayReconstruction` | Ray Reconstruction, falling back to `.portable` with `denoiserFallback` set in the statistics. |
| `.portable` | Temporal reprojection and an edge-aware wavelet filter, on every backend. |
| `.off` | Plain accumulation of a still view, for reference renders. |

**Portable denoiser.** The tracer divides its light by the surface's base colour (so texture detail is never blurred),
then:

1. reprojects last frame's light through the world position;
2. rejects it where normal or camera distance disagree;
3. clamps it to the current neighbourhood's mean ± 2σ;
4. blends with weight `max(1/frames, minimumHistoryWeight)` (default 1/32);
5. filters with four à-trous iterations guided by normal, depth and local luminance variance;
6. multiplies the base colour back and adds emission.

Camera, light and object motion keep history (moving objects use a higher history weight so the new lighting follows
quickly, and the reprojection guides reject history that no longer matches); adding or removing a mesh, or changing a
light, material or setting, restarts it. Plain accumulation (`.off`) restarts on any change, including motion. On an RTX 4070 at 1260×523 the chain costs about 1.1 ms of GPU time.

**Ray Reconstruction.** The tracer writes fresh noisy samples each frame along with diffuse albedo, specular albedo
and world normals with roughness as guides. Specular albedo incorporates the view angle and roughness. A bridge that exposes
the optional hit-distance input also receives the first sampled specular hit's distance in world units. A specular
ray that escapes uses the configured maximum ray distance, and pixels with no specular sample use zero.
DLSS Ray Reconstruction then denoises and upscales in one step, replacing Super Resolution for that view. See [DLSS](DLSS.md) for its runtime.

**`.off`.** Plain accumulation restarts on any camera, projection, geometry, pose, material, light or sky change.

Ray Reconstruction always traces at its DLSS input size; `resolutionScale` applies to the other denoisers.
The portable history age is capped at 1024 frames.

Each camera owns its accumulation, guide and filter textures; resizing or disabling releases them. Changed
geometry refits the CPU hierarchy; count changes and periodic rebuilds refresh its partitioning. A geometry-aware
four-tap reconstruction brings a reduced `resolutionScale` back to output resolution.

`Render3DPathTracingStatistics.snapshots` reports actual encoded frames, resets,
accumulation, triangles, lights, traced dimensions, the implementation (`vulkan-ray-query` or
`portable-shader-bvh`), why hardware ray queries were not used (`intersectionFallback`) and a
failure reason. Unsupported scenes report a reason and retain raster surface
lighting. The dedicated presentation shader does not restore SSR or procedural
sky on that fallback.

Current limits:

- 1–8 samples/pixel and surface interactions; the default three interactions
  allow two indirect surface bounces. Radiance and ray distance are bounded.
- Up to 131072 placed triangles in the portable BVH, or 1,398,101 shared triangle records
  and 1,048,576 placed parts with Vulkan ray queries. Each view supports up to 256 texture atlas tiles.
  When the scene exceeds a budget, the status reports the reason.
- Vulkan ray queries can sample authored terrain layer weights and paint. Layered terrain uses the raster
  fallback on the portable BVH.
- Moving geometry currently prepares CPU triangles and uploads them. The shader BVH refits; the hardware path
  instead rebuilds a top-level acceleration structure over per-part bottom-level structures. There is no GPU
  skinning or refit: skinned meshes make a view use the shader BVH.
- Mesh morph targets and shadow-casting custom shader graphs reject the tracing view explicitly.
  Clearcoat, sheen, anisotropy, parallax, vertex color and emissive thresholds
  are not reproduced by the base metallic/roughness tracing material.
- Atlas textures repeat and use a downsampled level zero; arbitrary sampler
  address modes, mip gradients, HDR material texture values and in-place texture
  edits are not reproduced. Replacing a texture refreshes its atlas tile.
- The interactive estimator caps its emissive proposal at 65,536 eligible triangles. A scene beyond that cap uses
  BSDF hits for emissive surfaces and reports `emissiveSamplingFallback`. Environment radiance is sampled when
  a ray escapes. Radiance clamping and the diffuse cache introduce approximation error.
- The denoisers trade noise for lag. The portable history weight and clamp follow moving lights within a few frames,
  and disocclusions start from one sample.
- The G-buffer first hit uses base metallic/roughness, base colour and emission; clearcoat, sheen and anisotropy
  are not reproduced there either.
- Cosmetic shader graphs, particles, analytic/volumetric fog, raster depth/motion guides and overlays
  remain in the existing renderer. This is surface transport, not a completely
  ray-traced renderer for every effect.

Tests are in `Render3DPathTracingTests.swift`: old scene compatibility and bounds,
BVH coverage, fresh SPIR-V/WGSL, offscreen shadow blockers without shadow maps,
light-off history invalidation, hidden diffuse bounce, offscreen metallic
reflection, spot cones, material textures, resolution changes and depth-tested
opaque/blended graph overlays. GPU tests live
under the serialized `Render3DGPUTests` suite.
