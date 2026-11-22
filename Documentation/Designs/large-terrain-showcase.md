# Large Terrain and Vegetation Showcase

Status: Proposed for approval

Date: 2026-11-18

## Goal

Build an original playable AdaEngine landscape with dense vegetation nearby and
continuous forest cover on distant slopes. The first target is a 4 × 4 km map
running at 60 FPS or higher on the contributor's Windows PC at native 1920 × 1080
in a standalone Release build. The target machine has a Ryzen 9 7900X and an
RTX 4070. The first version covers Windows with SAGA Vulkan.

## Landscape and player experience

The player starts on a meadow overlooking a forested valley and can walk across
the meadow, follow a trail into the forest, and climb to a viewpoint. A flyover
covers multiple terrain regions and looks across the valley. The center of the
map has the most variety, with long grass, wildflowers, shrubs, mixed deciduous
trees, and clearings. Distant hills remain visibly forested. Generate the terrain
and placement data from a fixed seed so the same build reproduces the views and
measurement route. Use original or appropriately licensed models and textures.

[Chlorophyll's close meadow](https://www.youtube.com/watch?v=VC_NUxbeA0E&t=394s)
and [its forest canopy from above](https://www.youtube.com/watch?v=VC_NUxbeA0E&t=175s)
are visual references for density and distance. The author's description explains
that distant trees are replaced by a streamed tile-level voxel representation.
Use the resulting continuous forest silhouette as a visual target. Tree count
will be reported as a workload metric.

## Runtime approach

- Generate a heightfield `.aterrain` and its region data offline. Load it through
  `Terrain3DSource` with bounded streaming and the existing ground mesh LOD.
- Start with existing spatial instancing for vegetation. Give nearby plants
  enough geometry to read at walking speed. Limit fine grass and flower meshes
  to the near field, with a ground material that matches their color at distance.
- Use simpler representations for mid-distance tree canopy and grouped canopy
  meshes for the horizon where individual crowns occupy only a few pixels.
  Prototype these using sample-authored assets and the existing renderer. Inspect
  the route for visible holes and abrupt transitions between ranges.
- The existing renderer accepts projected-size mesh alternatives for instanced
  batches. Terrain batches currently carry a maximum draw distance. If the sample
  needs per-instance LOD selection, assess connecting existing mesh alternatives
  to terrain batches before designing a separate vegetation renderer.
- Keep ground collision available to the walker. Give decorative plants a
  visual-only role and limit tree collision and shadow distance to where they
  affect the route. Record the settings used in the performance captures.
- Use the existing runtime and asset formats for the first pass. If baseline
  traces show a renderer or streaming bottleneck that content and configuration
  cannot address, use those traces to scope a runtime improvement. A dynamic
  voxel hierarchy would require new cache, memory, LOD, and platform contracts.

## Acceptance

1. The sample opens in Ada Studio and runs standalone from a clean checkout with
   its asset references intact. The walk and flyover show the same placement
   decisions across repeated runs. At terrain region boundaries, verify continuity
   of ground, collision on the walking route, and distant vegetation.
2. Run reproducible walking and flyover routes in standalone Release on the
   RTX 4070 at 1920 × 1080, with the display refresh rate at or above 60 Hz.
   Capture each route three times, recording when startup ends and timing starts.
   Each timed route must introduce previously nonresident regions so the capture
   includes streaming. Capture enough time to reach the dense forest and cross
   several region boundaries. Record cold launch separately.
3. The target is a frame every 1/60 second across the timed routes. Record
   PresentMon frame intervals, average FPS, p95, p99, worst interval, and the
   number of intervals above 1/60 s. Use unpaced present timing for the
   performance gate and record a display-paced run for visual inspection.
   Record the GPU, driver, resolution, render settings, and exact revision.
   Follow the [Windows capture guide](../../Editor/Documentation/WindowsPerformance.md).
   Capture terrain residency, instance and draw counts, and CPU/GPU timing when
   diagnosing misses. The existing 100,000-instance benchmark measures a
   synthetic workload and can assist diagnosis. The playable routes determine
   whether this showcase meets the target.
4. Include a ground-level screenshot and a distant view, plus the timing
   summary and raw capture location. Review the captures for sparse patches in
   the dense forest, terrain seams, and visible loading gaps.

## User documentation

Add a section to the existing
[Terrain guide](../../Sources/AdaEngine/AdaEngine.docc/Articles/3D/Terrain.md)
with a link to the sample, its controls, generation steps, and the Windows
performance capture procedure. The guide is reachable from the AdaEngine DocC
Topics page. Include a sample README with the same launch and measurement entry
points. Verify the project with `adastudio validate --project`, then launch
standalone and exercise both routes. Run the contribution documentation checks
for the guide and verify the sample link in the generated DocC output.
