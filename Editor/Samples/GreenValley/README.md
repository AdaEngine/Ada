# Green Valley

Green Valley is a 4 km square AdaEngine map. A trail winds between a meadow, deciduous woodland and a hilltop. Three terrain sources provide the ground, forest and grass. The trail soil is painted into the terrain's canonical material field, which all render LODs share. Short modeled blades fill the trail shoulders, and tall grass covers the surrounding terrain. Textured Poly Haven specimens grow along the trail. The terrain and vegetation are generated from a fixed seed.

## Play

Open this directory in Ada Studio and press Play. Use W/S to move forward or backward and A/D to move sideways. Press F to switch between free flight and walking. In free flight, Space climbs, Ctrl descends, and Shift flies faster. R starts a guided walk and G starts the guided flyover. A movement key takes over from either guided route.

The standalone Swift player uses the same terrain, vegetation and trail. Run from the AdaEngine repository root with the engine's configured Swift toolchain and native dependencies.

```sh
swift run --package-path Editor/Samples/GreenValley/Standalone -c release GreenValley
```

The Windows build uses SAGA Vulkan. In the standalone player, hold the right mouse button to look and Shift to walk faster. Free flight uses the camera heading and keeps the current viewpoint when activated. Press F again to land directly below the camera. The walker samples the loaded terrain triangles. The default camera starts at eye level on the trail. Set `GREEN_VALLEY_ROUTE` to `walk` or `fly` before launch to reproduce a guided route from the start. The player also finds terrain installed in `Assets/Terrain` beside its executable. Set `GREEN_VALLEY_TERRAIN` to override that location.

In standalone, click **Switch to Path Tracing** or press **P**. Loading the full terrain and forest precedes the first traced frame. The status identifies the active renderer or reports the reason for a raster fallback. Click again to restore raster streaming at the current camera position. Distance-based terrain LOD keeps the full 4 × 4 km landscape visible. Height fog starts 70 m from the camera and blends the forest into the outer hills. Grass bends with wind in the standalone raster player. Path tracing holds a still wind pose while it accumulates samples.

The standalone raster player also draws a distant canopy from the same tree placements. The generator samples crowns on a 2.5 m voxel grid and bakes opaque meshes with 12 triangles per crown. The farthest trees share one crown per occupied 20 m patch. Tiles appear when their far edge approaches the source trees' 440 m or 950 m draw distance. Fly upward with **F** and **Space** to see the canopy across the hills. Path tracing uses the original tree meshes across the map.

## Vegetation assets

The following specimens are bundled with the project under [Poly Haven's CC0 license](https://polyhaven.com/license). Counts are triangles in the actual GLBs shipped with Green Valley. The models share geometry across placements. Imported model textures and foliage masks are embedded in the GLBs.

| Model and source | In-game triangles | Detail distance |
| --- | ---: | ---: |
| [Island Tree 02](https://polyhaven.com/a/island_tree_02) by Rob Tuytel and Rico Cilliers, detailed / grove / distant models | 62,483 / 4,426 / 1,145 | 68 / 440 / 950 m |
| [Wild syringa, Tree Small 02](https://polyhaven.com/a/tree_small_02) by Rico Cilliers | 73,990 | 60 m |
| [Shrub 02](https://polyhaven.com/a/shrub_02) by Rico Cilliers | 7,590 | 35 m |
| [Fern 02](https://polyhaven.com/a/fern_02) by Rico Cilliers and Rob Tuytel | 2,384 | 80 m |
| [Grass Medium 01](https://polyhaven.com/a/grass_medium_01) by Rico Cilliers and Rob Tuytel | 1,257 | 90 m |

The wild syringa was simplified from the 2,062,487-triangle public glTF using gltfpack 1.3. Each understory GLB contains one specimen from the source model sheet. The sample also includes its own oak, birch, hazel, grass and golden flowers. Forest.aterrain contains 152,167 tree placements spread across 36 regions. Each coastal tree uses indexed trunk, branches and leaf geometry. Fly around a tree to see its crown from different angles. Tall grass clumps cover the playable map out to 125 m from the camera. Closer-spaced meadow patches along the route reach 150 m. Grass blades and fern patches reach 120 m and 105 m. Ground and trail surfaces use [Leafy Grass](https://polyhaven.com/a/leafy_grass) by Charlotte Baglioni and [Grass Path 2](https://polyhaven.com/a/grass_path_2) by Rob Tuytel.

## Regenerate and validate

The included assets are ready to play. Run the generator from any directory with Python 3 to rebuild the generated layout and meshes. It reuses the included imported GLBs and texture images. It uses a fixed seed, 256 height tiles and a shared color palette texture per generated mesh. Vegetation records use region-local coordinates. Trees, shrubs and ground cover have independent draw distances. Coarse distant hills extend beyond the edge of the playable heightfield.

```sh
python Editor/Samples/GreenValley/generate.py
python script/test_large_terrain_showcase.py
adastudio validate --project Editor/Samples/GreenValley --lint strict
```

## Measure

Use a standalone Release build at 1920 × 1080 with the RTX 4070 selected. Start each route in a fresh process. Allow startup to finish, then capture the foreground player's process ID with PresentMon. Record the display refresh rate, the active route, the window's client size and the game revision. Inspect the average, p99 and worst presentation intervals, GPU busy time, and count of frames above one sixtieth of a second. Repeat each route three times. The walking route crosses the center of the map and continues into another terrain region. The flyover reaches the northern hills in about 43 seconds of simulation time. [Windows capture guide](../../Documentation/WindowsPerformance.md)
