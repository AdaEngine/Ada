---
name: ada-scene-authoring
description: Create and edit Ada scene entities, hierarchy, components, and scriptable objects safely.
allowed-tools: files.read, files.write, editor.project.context, editor.scene.list_open, editor.scene.get, editor.scene.apply, editor.scene.undo, entity.find, component.get, render.capture_screenshot
---

# Ada Scene Authoring

- Inspect the active scene, selected entity, component descriptors, and asset references before editing.
- Prefer `editor.scene.get` and `editor.scene.apply` for open scene documents. Read the scene immediately before editing and pass its current revision; on a revision conflict, re-read and rebuild the operation list.
- Batch related entity and component operations into one `editor.scene.apply` call. It can create, rename, enable, reparent, and delete entities; add/remove components; and set a component's complete payload. When replacing a payload, include all fields that should be kept.
- It validates the resulting hierarchy, updates the open document, and participates in Ada Editor undo/autosave. Use `editor.scene.undo` to undo the latest active-scene edit.
- These tools operate on scene documents already open in Ada Editor. Open an unopened scene in the editor before editing it. If direct YAML editing is required, preserve `format`, `schemaVersion`, editor state, stable entity IDs, and unknown component payloads.
- Keep parent relationships acyclic. Add required components before dependent components.
- Validate the decoded scene, open it in the editor, and run it when the requested behavior is executable.
- Finish visual scene work with a screenshot of the relevant viewport or runtime window and inspect the result.
