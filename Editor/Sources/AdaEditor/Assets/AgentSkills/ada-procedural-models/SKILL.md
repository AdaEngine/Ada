---
name: ada-procedural-models
description: Generate low-poly GLB assets from AdaScript, including explicit joints, rigid/two-joint skinning and linear skeletal clips, then validate and play them through Model3DSource.
allowed-tools: editor.project.context, editor.model.generate, editor.model.inspect, editor.model.validate, editor.components.describe, editor.scene.get, editor.scene.apply, editor.docs.read, editor.build.start, editor.play.start, editor.task.status
---

# Ada Studio Procedural Models

Use this for props, furniture, buildings, trees, robots and stylized low-poly characters built from authored shapes. Describe geometry and optional rig in AdaScript; Studio writes a `.glb`. For blocky voxel art use `ada-voxel-models`. A character recipe explicitly chooses joint pivots and weight rules; automatic anatomical inference and organic mesh reconstruction are separate capabilities.

1. Read `editor.project.context` for the Assets root. Choose a new destination such as `Assets/Models/lamp.glb`; `editor.model.generate` never overwrites, so use a new name for each revision.
2. Call `editor.model.generate` with `source` (the script) and `destination`. The script runs in an isolated VM: no files, network, scene or engine access, a 64 KiB source limit and a small time/step budget. Errors come back as text; fix the script and call again.
3. Read the result: `parts` (names and parents), `materials`, `vertexCount`, `triangleCount` and `assetReference` (`@res://...`). Run `editor.model.inspect` on the path to read the real bounds and confirm the size is what you intended (1 unit is 1 meter).
4. Read `editor.components.describe` with query `Model3DSource`, add that component and a Transform to an entity, and set `source` to the `assetReference`. Preserve unrelated payload fields and pass the current scene revision.
5. Build, run visible Play and inspect a completed frame before claiming the model looks right. Generation proves the file is valid, not that it reads well.

## Script API

Define `func build(model)`. Axes follow the engine: X right, Y up, Z forward. Every shape is centered on its own origin, so build it, then move it with `model.place`. Shape calls return the part id (a whole number); keep it in a variable. A failed call records the error and the generation is rejected with that message.

| Call | Meaning |
| --- | --- |
| `model.material(i, r, g, b)` | Base color of material `i` (0...63), channels 0...1 in linear space. |
| `model.surface(i, metallic, roughness)` | PBR factors 0...1. Defaults: metallic 0, roughness 0.6. |
| `model.emissive(i, r, g, b)` | Glow color 0...1. |
| `model.box(w, h, d)` | Box with flat sides. |
| `model.plane(w, d)` | Horizontal plane facing up (a floor; one-sided). |
| `model.sphere(radius, segments)` | UV sphere. `segments` is 3...64 around the axis; rings are half of it. |
| `model.cylinder(rTop, rBottom, height, segments)` | Capped cylinder. Different radii make a frustum; a zero radius makes a cone. |
| `model.capsule(radius, height, segments)` | Total height including both caps, at least `2 * radius`. |
| `model.torus(major, minor, segments)` | Ring; `minor < major`. |
| `model.profile(radius, y)` ... `model.lathe(segments)` | Revolves the collected `(radius, y)` points around Y. |
| `model.vertex(x, y, z)` ... `model.triangle(a, b, c)` ... `model.mesh()` | Raw flat-shaded triangles from vertex indices; `mesh()` returns the part. |
| `model.group()` | Empty part, used as a pivot or parent. |
| `model.place(id, x, y, z)` | Position relative to the parent. |
| `model.rotate(id, x, y, z)` | Degrees; roll (Z) is applied first, then pitch (X), then yaw (Y). |
| `model.scale(id, x, y, z)` | Positive factors only; mirroring is not supported. The scale of a part without children is baked into its geometry, so squashed spheres (clouds, bushes) shade correctly; a scaled group scales its children and can distort their shading when the factors differ. |
| `model.paint(id, i)` | Material for the part. Material 0 is neutral gray unless you define it. |
| `model.parent(id, parentId)` | Attach to a part created earlier; transforms are inherited. |
| `model.name(id, "text")` | Name shown in the scene hierarchy and `editor.model.inspect`. |

## Explicit rigs in the interpreted generator

These functions run in the existing embedded bytecode VM. The native builder is compiled into the application; executing a recipe does not launch a Swift compiler, generate machine code or require JIT. Changes to the builder API must first ship in an updated application binary. Source/API presence is not iPad device validation.

