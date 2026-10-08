---
name: ada-ui-debugging
description: Inspect and debug AdaUI hierarchy, layout, focus, hit testing, and interaction behavior.
allowed-tools: ui.list_windows, ui.get_tree, ui.get_node, ui.find_nodes, ui.get_layout_diagnostics, ui.hit_test, ui.focus_node, ui.tap_node, ui.capture_node_screenshot
---

# AdaUI Debugging

- Locate nodes by stable `accessibilityIdentifier` when possible; runtime IDs are session-local.
- Trace interaction failures through window, tree, layout, hit test, focus, and action state instead of guessing from source.
- Use layout diagnostics before changing frames or padding. Keep keyboard navigation and visible focus intact.
- Apply only deterministic UI actions, then re-read the node or tree.
- Capture and inspect the affected node after the fix, including compact-width behavior when the project targets iPadOS.
