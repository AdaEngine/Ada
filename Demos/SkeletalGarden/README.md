# Skeletal Garden

A native AdaEngine demo for skeletal GLB import, clip playback, cross-fading, GPU skinning, independent model instances, and animated directional shadows. The scene uses the CC0 Quaternius RobotExpressive character and six original textured garden props and original low-poly trees, rocks and grass. Provenance and processing recipes are in `SourceAssets/ASSETS.md`.

Run from the AdaEngine repository root:

```sh
Demos/SkeletalGarden/script/build_and_run.sh
```

- WASD: camera-relative movement through the courtyard and surrounding hills.
- Shift: run. Idle, Walk, and Run fade over 0.22 seconds, retain walk/run cycle phase and match playback speed to actual movement.
- Space: jump on a press edge. R: reset to the starting position.
- Drag with the left mouse button: orbit the camera. Q/E: zoom in/out. A sphere sweep pulls the camera in around obstacles and eases it back out.
- Jump, Fall and Land are separate non-looping poses, blended from the actual grounded/vertical state.
- The second humanoid plays its own Walk clip at a different speed.
- Wood/stone props demonstrate color, ORM and normal maps; plants demonstrate alpha mask and double-sided leaves; the lantern demonstrates constant emission.

The scene uses offline-baked diffuse irradiance, GGX-prefiltered HDR reflections and a split-sum BRDF LUT. SSR stays disabled while IBL is active to keep lighting independent of screen visibility. The robot uses AdaPhysics’s fixed-step upright capsule controller: gravity, acceleration/braking, sweep collision, overlap recovery, wall sliding and grounded jumps. The props have explicit world-space collision proxies; the courtyard has a solid floor and visible raised borders. Animation follows collision-resolved speed, so the robot returns to Idle when blocked.

The first controller does not auto-step stairs, ride moving platforms, push dynamic bodies or collide with other controller capsules. Use it on a root entity without a PhysicsBody3DComponent; capsule dimensions are world units independent of visual scale. The second robot has a static collision proxy.

## Expanded landscape

The garden is 48x48 meters (16 times the original courtyard area), with a flat 12x12 plaza, rolling hills up to about 3.4m, a shallow lowland pond, a winding gravel trail, five jumping terraces, an elevated lookout and a stone gateway. A deterministic layout places 65 trees, 42 rocks and 193 grass tufts. The renderer and static Box3D collider share the same height geometry and triangle split. Collision uses 8192 triangles; rendering omits the triangles under the textured plaza. Scenery placement interpolates that exact surface. Trees include trunk/canopy collision proxies.

The controller snaps vertically onto descending walkable terrain without injecting lateral speed. Fixed simulation catches up at lower render rates (up to eight ticks after a stall); all fixed systems receive the same 1/60s delta.

## Validation modes

```sh
Demos/SkeletalGarden/script/build_and_run.sh --verify
Demos/SkeletalGarden/script/build_and_run.sh --capture
Demos/SkeletalGarden/script/build_and_run.sh --capture-overview
Demos/SkeletalGarden/script/build_and_run.sh --capture-no-ibl
Demos/SkeletalGarden/script/build_and_run.sh --debug
```

`--verify` drives the same controller/animation systems through a scripted crate collision, movement/braking and jump/landing and terrain traversal sequence; it also checks camera occlusion and all three air clips. It fails unless all runtime position, velocity, grounded and clip checks pass. `--capture-overview` captures the whole landscape under `dist/captures/overview`. `--capture` fixes the camera and character root, plays skeletal poses, and saves two PNGs under `dist/captures` directly from the Metal render target. The readback uses the render graph's command queue and waits asynchronously for completion. It does not capture the desktop.

The script stages `dist/SkeletalGarden.app`, including SwiftPM resource bundles, and launches it with macOS Launch Services. Logs are under `dist`. It only restarts the SkeletalGarden process. The build defaults to a dedicated `/tmp/adaengine-skeletal-import-build` scratch path; set `ADAENGINE_SKELETAL_BUILD_PATH` to override it.

The initial runtime supports four vertex influences and at most 128 joints per skin. TRS tracks support LINEAR, STEP, and CUBICSPLINE, including quaternion slerp and cubic tangent scaling. Per-instance palettes use frame-buffered GPU allocations and are shared by the PBR and directional-shadow passes. Static meshes keep the identity skinning path.

Useful regression suites: `SkeletalAnimationTests`, `SkeletalModel3DTests`, `GLTFSkeletalImportTests`, and `Model3DRenderItemsExtractionTests`, `CharacterController3DTests`, and `Physics3DTests`, `Physics3DGeometryTests`, `FixedPhysicsCatchUpTests`, and demo-owned `GardenTerrainTests`.

