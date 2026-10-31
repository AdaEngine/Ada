---
name: ada-scene-authoring
description: Create and edit Ada scene entities, hierarchy, components, and scriptable objects safely.
allowed-tools: files.read, files.write, editor.project.context, editor.scene.list_open, editor.scene.get, editor.scene.apply, editor.scene.undo, entity.find, component.get, editor.play.capture, render.capture_screenshot
---

# Ada Scene Authoring

- Inspect the active scene, selected entity, component descriptors, and asset references before editing.
- Prefer `editor.scene.get` and `editor.scene.apply` for open scene documents. Read the scene immediately before editing and pass its current revision; on a revision conflict, re-read and rebuild the operation list.
- Batch related entity and component operations into one `editor.scene.apply` call. It can create, rename, enable, reparent, and delete entities; add/remove components; and set a component's complete payload. When replacing a payload, include all fields that should be kept.
- It validates the resulting hierarchy, updates the open document, and participates in Ada Editor undo/autosave. Use `editor.scene.undo` to undo the latest active-scene edit.
- These tools operate on scene documents already open in Ada Editor. Open an unopened scene in the editor before editing it. If direct YAML editing is required, preserve `format`, `schemaVersion`, editor state, stable entity IDs, and unknown component payloads.
- Keep parent relationships acyclic. Add required components before dependent components.
- Organize related entities under clearly named parent entities: for example Player (camera, weapon, weapon sounds), Environment (architecture, collision, lighting), and Effects. Prefer a readable parent/child tree over a flat list of hundreds of objects. Use neutral parent transforms for purely organizational groups; inspect inherited transforms and preserve world placement when reparenting existing objects. Here inheritance means scene parenting, not introducing class subclasses just to organize a scene.
- Use explicit inspector sections for related exported fields: AdaScript `@export(group: "Camera/Auto Exposure")`, or Swift `@Export(group: "Camera/Auto Exposure")` inside `@Component`. Paths support one to four named levels; do not infer sections from field-name prefixes or change saved field names to group them.
- Validate the decoded scene, open it in the editor, and run it when the requested behavior is executable.
- Finish visual scene work by playing the scene and inspecting the game camera's frame (`editor.play.capture`; load `ada-visual-verification`). The editor viewport shows the editor camera, not what the game renders.
- Give every game scene a render setup that cannot flash blank: an active `Camera` with an explicit `backgroundColor` and clear flags, at least one light, and for 3D an `Environment3D` (sky/ambient). `render.capture_screenshot` without a running game is the editor window; never use it to judge the scene.