Finish all geometry, names, parents and transforms before the first `joint` or `vertexPosition` call: those operations freeze the original parts. Part ids and joint ids are separate namespaces. Part metadata below refers to the original recipe geometry. Rigged output bakes mesh transforms into model-space buffers and merges by material.

| Call | Meaning |
| --- | --- |
| `model.partCount()` | Original part count, including groups. |
| `model.partName(part)`, `model.partParent(part)` | Original name and parent part id; `-1` for no parent. |
| `model.hasMesh(part)`, `model.vertexCount(part)` | Whether a part has geometry and its vertex count. |
| `model.vertexPosition(part, vertex, axis)` | Model-space coordinate; axis 0/1/2 is X/Y/Z. |
| `model.joint(name, parentJoint, x, y, z)` | Create a joint and return its joint id. Rest translation is local to its parent. First root uses `-1`; later parents must already exist. Names must be unique. |
| `model.bind(part, joint)` | Assign every vertex of the part fully to this joint. Bind every mesh part. |
| `model.weights(part, vertex, j0, w0, j1, w1)` | Override a bound vertex with up to two influences. Nonnegative weights must sum to one. Use existing joints even for zero-weight entries. |
| `model.clip(name)` | Create a uniquely named clip and return its clip id. |
| `model.rotationKey(clip, joint, time, x, y, z)` | Joint-local Euler rotation in degrees; converted to a unit quaternion. |
| `model.translationKey(clip, joint, time, x, y, z)` | Joint-local translation. |

Keys use LINEAR interpolation; timestamps must strictly increase within each joint/channel. Looping is selected on `Model3DSource`, not encoded in glTF. For a seamless loop make the first and last values equal. Limits: 128 joints, 32 clips, 16,384 keys, key times 0...3600 seconds, joint/translation coordinates within 1000 meters. Existing source/execution/geometry budgets still apply. No rest-joint rotations or imported-mesh editing are exposed by this recipe API.

```
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

Validate the written asset, check joint order and clip names, then verify actual deformations in completed game frames at several phases. Import success alone does not establish animation playback or adequate weights.

Winding: triangles must be counter-clockwise when seen from outside, so `cross(b - a, c - a)` points out. A `lathe` profile runs from the top, outward and down the side, back to the axis at the bottom (a solid), as in a cup: `profile(0, 1)`, `profile(0.5, 1)`, `profile(0.3, 0)`, `profile(0, 0)`. Repeat the first point to close a ring profile. Corners sharper than 60 degrees get hard edges; gentler turns are smooth.

Limits: 512 parts, 200,000 vertices in total, sizes up to 1000, 256 profile points, 20,000 custom vertices.

```
func build(model) {
    model.material(1, 0.55, 0.55, 0.6);
    model.surface(1, 0.8, 0.35);
    model.material(2, 1.0, 0.85, 0.4);
    model.emissive(2, 1.0, 0.8, 0.3);

    var lamp = model.group();
    model.name(lamp, "Desk lamp");

    var base = model.cylinder(0.12, 0.15, 0.04, 24);
    model.paint(base, 1);
    model.place(base, 0.0, 0.02, 0.0);
    model.parent(base, lamp);

    var arm = model.cylinder(0.015, 0.015, 0.45, 12);
    model.paint(arm, 1);
    model.place(arm, 0.0, 0.26, 0.0);
    model.parent(arm, lamp);

    var shade = model.cylinder(0.04, 0.12, 0.14, 24);
    model.paint(shade, 1);
    model.place(shade, 0.0, 0.55, 0.0);
    model.parent(shade, lamp);

    var bulb = model.sphere(0.045, 12);
    model.paint(bulb, 2);
    model.place(bulb, 0.0, 0.52, 0.0);
    model.parent(bulb, lamp);
}
```

## Craft

- Model at real-world size in meters; an object about 1 m across is easy to frame.
- Put the origin where the object sits or pivots: a prop's feet at `y = 0`, a door's hinge at its own group.
- Group the parts (`model.group()` plus `model.parent`) so the scene gets a named hierarchy that code can animate by part later.
- Use 3-6 materials and distinct roughness values; shape reads better than detail. Segments of 12-24 are enough for small parts.
- Use `plane` for floors and walls only when seen from the front; thin `box` parts have both sides.
- Prefer shapes and loops over raw triangles. Loops over many parts are fine in a script, but each call costs script budget, so build repeated detail with a few `lathe` or `box` parts.
- Only the calls above exist; do not use `print`, files, imports or `System`. A script that fails validation is rejected before running.
