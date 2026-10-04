# AdaEngine skeletal asset tools

The initial skeletal importer lives in `Sources/AdaAssets/GLTF`. It retains node rest TRS, ordered skin joints, inverse bind matrices, typed vertex influences, and named TRS animation clips. The initial runtime now preserves these data in `ModelAsset3D`, creates instance-owned players, and renders GPU skinning in the PBR and directional-shadow passes. `Demos/SkeletalGarden` is the native development scene.

## Reference assets

`Tests/AdaAssetsTests/Fixtures` contains two procedural assets generated locally with Blender 5.1.1, without external models or animation libraries:

- `TwoBoneRibbon.glb`: two joints, blended vertex weights, one `Bend` clip.
- `TestHumanoid.glb`: eleven joints, a low-poly test mannequin, `Idle`, `Walk`, and `Run` clips. This is an import fixture, not finished demo artwork.

The fixtures and generator use the repository's license. Regenerate them from the repository root:

```sh
/Applications/Blender.app/Contents/MacOS/Blender --background --factory-startup --python Tools/3DAssets/generate_skeletal_fixtures.py
```

This runs an independent Blender process and replaces only the two named GLBs. Their skinned meshes are scene roots, avoiding ambiguous parent transforms. Export uses four influences, baked animation, no geometry compression, and embedded material data. Exported clip names and binding are tested through the production loader.

## Format validation

Install the pinned official Khronos validator locally and validate the fixtures:

```sh
npm --prefix Tools/3DAssets --registry=https://registry.npmjs.org ci --ignore-scripts
npm --prefix Tools/3DAssets run validate
```

Validate another GLB:

```sh
npm --prefix Tools/3DAssets run validate -- /absolute/path/model.glb
```

The command prints JSON reports and exits nonzero for validation errors. Warnings remain visible for review. Both reference fixtures were validated with zero errors and zero warnings.

## Import tests

```sh
CLANG_MODULE_CACHE_PATH=/tmp/adaengine-skeletal-import-build/clang-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/tmp/adaengine-skeletal-import-build/swift-cache \
swift test --scratch-path /tmp/adaengine-skeletal-import-build --filter GLTFSkeletalImportTests
```

Tests cover actual Blender exports and small binary fixtures with known bind matrices, influence values, interpolation data, and malformed references. The native importer supports one JOINTS_0/WEIGHTS_0 set and TRS channels with LINEAR/STEP/CUBICSPLINE data. It explicitly rejects extra influence sets and morph animation channels. Missing inverse bind matrices become identity matrices per glTF 2.0. The initial player also supports all three TRS interpolations, pause/seek, looping, playback speed, and pose cross-fades. Each skin currently supports at most 128 joints.

Draco, Meshopt, and KTX2 outputs need decoder support before use. AI-generated assets should be cleaned before rigging and pass the same validation/import pipeline.

## PBR and IBL garden pipeline

`prepare_robot.py` creates the runtime CC0 RobotExpressive profile while retaining original geometry, nodes and inverse bind matrices. It selects three skeletal clips and normalizes source weights. Provenance and source SHA256 are in `Demos/SkeletalGarden/SourceAssets/ASSETS.md`.

`generate_garden_assets.py` authors six original PBR props through Blender and runs `bake_ibl.py`. The IBL bake produces linear RGBA16F radiance/irradiance, a six-level GGX specular atlas and split-sum BRDF LUT. Its constant-radiance energy self-test runs before output generation. The runtime `.ibl` loader validates dimensions, byte counts and finite nonnegative half-float data before GPU upload.

```sh
python3 Tools/3DAssets/prepare_robot.py
/Applications/Blender.app/Contents/MacOS/Blender --background --factory-startup --python Tools/3DAssets/generate_garden_assets.py
```

The GLB import path keeps base color/emission in sRGB, material data in linear space, supports UV0/UV1 and glTF wrap/filter choices, and creates color-correct mipmaps. Referenced images that cannot be decoded fail import rather than becoming silently missing textures.

Useful suites: `GLTFMaterialImportTests`, `ImageMipmapsTests`, `PBR3DSceneTests`. `SkeletalGarden --capture-no-ibl` provides a visual control scene; use the build script's flag of the same name.

Landscape props: run Blender with `--background --factory-startup --python Tools/3DAssets/generate_landscape_assets.py` to reproduce Tree/Rock/Grass. `prepare_robot.py` also derives rotation-only Jump/Fall/Land clips from the retained CC0 source. The terrain itself is deterministic demo code, shared with its static triangle collider.
