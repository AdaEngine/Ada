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

## Check what ran

`Render3DPathTracingStatistics`, a resource of the render world, reports per view which traversal ran and why hardware
was not used:

```swift
if let status = statistics.snapshots[String(cameraID)] {
    print(status.implementation)            // "vulkan-ray-query" or "portable-shader-bvh"
    if let reason = status.intersectionFallback { print("Hardware not used: \(reason)") }
}
```

A view reports a reason when the device has no ray queries, when the scene has skinned meshes, or when a build or shader
failure turned hardware off (it then stays off for the rest of the session). Asking for `.software` reports no reason.

## What the hardware path does

- Each mesh part gets one bottom-level acceleration structure, built once from its geometry and shared by every
  placement of that part. Parts that disappear release theirs.
- The top-level structure lists every placed part with its transform. It is rebuilt when the scene changes and keeps
  its capacity otherwise.
- Shading, lights, the sky, the denoisers and DLSS Ray Reconstruction read the same triangle and material tables as the
  shader BVH, so the picture matches it. Alpha-tested and stochastically transparent materials, single-sided surfaces and
  shadow-caster filtering follow the same rules.

## Limits

- Meshes with skinning make the view use the shader BVH. Morph targets already reject tracing, as before.
- The scene budget is unchanged: 131072 triangles.
- The CPU still prepares the shading tables when the scene changes, so hardware saves the BVH work, not that preparation.
- Performance depends on the scene. On the author's RTX 4070, in a synthetic scene of about 85 thousand triangles at
  640 by 480 (unoptimized build, wall-clock time per frame including CPU work), hardware was clearly faster when the
  trace was the bottleneck (8 samples per pixel: about 30 to 45 percent less frame time). At 2 samples per pixel it was
  about 5 percent slower with double-sided materials and up to about 18 percent slower with single-sided materials. When
  one object moved every frame it was 11 to 14 percent faster. Measure your own scene, and set `.software` if hardware
  is slower for you.
- Hardware ray queries are used on the Vulkan renderer only.
