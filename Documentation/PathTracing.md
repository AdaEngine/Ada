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

Each camera owns two HDR accumulation textures and one spatial filter target. Unjittered camera/projection,
geometry/pose/material/light/sky changes reset accumulation; presentation jitter
can still vary between accumulated samples. Resize and disabling release a
view's history. Changed geometry refits the CPU hierarchy; count changes and
periodic rebuilds refresh its partitioning. Bounds/centers are cached during
building. A normal/depth/roughness-guided 5x5 filter with bounded anti-firefly
weighting runs after raw accumulation, retaining sharp mirror samples. A
geometry-aware four-tap reconstruction follows it; DLSS/TAA can reconstruct the
finished frame using the existing raster depth and motion guides.

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
  small emitters can be very noisy. There is no ReSTIR/MIS or dedicated temporal
  denoiser. Radiance clamping, anti-firefly filtering and finite path length introduce bias.
- Continuous camera/pose changes restart static accumulation. Temporal
  reconstruction is not a replacement for a lighting denoiser.
- Cosmetic shader graphs, particles, analytic/volumetric fog, raster depth/motion guides and overlays
  remain in the existing renderer. This is surface transport, not a completely
  ray-traced renderer for every effect.

Tests are in `Render3DPathTracingTests.swift`: old scene compatibility and bounds,
BVH coverage, fresh SPIR-V/WGSL, offscreen shadow blockers without shadow maps,
light-off history invalidation, hidden diffuse bounce, offscreen metallic
reflection, spot cones, material textures, resolution changes and depth-tested
opaque/blended graph overlays. GPU tests live
under the serialized `Render3DGPUTests` suite.