`--capture-no-ibl` captures a control scene under `dist/captures/no-ibl`. The generator/profile tools are reproducible:

```sh
python3 Tools/3DAssets/prepare_robot.py
/Applications/Blender.app/Contents/MacOS/Blender --background --factory-startup --python Tools/3DAssets/generate_landscape_assets.py
/Applications/Blender.app/Contents/MacOS/Blender --background --factory-startup --python Tools/3DAssets/generate_garden_assets.py
```

The glTF material path imports AO/ORM, normal scale, emission factors and KHR_materials_emissive_strength, OPAQUE/MASK/BLEND, alpha cutoff, double-sided flags, UV0/UV1, wrap/filter settings and color-correct mipmaps. Alpha mask is applied in both PBR and animated-shadow passes. Transparent instances render after opaque geometry with depth writes disabled. IBL maps are loaded once from `.ibl` manifests; integrations are offline, not per-frame shader loops.

## Render quality

The demo enables three stabilized directional-shadow cascades (1024px per tile, a 3072x1024 atlas), half-resolution SSAO with depth/normal-aware bilateral filtering and upsampling, and spatial FXAA after tone mapping. Other scenes keep the source-compatible defaults: one shadow map, SSAO disabled, AA disabled. Settings are per camera in Environment3D.

1 toggles sunlight shadows, 2 toggles SSAO, 3 toggles FXAA, 4 switches one/three shadow cascades. These switches do not change scene geometry or animation. SSAO attenuates the opaque indirect-light buffer; direct lighting and emission remain separate. Transparent foreground attenuates that buffer and preserves the opaque normals/positions underneath. FXAA runs before UI/2D content and has no temporal history.

```sh
Demos/SkeletalGarden/script/build_and_run.sh --capture-quality
Demos/SkeletalGarden/script/build_and_run.sh --capture-baseline
Demos/SkeletalGarden/script/build_and_run.sh --capture-no-ao
Demos/SkeletalGarden/script/build_and_run.sh --capture-no-aa
Demos/SkeletalGarden/script/build_and_run.sh --capture-single-shadows
Demos/SkeletalGarden/script/build_and_run.sh --capture-no-shadows
```

These modes freeze both robots and the camera, capture frames 30/50 and write GPU timings after frame 160. Baseline retains the original single shadow map and disables SSAO/FXAA. Files are under dist/captures/<mode>. Profiling serializes GPU passes only in these measurement modes, records Metal hardware timestamps and discards 20 warmup samples per pass. Min/mean/max are pass durations, not a universal FPS estimate; normal play keeps asynchronous GPU submission. Backends without timestamps report unavailable.

Focused regression suites: CascadedShadow3DTests and RenderQuality3DIntegrationTests.

Native capture/measurement results and limitations are recorded in [RenderQualityValidation.md](RenderQualityValidation.md).

## Visibility and static LOD

The 3D renderer builds compact CPU-selected draw lists per camera and per sunlight cascade. Six clip planes use the engine's 0...W depth convention. Hidden meshes/hierarchies are excluded; NoFrustumCulling keeps an explicitly marked mesh. Shadow visibility is independent from the camera list, including offscreen casters. Skin bounds use cached joint-influence envelopes transformed by the actual pose; static rest bounds do not discard a moving character.

Trees have 96/51/23 triangles and rocks 80/44/20 at LOD0/1/2. Static alternatives preserve the base local coordinates and material indices. LOD uses projected viewport-height coverage with 15 percent hysteresis, per camera. Grass fades with an ordered screen-space dither over the final 5m of its 30m range (including its shadow). The terrain has 60 visible 6m chunks, three resolutions and fixed-resolution stitched boundaries; collision stays at the original full resolution.

5 toggles frustum culling, 6 toggles static LOD. The native window title displays visible/candidate meshes, submitted triangles, draw calls and LOD distribution. Capture modes --capture-visibility, --capture-no-culling, --capture-no-lod and --capture-unoptimized write visibility.json alongside PNG/GPU timing captures. Unoptimized disables frustum culling, LOD and distance culling while retaining the same scene and lighting.

This is the CPU frustum/LOD foundation. GPU Hi-Z occlusion and indirect draw generation are a future layer.

Measured visibility/LOD results and validation limits: [VisibilityValidation.md](VisibilityValidation.md).

## MetalFX Temporal

Temporal reconstruction is opt-in per 3D camera. Press 7 to toggle it in the demo:

