# Frustum and LOD validation

macOS/Metal, Apple M3 Pro, fixed 2200x1520 garden capture. Both robot poses, camera, lighting and render quality remain fixed.

| Main camera | Unoptimized | Culling + LOD + distance |
| --- | ---: | ---: |
| Candidates | 486 | 486 |
| Visible mesh entities | 486 | 206 |
| Triangles submitted | 30489 | 15803 |
| Draw calls | 159 | 121 |

Triangle reduction: 48.2%. Draw-call reduction: 23.9%. Optimized LOD distribution: [166, 37, 3].

The same LOD/distance configuration with frustum culling disabled produced a bit-identical final frame (zero changed pixels). The camera rejected 271 mesh entities by frustum and 9 by distance, while the far shadow cascade retained 474 meshes. This verifies that camera visibility does not remove offscreen casters.

LOD can split batches by mesh level: distant cascade draw counts can increase even while triangle counts fall. The LOD-only camera control with culling retained used 17,684 triangles/112 draws; enabling LOD reduced that to 15,803 triangles while splitting it into 121 draws. Counters distinguish mesh entities from prefab roots, and GPU shader cost is not inferred from triangle-count reduction.

Captures/counters: dist/captures/visibility, unoptimized and no-culling. MeshVisibilityLOD3DTests verify clip planes, transformed nonuniform bounds, per-camera/cascade compact buffers, hysteresis, distance cuts and posed influence envelopes. GardenTerrainTests verifies exact boundary vertex equality between neighboring LODs. Khronos validation: Tree/Rock LOD0/1/2 all zero errors/warnings.

This implementation submits CPU-culled draw lists. GPU occlusion/Hi-Z, indirect draws and character mesh/animation LOD are outside this slice.

Final regression run: 1235 tests in 214 suites passed. Targeted SwiftLint and git diff --check passed. The Metal scene also passed the scripted character/camera/jump/terrain route with the optimized renderer enabled.
