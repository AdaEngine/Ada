---
name: ada-csg
description: Build and edit 3D levels with constructive solid geometry (CSG) in Ada Studio. Use for editable walls, floors, holes, Boolean groups, UVs, and checking collision in Play.
allowed-tools: editor.project.context, editor.scene.list_open, editor.scene.get, editor.scene.apply, editor.scene.undo, editor.docs.read, editor.play.start, editor.task.status, editor.play.capture, render.capture_screenshot
---

# Ada Studio CSG Levels

Read the offline guide with `editor.docs.read` and ID `CSG`. Check
`editor.project.context` for host capabilities. Use a desktop Studio host with
CSG support to evaluate the geometry and verify the result.

## Create or change the scene

1. Open the 3D scene. Use `editor.scene.get` to read its revision, entities and
   transforms. Send all related edits in one `editor.scene.apply` call using the
   returned revision. If it changes, re-read and rebuild the edit batch.
2. Create a group with the authoring component `AdaStudio.CSGGroup` and payload
   `{"version":1}`. Create each solid as a direct child of that group with
   `AdaStudio.CSGBox`. This component name is shared by boxes, spheres and
   cylinders. Use `shape` values `box`, `sphere`, or `cylinder`. A missing
   `shape` is a box. Use `operation` values `union`, `subtract`, or `intersect`.
3. Set `AdaTransform.Transform` on each block. The three components of `scale`
   are its dimensions and must be positive. `position` and quaternion
   `rotation` are relative to the group. A cylinder's local axis is Y.
4. Create the base first, followed by the remaining blocks in evaluation order.
   Only enabled direct children with the CSG marker participate. The first
   enabled block supplies the base. Each later block modifies the accumulated
   solid. Use the Inspector's move arrows to reorder existing blocks.
5. Use `setComponent` with the complete payload to change an operation,
   transform or texture while preserving the other fields. Use the existing
   scene undo tool after an unwanted edit.

For a doorway, use the following operations in order. Send them as the
`operations` array together with the current `expectedRevision`. Choose
unused IDs if the scene already contains any of the example IDs.

```json
[
  {"op":"createEntity","id":"level","name":"Level","components":{"AdaStudio.CSGGroup":{"version":1,"texture":"checker"}}},
  {"op":"createEntity","id":"wall","name":"Partition","parentID":"level","components":{
    "AdaStudio.CSGBox":{"operation":"union"},
    "AdaTransform.Transform":{"position":[0,1.5,0],"rotation":[0,0,0,1],"scale":[0.4,3,6]}
  }},
  {"op":"createEntity","id":"opening","name":"Doorway","parentID":"level","components":{
    "AdaStudio.CSGBox":{"operation":"subtract"},
    "AdaTransform.Transform":{"position":[0,0.97,0],"rotation":[0,0,0,1],"scale":[1,2.15,1.5]}
  }},
  {"op":"createEntity","id":"floor","name":"Floor","parentID":"level","components":{
    "AdaStudio.CSGBox":{"operation":"union"},
    "AdaTransform.Transform":{"position":[0,-0.125,0],"rotation":[0,0,0,1],"scale":[10,0.25,6]}
  }}
]
```

The cutter extends through both wall faces. Adding the floor after the subtraction
leaves the opening flush at Y = 0. For a round hole through this wall, turn a
cylinder's axis toward X and extend it beyond both wall faces.

## Check the geometry, UVs and collision

- Set the group `texture` to `checker` to inspect UVs on both original faces and
  cuts. For a custom image, use an `@res://` PNG or JPEG reference relative to
  the primary assets folder. The optional integer `uvRepeats` defaults to 1.
  Set it between 1 and 64. Omit `texture` for the plain material.
- Read the scene again to confirm authored order and transforms. Start Play,
  wait until `editor.task.status` reports it running, then capture the lit
  game camera with `editor.play.capture` and inspect the image with the host's
  viewing capability. See `ada-visual-verification` for capture options.
  An empty intersection can be valid. If evaluation fails, inspect
  dimensions, order and image references before starting Play or exporting.
- With a player character, check that it can walk through the doorway and
  that the solid wall beside it stops movement. For native AdaScript export,
  enable the Model 3D and Physics 3D plugins. Check visible Play and any
  packaged player separately.
