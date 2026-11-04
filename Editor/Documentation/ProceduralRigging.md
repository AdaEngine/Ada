# Procedural rigs in AdaScript

Studio's `editor.model.generate` tool accepts a model recipe with geometry,
explicit joints, vertex weights and local translation/rotation animation keys.
This is useful for stylized characters assembled from known parts. The recipe
decides anatomy and weights; it does not infer a rig for an arbitrary imported mesh.

The application must include the extended model builder. It ships as precompiled
native code; the embedded compiler produces interpreted bytecode. Recipe execution
requires no JIT, Swift compiler, shell, Python, Blender or cloud 3D service.
Windows VM execution and native output playback have been checked. Physical iPad
execution and a complete rebuilt Studio bundle remain unverified.

## Generate and play

Pass this complete source as `source` to `editor.model.generate`, with a new
`destination`, for example `Assets/Models/swing.glb`. Existing files are never
overwritten, so choose another destination when revising a recipe.

```text
func build(model) {
    var body = model.box(0.4, 0.6, 0.2);
    model.place(body, 0, 0.3, 0);
    var root = model.joint("Root", -1, 0, 0, 0);
    model.bind(body, root);
    var idle = model.clip("Idle");
    model.rotationKey(idle, root, 0, 0, -10, 0);
    model.rotationKey(idle, root, 0.5, 0, 10, 0);
    model.rotationKey(idle, root, 1, 0, -10, 0);
}
```

Run `editor.model.validate` on the resulting path. Add a `Model3DSource` to a
scene entity using the returned asset reference, set `animation` to `Idle`,
and enable `autoplay` and `repeats`. Build and run Play. The box should swing
around its bottom pivot. Inspect completed frames to check the visible result;
successful import alone does not prove playback or adequate deformation.

## Joint and weight rules

Finish geometry, names, transforms and part parents before calling rig functions.
The original parts then freeze. Part IDs and joint IDs are separate namespaces.
`joint(name, parentJoint, x, y, z)` returns a joint ID: first root uses parent
`-1`; other parents must already exist. Positions are local to the joint parent.

`bind(part, joint)` gives every vertex one rigid influence. Every mesh needs a
binding. `weights(part, vertex, j0, w0, j1, w1)` replaces a bound vertex's weights
with two valid joint IDs and nonnegative weights summing to one. Metadata helpers
`partCount`, `partName`, `partParent`, `hasMesh` and `vertexCount` inspect original
parts. `vertexPosition(part, vertex, axis)` reads model-space coordinates, with
axes 0/1/2 for X/Y/Z. Output geometry is baked to model space and merged by material.

`clip(name)` returns a clip ID. `rotationKey(clip, joint, time, x, y, z)` accepts
Euler angles in degrees and writes a quaternion. `translationKey` accepts a local
translation. Times are seconds and must increase within each joint/channel.
Channels use LINEAR interpolation. Match first/last values for a seamless loop;
the scene instance controls repetition.

Limits include 128 joints, two influences per vertex, 32 clips, 16,384 keys,
key times up to one hour, 64 KiB of source and execution/geometry budgets.
Rest rotations, scale keys and imported-mesh editing are not exposed by this API.

The [skeleton demo](../../Demos/ProceduralSkeleton/README.md) includes a complete
recipe for 23 joints, blended clothing weights and a walk cycle, with buffer and
native playback evidence. Its Python/Swift harness is for developer validation;
those tools are not part of the device recipe workflow.
