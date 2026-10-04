# Skeletal Garden

A native AdaEngine demo for skeletal GLB import, clip playback, cross-fading, GPU skinning, independent model instances, and animated directional shadows. The scene uses the CC0 Quaternius RobotExpressive character and six original textured garden props. Provenance and processing recipes are in `SourceAssets/ASSETS.md`.

Run from the AdaEngine repository root:

```sh
Demos/SkeletalGarden/script/build_and_run.sh
```

- WASD: camera-relative movement inside the courtyard.
- Shift: run. Idle, Walk, and Run fade over 0.22 seconds, retain walk/run cycle phase and match playback speed to actual movement.
- Space: jump on a press edge. R: reset to the starting position.
- Drag with the left mouse button: orbit the camera.
- The second humanoid plays its own Walk clip at a different speed.
- Wood/stone props demonstrate color, ORM and normal maps; plants demonstrate alpha mask and double-sided leaves; the lantern demonstrates constant emission.

The scene uses offline-baked diffuse irradiance, GGX-prefiltered HDR reflections and a split-sum BRDF LUT. SSR stays disabled while IBL is active to keep lighting independent of screen visibility. The robot uses AdaPhysics’s fixed-step upright capsule controller: gravity, acceleration/braking, sweep collision, overlap recovery, wall sliding and grounded jumps. The props have explicit world-space collision proxies; the courtyard has a solid floor and visible raised borders. Animation follows collision-resolved speed, so the robot returns to Idle when blocked.

The first controller does not auto-step stairs, ride moving platforms, push dynamic bodies or collide with other controller capsules. Use it on a root entity without a PhysicsBody3DComponent; capsule dimensions are world units independent of visual scale. The second robot has a static collision proxy.

## Validation modes

```sh
Demos/SkeletalGarden/script/build_and_run.sh --verify
Demos/SkeletalGarden/script/build_and_run.sh --capture
Demos/SkeletalGarden/script/build_and_run.sh --capture-no-ibl
Demos/SkeletalGarden/script/build_and_run.sh --debug
```

`--verify` drives the same controller/animation systems through a scripted crate collision, movement/braking and jump/landing sequence. It fails unless all runtime position, velocity, grounded and clip checks pass. `--capture` fixes the camera and character root, plays skeletal poses, and saves two PNGs under `dist/captures` directly from the Metal render target. The readback uses the render graph's command queue and waits asynchronously for completion. It does not capture the desktop.

The script stages `dist/SkeletalGarden.app`, including SwiftPM resource bundles, and launches it with macOS Launch Services. Logs are under `dist`. It only restarts the SkeletalGarden process. The build defaults to a dedicated `/tmp/adaengine-skeletal-import-build` scratch path; set `ADAENGINE_SKELETAL_BUILD_PATH` to override it.

The initial runtime supports four vertex influences and at most 128 joints per skin. TRS tracks support LINEAR, STEP, and CUBICSPLINE, including quaternion slerp and cubic tangent scaling. Per-instance palettes use frame-buffered GPU allocations and are shared by the PBR and directional-shadow passes. Static meshes keep the identity skinning path.

Useful regression suites: `SkeletalAnimationTests`, `SkeletalModel3DTests`, `GLTFSkeletalImportTests`, and `Model3DRenderItemsExtractionTests`, `CharacterController3DTests`, and `Physics3DTests`.

`--capture-no-ibl` captures a control scene under `dist/captures/no-ibl`. The generator/profile tools are reproducible:

```sh
python3 Tools/3DAssets/prepare_robot.py
/Applications/Blender.app/Contents/MacOS/Blender --background --factory-startup --python Tools/3DAssets/generate_garden_assets.py
```

The glTF material path imports AO/ORM, normal scale, emission factors and KHR_materials_emissive_strength, OPAQUE/MASK/BLEND, alpha cutoff, double-sided flags, UV0/UV1, wrap/filter settings and color-correct mipmaps. Alpha mask is applied in both PBR and animated-shadow passes. Transparent instances render after opaque geometry with depth writes disabled. IBL maps are loaded once from `.ibl` manifests; integrations are offline, not per-frame shader loops.