```swift
camera.temporalUpscaling = TemporalUpscalingSettings(renderScale: 0.75)
// After a scripted cut or teleport:
camera.temporalUpscaling?.resetGeneration += 1
```

On supported Metal devices the scene stays linear HDR through MetalFX, then
uses the existing ACES/sRGB output transform before UI. Camera, rigid mesh and
skinned mesh velocities are unjittered current-to-previous UV displacement.
An eight-sample Halton sequence jitters input geometry; transparent foreground
uses a reactive mask while preserving opaque velocity/depth underneath. FXAA is
bypassed while temporal reconstruction is active. Unsupported devices keep the
ordinary spatial/native pipeline; failed encodes use a complete spatial fallback
and reset history on the next frame.

```sh
Demos/SkeletalGarden/script/build_and_run.sh --temporal
Demos/SkeletalGarden/script/build_and_run.sh --capture-temporal
Demos/SkeletalGarden/script/build_and_run.sh --capture-temporal-motion
Demos/SkeletalGarden/script/build_and_run.sh --capture-spatial
Demos/SkeletalGarden/script/build_and_run.sh --capture-spatial-motion
Demos/SkeletalGarden/script/build_and_run.sh --capture-temporal-multi
Demos/SkeletalGarden/script/build_and_run.sh --verify-temporal
```

Motion modes use the same deterministic camera orbit and character pose sequence
for temporal/spatial controls. Captures read the final output after upscaling,
at the same output resolution. `motion-30.json`/`motion-50.json` summarize actual
GPU velocity readback; `temporal.json` records encoded/fallback frames and resets.
Multi-camera mode also renders to a 480x320 texture, explicitly resets that
history, changes input scale and disables/re-enables the texture camera.

The first implementation uses a separate mesh-motion pass. Its measured cost
includes motion, MetalFX, output tone mapping and the depth resolve used by 2D
scene overlays. It is a quality option; faster rendering is not assumed.
Apple mobile and WebGPU execution require separate validation.

Recorded native proof: [MetalFXValidation.md](MetalFXValidation.md).

## Local lighting and shadows

Point/spot lights use world-meter ranges independent of entity scale. Intensity
is a linear radiance multiplier at one meter with inverse-square falloff and a
smooth range cutoff. Spot lights aim along local +Z; cone angles are half-angles
in degrees. The inner cone is fully lit; the outer cone smoothly reaches zero.

```swift
PointLightComponent(radiance: [1, 0.35, 0.08], intensity: 45, range: 9)
SpotLightComponent(intensity: 160, range: 12, innerConeAngle: 16, outerConeAngle: 28)
```

The forward shader supports four directional lights (one primary cascaded-shadow
sun) and 32 visible local lights per camera. Local lights are selected by
estimated influence with stable entity-ID ties. A camera's
`Environment3D.localShadows` controls an enabled flag and 0–4 shadowed lights.
Higher `shadowPriority` wins among selected visible lights, then influence;
retained winners keep their atlas slots. Over-budget lights remain illuminated
without shadows. Point shadows use six projections and spot shadows one, in a
reused 512-pixel-tile atlas with a single pass per camera. Alpha-mask and GPU
skinning are shared with the sunlight shadow path. Transparent BLEND materials
remain unshadowed casters. Atlas sampling clamps PCF taps to the current tile.

The demo's extra lights are opt-in. Key 8 toggles local lights and key 9 toggles
their shadows. Inspector controls expose range, cone, shadow bias/priority and
the per-camera local shadow budget.

```sh
Demos/SkeletalGarden/script/build_and_run.sh --local-lights
Demos/SkeletalGarden/script/build_and_run.sh --capture-local-lights
Demos/SkeletalGarden/script/build_and_run.sh --capture-local-no-lights
Demos/SkeletalGarden/script/build_and_run.sh --capture-local-unshadowed
Demos/SkeletalGarden/script/build_and_run.sh --capture-local-point
Demos/SkeletalGarden/script/build_and_run.sh --capture-local-spot
Demos/SkeletalGarden/script/build_and_run.sh --capture-local-budget
Demos/SkeletalGarden/script/build_and_run.sh --capture-local-many
Demos/SkeletalGarden/script/build_and_run.sh --capture-local-moving
Demos/SkeletalGarden/script/build_and_run.sh --capture-local-multi
Demos/SkeletalGarden/script/build_and_run.sh --verify-local-lights
```

`lights.json` records each camera's selected lights, shadow faces and atlas size;
GPU pass timings are separate. The moving control animates a point light, the
character pose and the camera using deterministic frame increments. The
multi-camera control also tests render-to-texture and a resized temporal input.
Native proof and limits: [LocalLightingValidation.md](LocalLightingValidation.md).
