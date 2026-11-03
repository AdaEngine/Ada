# Scenes, Viewport and Inspector

Read this reference only when the task touches this area. Return to [the editor guide](../../AGENTS.md) for routing and shared rules.

Paths in code spans and commands retain their original `Editor/` working-directory context unless explicitly repository-relative; Markdown links resolve from this file.

This inventory was originally recorded on **2026-10-04** and subsequently maintained. Implementation and test links identify existing coverage, not a validation run or platform acceptance.

- Inspector subgroups use explicit export metadata (`group: "Camera/Auto Exposure"`,
  at most four levels) or descriptor `groupPath`; never infer groups from names.
  Scene hierarchy supports ancestor-preserving name search, empty parent groups,
  and persisted divider width. Its vertical scroll indicator appears when rows
  overflow the viewport. Keep related authored entities under meaningful
  parent groups and account for inherited transforms. See
  [InspectorGroups.md](../../Documentation/InspectorGroups.md).

### Entity scenes and viewport

The scene header uses compact icons for object points, Annotate and Terrain, with
localized hover tooltips and active-state highlights. The Show/Hide object points
button controls the transform-origin
cross markers in both 2D and 3D. They are hidden by default per viewport; transform
handles, camera/light/audio gizmos and annotation markers remain independent.

`.ascn` scene documents, YAML/model serialization, entity hierarchy and selection,
entity templates, rename/delete/duplicate/copy/paste/reparent operations.
Reusable nested scenes through `SceneInstance` already exist.
2D/3D viewport modes, camera navigation, picking, grid/rulers/orientation helpers
and Move/Scale/Rotate tools. Scene edits have undo/redo.
The native viewport's Terrain tool creates height-field ground and sculpts it
with Raise/Lower/Smooth/Flatten brushes, radius/strength controls and a surface
ring. Brush controls and Create Terrain live in the contextual Inspector, share
the active viewport's state and clear with its action owner. The viewport retains
its full height. A stroke commits one document-history edit; Escape restores its original
heights. `Terrain3DSystem` generates meshes and, with `Physics3DPlugin`, matching
static triangle colliders. Height samples persist in `AdaScene.Terrain3D` through
scene loading and native export. Imported-mesh sculpting, texture painting and
browser authoring remain separate. Guide: [Terrain.md](../../Documentation/Terrain.md).
Coverage: [EditorTerrainTests.swift](../../Tests/AdaEditorTests/EditorTerrainTests.swift).
Inspector layout, live language changes and owner lifecycle coverage:
[EditorTerrainInspectorTests.swift](../../Tests/AdaEditorTests/EditorTerrainInspectorTests.swift).
2D sprite picking shares the runtime hit test: CPU alpha masks, atlas regions,
anchors, image modes and composed parent transforms before ECS propagation.
Coverage: [EditorSpritePickingTests.swift](../../Tests/AdaEditorTests/EditorSpritePickingTests.swift).
Selection reuses the parsed scene model and retains preview entities for editor-only
state changes. Large terrain payloads use bulk YAML node construction; regression
coverage: [EditorSceneSelectionRegressionTests.swift](../../Tests/AdaEditorTests/EditorSceneSelectionRegressionTests.swift).
Each workbench pane keeps only its last scene preview mounted while displaying code.
The hidden preview disables input and suspends hosted world updates, including after
native window activation. Returning to the scene reuses its prepared world; closing
or replacing the retained scene releases it. Hidden hierarchies do not prepare rows.
Preserve the one-scene-per-pane bound and code input ownership when changing tabs.
Lifecycle coverage: `EditorWorkbenchSplitTests.retainedScenePresentation` and
`EditorScenePerformanceRegressionTests.retainedScenePausesHostedFrames`.
Large scene documents decode off the UI actor; previews prepare model/LOD/Spine
assets asynchronously and install entities in batches while hosted frames are
suspended. They retain shared handles per preview world, cancel stale loads and reuse unchanged imports. JSON
component arrays use the portable value parser; edit worlds omit physics-body
geometry while the document/Inspector and Play retain it. Imported models share
matching texture contents without retaining unused GPU textures in the index.
Guide: [SceneLoading.md](../../Documentation/SceneLoading.md). Coverage:
[EditorSceneAssetCacheTests.swift](../../Tests/AdaEditorTests/EditorSceneAssetCacheTests.swift).
The hierarchy and project tree own hover state and drawing caches per mounted row.
Project-switcher and Targets/Files picker rows use `EditorPickerRowButtonStyle`
with full-row hit areas and hover feedback layered over the saved selection color.
Pointer enter/leave, padding clicks and selection coverage: `EditorPickerHoverTests`.
Pointer-motion and neighboring-row cache coverage:
[EditorSidebarHoverTests.swift](../../Tests/AdaEditorTests/EditorSidebarHoverTests.swift).
Window dispatch coalesces consecutive hover moves while preserving the raw scene
event stream and gesture boundaries. Coverage:
[EditorWindowHoverInputTests.swift](../../Tests/AdaEditorTests/EditorWindowHoverInputTests.swift).
Viewport annotations are captured with each scheduled scene frame and published
with its completed texture at the next UI tick. Their Canvas drawing revisions
refresh synchronously without rebuilding the viewport; 3D rotation leaves hidden
rulers and unchanged status text alone. The compass observes its own presented
camera orientation. Gizmo hover/drag use the displayed geometry, mapping pointer
coordinates into the captured target while resizing. Coverage:
[EditorViewportPresentationTests.swift](../../Tests/AdaEditorTests/EditorViewportPresentationTests.swift),
[EditorViewportCompassPresentationTests.swift](../../Tests/AdaEditorTests/EditorViewportCompassPresentationTests.swift),
[EditorViewportInteractionPresentationTests.swift](../../Tests/AdaEditorTests/EditorViewportInteractionPresentationTests.swift),
[SceneViewTests.swift](../../../Tests/AdaEngineTests/SceneViewTests.swift).
2D scene UI previews filter active authored UI components before sorting or
decoding hierarchy transforms; scenes without UI skip preview preparation.
Coverage: [EditorSceneViewportPreviewTests.swift](../../Tests/AdaEditorTests/EditorSceneViewportPreviewTests.swift).
The Sprite Inspector authors anchor presets/custom coordinates, stretch/fit/fill,
nine-slice borders and tiled axes/scale through normal scene history and Save.
AdaScript constructors and query writes share these layout values; native AOT
uses equivalent factory lowering. Guide: [SpriteLayout.md](../../Documentation/SpriteLayout.md).
Coverage: [EditorSpriteLayoutTests.swift](../../Tests/AdaEditorTests/EditorSpriteLayoutTests.swift).
The runtime automatically instances Sprite quads on capable Metal/WebGPU devices,
with an expanded-vertex fallback and render-world reference-mode override.
Metal pixels and CPU/upload/GPU timings are validated; WebGPU compilation is
validated while WebGPU/mobile runtime execution remains unverified for this path.
Guide: [SpriteInstancing.md](../../../Documentation/SpriteInstancing.md).

