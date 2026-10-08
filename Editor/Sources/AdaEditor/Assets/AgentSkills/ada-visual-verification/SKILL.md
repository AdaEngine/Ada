---
name: ada-visual-verification
description: Verify scene, rendering, and AdaUI changes with live inspection and screenshots.
allowed-tools: editor.project.context, editor.scene.get, world.list_worlds, entity.find, ui.list_windows, ui.get_tree, ui.find_nodes, ui.get_layout_diagnostics, ui.capture_node_screenshot, render.capture_screenshot
---

# Ada Visual Verification

Use this after any change whose success is visible.

1. Build and launch the exact project and scene in scope.
2. Use `editor.scene.get` to confirm the open scene revision and hierarchy before launch. Locate the runtime window or viewport using its accessibility identifier or inspected UI tree.
3. Capture the smallest screenshot that proves the result; use a full render capture for game output and a node capture for AdaUI or editor layout.
4. Inspect the image and relevant diagnostics. If the result is wrong, fix it and repeat the same capture.

Never treat compilation, a saved PNG path, or a screenshot without visible rendered content as runtime proof.
