# Portable world-space path tracing

This experimental mode traces actual scene triangles in a fragment shader BVH on
the existing Metal/WebGPU renderer. It does not use RTX/DXR/Metal hardware ray
intersection units. It is a correctness and integration starting point, not a
claim of Doom or Indiana Jones performance or image quality.

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

## First hit from the G-buffer

On devices with the extra G-buffer outputs (verified on native WebGPU; Metal is not yet verified), a traced view takes its first hit
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
| `.automatic` (default) | DLSS Ray Reconstruction when the camera uses DLSS temporal upscaling on a supported NVIDIA GPU and the tracer runs at input size (`resolutionScale` 1); otherwise `.portable`. |
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

Camera and light motion keep history; adding, removing, switching or retuning a light, scene, material or setting
changes restart it. On an RTX 4070 at 1260×523 the chain costs about 1.1 ms of GPU time.

**Ray Reconstruction.** The tracer writes one fresh sample per frame and diffuse albedo, specular albedo and world
normals with roughness as guides. DLSS Ray Reconstruction then denoises and upscales in one step, replacing Super
Resolution for that view. See [DLSS](DLSS.md) for its runtime.

**`.off`.** Plain accumulation restarts on any camera, projection, geometry, pose, material, light or sky change.

Ray Reconstruction always traces at its DLSS input size; `resolutionScale` applies to the other denoisers.
The portable history age is capped at 1024 frames.

Each camera owns its accumulation, guide and filter textures; resizing or disabling releases them. Changed
geometry refits the CPU hierarchy; count changes and periodic rebuilds refresh its partitioning. A geometry-aware
four-tap reconstruction brings a reduced `resolutionScale` back to output resolution.

`Render3DPathTracingStatistics.snapshots` reports actual encoded frames, resets,
accumulation, triangles, lights, traced dimensions, implementation name and a
failure reason. Unsupported scenes report a reason and retain raster surface
lighting. The dedicated presentation shader does not restore SSR or procedural
sky on that fallback.

Current limits:

- 1–8 samples/pixel and surface interactions; the default three interactions
  allow two indirect surface bounces. Radiance and ray distance are bounded.
- 131072 triangles, 256 texture tiles. There is no silent geometry truncation.
- Moving geometry currently prepares CPU triangles, refits the BVH and uploads it; there is no
  BLAS/TLAS instancing, GPU skinning/refit or hardware RT acceleration.
- Mesh morph targets and shadow-casting custom shader graphs reject the tracing view explicitly.
  Clearcoat, sheen, anisotropy, parallax, vertex color and emissive thresholds
  are not reproduced by the base metallic/roughness tracing material.
- Atlas textures repeat and use a downsampled level zero; arbitrary sampler
  address modes, mip gradients, HDR material texture values and in-place texture
  edits are not reproduced. Replacing a texture refreshes its atlas tile.
- Emissive surfaces and the environment have no next-event importance sampling;
  small emitters can be very noisy. There is no ReSTIR/MIS. Radiance clamping and finite path length introduce bias.
- The denoisers trade noise for lag: the portable history weight and clamp follow moving lights within a few frames,
  and disocclusions start from one sample. Every light is still sampled at every bounce, which dominates trace cost.
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