Entry points: [EditorSceneDocumentEditor.swift](../../Sources/AdaEditor/UI/Editor/EditorSceneDocumentEditor.swift),
[EditorSceneModel+Hierarchy.swift](../../Sources/AdaEditor/EditorSceneModel+Hierarchy.swift),
[EditorSceneViewportModel.swift](../../Sources/AdaEditor/UI/Editor/EditorSceneViewportModel.swift),
[EditorDocumentHistory.swift](../../Sources/AdaEditor/UI/Editor/EditorDocumentHistory.swift).
Coverage: [EditorSceneEditingTests.swift](../../Tests/AdaEditorTests/EditorSceneEditingTests.swift),
[EditorSceneInstanceTests.swift](../../Tests/AdaEditorTests/EditorSceneInstanceTests.swift),
[EditorGizmoTests.swift](../../Tests/AdaEditorTests/EditorGizmoTests.swift).

### Inspector and components

Inspector subgroup headers use a stable FNV-1a hash of the component/scriptable
ID and full group path for their tint. Keep colors independent of translated
titles, foldout state and Swift's per-process randomized Hasher.

Add/remove components, typed property controls, asset/entity references,
attachable scripts and exported script fields. Built-in and reflected component
descriptors share the inspector catalog. Specialized editing exists for 2D/3D
physics shapes, mesh primitives/material parameters, cameras, lights, 3D
environment, tile maps and UI components. Live Play inspection has its own model.
Environment 3D's Color Correction group supports smooth master/R/G/B curves and
horizontal-strip texture LUTs with a shared strength and an off mode. Curve drags
commit one history edit. See [../Documentation/ColorCorrection.md](../../../Documentation/ColorCorrection.md).
Coverage: `EditorColorCorrectionTests` and engine `ColorCurves3DTests`.
The reflected `ParticleEmitter3D` component authors world-space smoke/dust settings;
runtime emission uses instanced soft billboards. See `../Documentation/Particles3D.md`
for behavior and rendering boundaries.

Entry points: [EditorComponentRegistry.swift](../../Sources/AdaEditor/EditorComponentRegistry.swift),
[EditorInspectorSidebar.swift](../../Sources/AdaEditor/UI/Editor/EditorInspectorSidebar.swift),
[EditorPlayInspectionModel.swift](../../Sources/AdaEditor/UI/Editor/EditorPlayInspectionModel.swift).
Coverage: [EditorInspectorTests.swift](../../Tests/AdaEditorTests/EditorInspectorTests.swift),
[EditorPhysicsInspectorTests.swift](../../Tests/AdaEditorTests/EditorPhysicsInspectorTests.swift),
[EditorMeshInspectorTests.swift](../../Tests/AdaEditorTests/EditorMeshInspectorTests.swift).
