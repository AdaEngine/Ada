---
name: ada-3d-assets
description: Import, inspect, place and diagnose GLB/glTF models in Ada Studio, including model scale, hierarchy, bounds and format compatibility.
allowed-tools: editor.project.context, editor.model.inspect, editor.model.validate, editor.model.import, editor.components.describe, editor.scene.get, editor.scene.apply, editor.docs.search, editor.docs.read, editor.examples.read
---

# Ada Studio 3D Assets

1. Read `editor.project.context` for actual host tools, resource roots and model limits. Reuse existing models. Read the `Agent3DWorkflow` documentation article and `basic-3d-scene` example when establishing a new scene.
2. Run `editor.model.inspect` on a project-relative Assets path. Read material indexes, texture slots, named clips, skin joints and rest-pose scene bounds. Bounds retain the original model scale; preview auto-framing does not change the imported scale. Very large or small dimensions need an intentional entity Transform change.
3. Use `editor.model.import` to move a downloaded model from a project-relative Downloads path into Assets. It copies local buffers/textures together, chooses a collision-free bundle name and returns its `@res://` reference. A bare `.gltf` without its buffers/textures is incomplete. Network dependencies and escaping symlinks are rejected.
4. Read `editor.components.describe` with query `Model3DSource`. Add that component and its required Transform to the authored entity. Set `source` to the returned resource reference; `animation`, `autoplay` and `repeats` control a named clip. On desktop, use `editor.scene.get/apply` for open documents, preserve unrelated payload fields, and pass the current revision so undo works. Mobile agents can edit scene YAML with their file tools.
5. Validate the model, build, then run visible Play and inspect a completed GPU frame. Use the tools advertised by the current host: desktop `editor.build.start`, `editor.play.start`, `editor.task.status`, `render.capture_screenshot`; mobile `editor.build`, `editor.play.start`, `editor.play.capture`, `editor.image.read`.

Model validation performs native CPU import and profile checks; it does not prove rendering, animated bounds, collision or gameplay. The isolated simulation excludes model rendering. Imported meshes do not automatically gain physics colliders. For invisible models, inspect source resolution, entity visibility/scale, camera projection/framing/clipping and lighting before replacing assets.

Use plain glTF 2.0 triangle output, UV0/UV1 and at most 128 joints per skin with one set of four influences. Draco, Meshopt and KTX2 decoding are unavailable in this profile. For a requested Blender export, check whether `editor_external` is available, list enabled local tools and describe `blender.create_and_export_glb` if present. Invoke that preset in Build with the described recipe and use its returned Downloads path for import. For a low-poly model generated in Studio, load `ada-procedural-models` (`editor.model.generate` writes a `.glb`). For blocky voxel art load `ada-voxel-models` (`editor.voxel.generate` writes a `.vox`).

For a tracked Blender job, use the returned job ID with `blender.import_glb` in the intended open scene and then `blender.place_model` with the current scene revision. Use `blender.verify_play` for the same job and scene. It returns a local `capturePath` after the imported model loads in the selected run. Report that evidence and leave visual confirmation to the user reviewing the frame. After a retry, use the same job ID and the returned last completed stage.
