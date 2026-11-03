# UI Designer

Read this reference only when the task touches this area. Return to [the editor guide](../../AGENTS.md) for routing and shared rules.

Paths in code spans and commands retain their original `Editor/` working-directory context unless explicitly repository-relative; Markdown links resolve from this file.

This inventory was originally recorded on **2026-10-04** and subsequently maintained. Implementation and test links identify existing coverage, not a validation run or platform acceptance.

### UI Designer

Reusable `.ui` YAML resources with visual Design, Interact and source modes.
Palette, hierarchy reorder/nesting, property inspector and ordered modifiers,
including background/overlay content. Inputs, actions, preview data, bindings,
conditional/repeated content and nested UI resources. Entity UI components can
bind designed controls to exported gameplay-script fields. Designer undo/redo
and Swift UI export integration are present.

Design supports palette/hierarchy/canvas drag and drop, stack insertion, and
responsive free placement through AdaUI FreeLayout/relativePosition. Drops use
one history transaction; compact iPad layouts retain pointer capture while
revealing the canvas, with held touches for drag and quick swipes for scrolling.

Guide: [UIScenes.md](../../Documentation/UIScenes.md).
Entry points: [EditorUISceneEditor.swift](../../Sources/AdaEditor/UI/Editor/EditorUISceneEditor.swift),
[EditorViewModel+UIExports.swift](../../Sources/AdaEditor/UI/Editor/EditorViewModel+UIExports.swift).
Coverage: [EditorUISceneTests.swift](../../Tests/AdaEditorTests/EditorUISceneTests.swift),
[EditorScriptUIBindingTests.swift](../../Tests/AdaEditorTests/EditorScriptUIBindingTests.swift),
[EditorUIExportIntegrationTests.swift](../../Tests/AdaEditorTests/EditorUIExportIntegrationTests.swift).

## Boundaries and incomplete paths

- AdaUI views written in AdaScript (`@view`, UI Script templates/previews,
  `runtime.entry.view`) are temporarily unavailable. The `.ui` Designer and
  gameplay-script field bindings are separate, existing features.
