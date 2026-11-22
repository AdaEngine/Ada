# Full-map path tracing for Green Valley

Proposed extension to [hardware path tracing](hardware-path-tracing.md) for the [Green Valley showcase](large-terrain-showcase.md). Target hardware is the Windows RTX 4070 running SAGA Vulkan.

## Player experience

A single button or P switches between raster and path tracing from the current camera. The status displays preparation, active tracing after a successfully encoded frame, or the specific fallback reason. Walking, flying and switching back preserve position, orientation and the route. The entire four-kilometre map participates in ray intersections, including terrain, trees outside the camera frustum, and their shadows. Both modes use the map's authored tree meshes, transforms and alpha masks. Grass retains its authored visibility distances. Interior forest views and distant hills retain their atmosphere.

## Renderer changes

Today the shared scene preparer rejects layered terrain and counts every repeated tree against a 131,072-triangle limit. Even the hardware backend depends on that expanded representation. Raising the limit alone would increase CPU preparation and memory with every tree.

For Vulkan ray queries, AdaCorePipelines builds reusable bottom-level acceleration structures and local-space shading buffers per distinct mesh. Top-level instances reference them and carry the placement transform, tint and material selection. Shaders decode instance and primitive IDs to fetch geometry, normals, UVs and sidedness. Support masked foliage for both primary and shadow rays. Cache geometry across frames and update placements when the scene changes.

The terrain system supplies traceable geometry and layer weights for all map regions, including areas outside the raster residency radius. Use a coarse whole-map terrain surface while detailed tiles stream, preserve continuous coverage and avoid duplicate intersections at transitions. Use the same authored heightfield, splat weights, paint textures and trail in both renderers. Keep full-map tree placements resident for secondary rays. Apply the authored height fog and sky consistently. Manage builds across frames, account for actual memory and report failures with a route back to raster. Other backends keep their existing behavior.

## Acceptance

- On the RTX 4070, walk and fly across region boundaries, including the far edge. Capture a real hardware-traced frame on each route and verify the per-camera Vulkan implementation, encoded frame count and lack of fallback.
- Verify tree prototype counts and placement transforms against the map. Compare foliage cutouts, terrain layer blends, shadows from outside the camera frustum, fog and hill silhouettes at matched camera poses.
- Toggle both ways repeatedly and during initial preparation. Verify unchanged camera and controls, bounded memory across cycles and release of acceleration structures.
- Measure raster and traced frame intervals separately at 1920 × 1080, recording internal scale, samples, bounces, GPU memory and worst frame. The 60 FPS target applies to the playable raster routes. Publish the measured traced performance.
- Add GPU regression fixtures for repeated geometry exceeding the expanded triangle limit, alpha-masked instances and layered terrain across region boundaries. Update the existing Path Tracing and Terrain guides with the button, status meanings, hardware scope and a reproducible Green Valley example. Verify DocC navigation, both guides and the example in the standalone executable.
