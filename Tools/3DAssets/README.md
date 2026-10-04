# AdaEngine skeletal asset tools

The initial skeletal importer lives in `Sources/AdaAssets/GLTF`. It retains node rest TRS, ordered skin joints, inverse bind matrices, typed vertex influences, and named TRS animation clips. Playback and GPU skinning are the next runtime stage; `ModelAsset3D` still renders static meshes.

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

Tests cover actual Blender exports and small binary fixtures with known bind matrices, influence values, interpolation data, and malformed references. The native importer supports one JOINTS_0/WEIGHTS_0 set and TRS channels with LINEAR/STEP/CUBICSPLINE data. It explicitly rejects extra influence sets and morph animation channels. Missing inverse bind matrices become identity matrices per glTF 2.0. Do not confuse imported interpolation data with runtime playback support.

Draco, Meshopt, and KTX2 outputs need decoder support before use. AI-generated assets should be cleaned before rigging and pass the same validation/import pipeline.
