# Spine 2D animation

`AdaSpine` is an optional SwiftPM library for characters exported from **Spine 4.2**.
Add the `AdaSpine` product to the application target and import it alongside
`AdaEngine`. The base `AdaEngine` product does not link the Spine runtime.

The official C runtime is pinned in `Sources/SpineRuntimeC/UPSTREAM.md`.
Its [license](../Sources/SpineRuntimeC/LICENSE) applies to applications using this
optional module; it is separate from AdaEngine's license.

## Load and play

Install `SpinePlugin()` alongside the engine's default plugins. When composing
plugins manually, include the usual transform, visibility, rendering and
`Core2DPlugin` setup. Spine owns its draw buffers, blend pipelines and a shader
that supports both light and dark slot tint colors.

Keep the export and its companion atlas beside one another:

```text
Characters/Hero.spine     # Spine JSON export, renamed from Hero.json
Characters/Hero.atlas
Characters/Hero.png       # Names and subdirectories are read from the atlas
```

Binary exports use `Hero.skel` with `Hero.atlas`. Atlas pages must declare their
pixel `size:`. Exported atlas rotation, trimming, multiple pages and PMA are
handled by the runtime.
Texture filtering and wrapping use AdaEngine's texture import settings.

```swift
import AdaEngine
import AdaSpine

let asset = try await AssetsManager.load(
    SpineSkeleton.self,
    at: "@res://Characters/Hero.spine"
)
let animation = try SpineAnimation(skeleton: asset.asset)
try animation.player.play("walk", repeats: true)

world.spawn {
    animation
    Transform(scale: [0.01, 0.01, 1])
}
```

Spine coordinates are pixels with positive Y pointing up. Set the entity scale
to convert to scene units. Translation, rotation and scale of the owner are
applied to the entire character. Layers within the character follow Spine's
draw order; the owner's Z position determines its placement among other 2D
objects. Dynamic skeleton bounds currently use `NoFrustumCulling`, retaining
the normal per-camera visibility and render-layer checks.

```swift
try animation.player.play("jump", repeats: false, transitionDuration: 0.2)
try animation.player.setSkin("winter")
animation.player.resetToSetupPose()
```

Set `SpineAnimation.isPaused` to freeze playback or change its nonnegative
`speed`. Non-looping clips hold their final pose. A player is a reference with
serialized access: create a new `SpineAnimation` per character for independent
playback. Copying a component intentionally shares its existing player.

For procedural loading, `SpineSkeleton(skeleton:atlas:textures:format:scale:)`
accepts exported bytes, atlas text and texture handles in atlas-page order.
`SpineAnimationPlayer` also works without a GPU; `snapshot()` returns owned
vertices, UVs, colors and indices after animation, skinning and clipping.

## Supported behavior

The official runtime evaluates linear, stepped and Bezier timelines, the bone
hierarchy, skins, attachment changes, draw order, weighted meshes, deformation,
IK, path and transform constraints, physics constraints and animation mixing.
The AdaEngine adapter renders region and mesh attachments, clipping and the
normal, additive, multiply and screen blend modes, two-color tinting and PMA atlas pages.

Gameplay event callbacks and scene serialization for
`SpineAnimation` are not exposed yet. Runtime imports are read-only; edit and
export the source in Spine. Assets must be valid exports for the pinned runtime
version; update the runtime and re-export together when changing versions.

## Validation

`swift test --filter 'SpineAnimationTests|SpineSceneTests'` exercises the actual C runtime through
the Swift adapter, including curves, hierarchy, independent instances, blending,
weighted vertices, clipping, skins, PMA metadata, concurrent access, filesystem
loading and headless scene extraction/preparation. Real GPU pixels require a
separate render smoke test.

## Visual preview

[SpineNative](https://github.com/AdaEngine/AdaExamples/tree/main/Examples/Technical/SpineNative/README.md) runs the production render systems
in a native engine window. Its AdaMCP endpoint exposes exact pose selection and
the engine's GPU screenshot tools.

[SpinePreview](https://github.com/AdaEngine/AdaExamples/tree/main/Examples/Technical/SpinePreview/README.md) exports the official Spineboy's
walk, run, jump and idle poses through the production Swift player. Its portable
browser viewer displays the textured triangles, bone overlay and frame scrubber.
This preview makes animation behavior visible without requiring a native GPU backend.
