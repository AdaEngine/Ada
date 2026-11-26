# Hardware Path Tracing

Let a path-traced view find ray intersections with the GPU's ray-tracing hardware instead of a shader BVH. The image,
lighting and denoisers stay the same; only the intersection step changes, and the shader BVH remains the fallback
wherever hardware cannot be used.

## Requirements

- The Vulkan renderer (Windows or Linux) on a device that supports ray queries. It has been verified on an NVIDIA
  GeForce RTX 4070 only.
- Path tracing enabled on the view's environment. See the path tracing guide for the tracer itself.

Metal, D3D12, Android and the browser keep the shader BVH.

## Choose the intersection

`PathTracing3D.intersection` selects the traversal:

```swift
environment.pathTracing = .init(isEnabled: true, samplesPerPixel: 4, maximumBounces: 3, resolutionScale: 0.5, historyLimit: 32)
// .automatic is the default: hardware when the device and the whole view can use it, otherwise the shader BVH.
environment.pathTracing.intersection = .automatic
// Force the shader BVH, for reference renders or to compare the two.
environment.pathTracing.intersection = .software
```

A view falls back to the shader BVH as a whole; it never mixes the two in one frame. Switching between them restarts the
view's accumulation, like any other scene change.

## Use interactive lighting

```swift
environment.pathTracing = .init(isEnabled: true, samplesPerPixel: 1,
    maximumBounces: 3, resolutionScale: 0.5)
environment.pathTracing.transport = .interactive
environment.pathTracing.radianceCache = true
```

Interactive transport samples an analytic light or an emissive triangle at each interaction. It can run with the
shader BVH or hardware ray queries. Existing scenes decode to `.exhaustive`, which evaluates every analytic light.
With one analytic light and emissive meshes, the interactive sampler draws proposals from both groups at each
interaction. This uses a smaller sample budget and preserves the proposal weights.

The optional world-space radiance cache needs Vulkan ray queries, the raster G-buffer first hit and at least three
surface interactions. It reuses diffuse lighting after warming, including at the last eligible hit within the bounce
limit. On smooth surfaces that use the cache, the tracer still evaluates specular lighting and follows specular paths.
The cache uses about 4.5 MiB per active view. Use
`radianceCache = false` for an uncached comparison. On compatible Windows systems, the same transport can feed
DLSS Ray Reconstruction. Use an updated NGX bridge to receive the optional specular hit distance guide.

The cache retains compatible probes while objects move. During motion it refreshes probes against current visibility,
reduces their lifetime and weighs new samples more heavily. A lighting-only edit gradually refreshes existing diffuse
probes against the new light. During this refresh, a compatible probe may provide its deepest estimate when the
path needs one more interaction than the cache stores. Changes to scene structure, sky or bounce depth start a new
cache history.
With interactive Ray Reconstruction, switching an analytic light or adjusting a mesh emitter's emission keeps the
history needed for reprojection. Rays can respond to the new light on the next frame.

When the Vulkan scene has only opaque, double-sided surfaces without per-mesh tracing distance limits, the
device accepts hits during traversal. Mixed scenes use the shader's alpha, face and distance checks.

## Benchmark on Windows Vulkan

The standalone `SolariComparison` demo accepts `--uncapped --benchmark 300` to request immediate presentation and record
300 intervals after warm-up. It reports output size, trace size, the mean and 95th-percentile intervals, and the rates
of encoded frames and completed scene textures that reach the view. The renderer logs the selected presentation mode.
The renderer uses FIFO when the Windows Vulkan surface lacks immediate presentation support.

Run a separate diagnostic pass with `--gpu-timing` to read Vulkan timestamps. The tracer's interval
starts at its first timed GPU pass and ends at its last. Acceleration structure builds before that
interval and window presentation are outside the measurement.

## Check what ran

`Render3DPathTracingStatistics`, a resource of the render world, reports per view which traversal ran and why hardware
was not used:

```swift
if let status = statistics.snapshots[String(cameraID)] {
    print(status.implementation)            // "vulkan-ray-query" or "portable-shader-bvh"
    if let reason = status.intersectionFallback { print("Hardware not used: \(reason)") }
    print(status.radianceCache ?? "disabled")
    if let reason = status.radianceCacheFallback { print(reason) }
}
```

A view reports a reason when the device has no ray queries, when the scene has skinned meshes, or when a build or shader
failure turned hardware off (it then stays off for the rest of the session). Asking for `.software` reports no reason.

## What the hardware path does

- Each mesh part gets one bottom-level acceleration structure, built once from its geometry and shared by every
  placement of that part. Parts that disappear release theirs.
- The top-level structure lists every placed part with its transform. It is rebuilt when the scene changes and keeps
  its capacity otherwise.
- Instances share local-space shading tables and carry their own transforms, material, and shadow flags.
  Alpha-tested and stochastically transparent materials, single-sided surfaces and shadow-caster filtering
  use the same rules as the shader BVH.
- Layered terrain reads its authored layer IDs, weights, palette textures and paint on hardware ray hits.
  The portable shader BVH falls back to raster for views with layered terrain.

## Limits

- Meshes with skinning make the view use the shader BVH. Morph targets already reject tracing, as before.
- The shader BVH budget is 131072 placed triangles. Vulkan ray queries have a separate budget of 1,398,101
  triangles in the shared shading table and up to 1,048,576 placed parts. Repeated placements can share triangles.
- Large scene changes can prepare geometry over several frames. The view uses raster rendering while preparation runs.
- Performance depends on the scene. On the author's RTX 4070, in a synthetic scene of about 85 thousand triangles at
  640 by 480 (unoptimized build, wall-clock time per frame including CPU work), hardware was clearly faster when the
  trace was the bottleneck (8 samples per pixel: about 30 to 45 percent less frame time). At 2 samples per pixel it was
  about 5 percent slower with double-sided materials and up to about 18 percent slower with single-sided materials. When
  one object moved every frame it was 11 to 14 percent faster. Measure your own scene, and set `.software` if hardware
  is slower for you.
- Hardware ray queries are used on the Vulkan renderer only.
