# AdaEditor Agent Guide

The repository-wide rules in [../AGENTS.md](../AGENTS.md) also apply here.
This file records the editor's existing capabilities so agents can reuse them
and assess gaps before proposing new features.

## Package and workflow

- `Editor/` is a separate Swift 6.2 SwiftPM package, depending on AdaEngine by
  local path. Run editor builds/tests from this directory.
- Shared editor UI uses AdaUI. Native app wrappers and mobile-specific screens
  have separate platform boundaries; do not assume desktop/mobile feature parity.
- [Package.swift](Package.swift) owns package dependencies and resources;
  [project.yml](project.yml) owns XcodeGen app configuration.
- Keep mocks, fixtures, and QA harnesses in test targets or separate executables.
  Do not add test-only objects or QA launch hooks to the main app, including Debug builds.
- Use an isolated scratch/module cache when necessary; never delete the shared
  `.build`. Preserve unrelated engine, demo, and editor changes.
- Debug macOS builds accept `--editor-project=<absolute-path>` to open the
  production workspace directly for native UI validation.
- Public scripting terminology is **AdaScript**. `Gravity*` names are internal
  compiler, VM, and language-tooling implementation names.

## Capability inventory

Snapshot: **2026-10-04**, checked against the current working-tree source and
documentation. “Present” means an implementation exists, not that every
interaction or platform was exercised during this inventory. Test links identify
existing coverage, not a test run performed for this documentation change.

### Projects and files

Project creation/opening, recent projects, project persistence and recovery;
AdaScript and standalone SwiftPM project paths. Project navigator, new-file
templates, asset import/file drop, deletion, file search, Save and Save All.
Project settings cover runtime entry, plugins, input actions and resource roots;
standalone SwiftPM tooling includes dependencies, products, targets and tasks.

Entry points: [ProjectSystem.swift](Sources/AdaEditor/ProjectSystem.swift),
[EditorProjectStore.swift](Sources/AdaEditor/EditorProjectStore.swift),
[EditorViewModel+ProjectConfiguration.swift](Sources/AdaEditor/UI/Editor/EditorViewModel+ProjectConfiguration.swift).
Coverage: [ProjectSystemTests.swift](Tests/AdaEditorTests/ProjectSystemTests.swift),
[EditorFileDropTests.swift](Tests/AdaEditorTests/EditorFileDropTests.swift).

### Workbench and code

Document tabs, tab reordering, Back/Forward navigation, restoration, resizable
panels, and two independently selected document panes with Split/Merge/move
actions. Code and scene documents can remain visible together.
Text editing, syntax highlighting for Swift/AdaScript/YAML/GLSL, completion,
snippet placeholders, hover, definition navigation and diagnostics. Swift uses
SourceKit-LSP; AdaScript uses the embedded language core / language server.
Find in File and Find in Project include case and whole-word controls.

Entry points: [EditorCenterWorkbench.swift](Sources/AdaEditor/UI/Editor/EditorCenterWorkbench.swift),
[EditorWorkbenchViewModel+Split.swift](Sources/AdaEditor/UI/Editor/EditorWorkbenchViewModel+Split.swift),
[EditorViewModel+SourceTooling.swift](Sources/AdaEditor/UI/Editor/EditorViewModel+SourceTooling.swift).
Coverage: [EditorWorkbenchSplitTests.swift](Tests/AdaEditorTests/EditorWorkbenchSplitTests.swift),
[GravityLiveEditorTests.swift](Tests/AdaEditorTests/GravityLiveEditorTests.swift),
[EditorTextSearchTests.swift](Tests/AdaEditorTests/EditorTextSearchTests.swift).

### Entity scenes and viewport

`.ascn` scene documents, YAML/model serialization, entity hierarchy and selection,
entity templates, rename/delete/duplicate/copy/paste/reparent operations.
Reusable nested scenes through `SceneInstance` already exist.
2D/3D viewport modes, camera navigation, picking, grid/rulers/orientation helpers
and Move/Scale/Rotate tools. Scene edits have undo/redo.
2D sprite picking shares the runtime hit test: CPU alpha masks, atlas regions,
anchors, image modes and composed parent transforms before ECS propagation.
Coverage: [EditorSpritePickingTests.swift](Tests/AdaEditorTests/EditorSpritePickingTests.swift).

Entry points: [EditorSceneDocumentEditor.swift](Sources/AdaEditor/UI/Editor/EditorSceneDocumentEditor.swift),
[EditorSceneModel+Hierarchy.swift](Sources/AdaEditor/EditorSceneModel+Hierarchy.swift),
[EditorSceneViewportModel.swift](Sources/AdaEditor/UI/Editor/EditorSceneViewportModel.swift),
[EditorDocumentHistory.swift](Sources/AdaEditor/UI/Editor/EditorDocumentHistory.swift).
Coverage: [EditorSceneEditingTests.swift](Tests/AdaEditorTests/EditorSceneEditingTests.swift),
[EditorSceneInstanceTests.swift](Tests/AdaEditorTests/EditorSceneInstanceTests.swift),
[EditorGizmoTests.swift](Tests/AdaEditorTests/EditorGizmoTests.swift).

### Inspector and components

Add/remove components, typed property controls, asset/entity references,
attachable scripts and exported script fields. Built-in and reflected component
descriptors share the inspector catalog. Specialized editing exists for 2D/3D
physics shapes, mesh primitives/material parameters, cameras, lights, 3D
environment, tile maps and UI components. Live Play inspection has its own model.

Entry points: [EditorComponentRegistry.swift](Sources/AdaEditor/EditorComponentRegistry.swift),
[EditorInspectorSidebar.swift](Sources/AdaEditor/UI/Editor/EditorInspectorSidebar.swift),
[EditorPlayInspectionModel.swift](Sources/AdaEditor/UI/Editor/EditorPlayInspectionModel.swift).
Coverage: [EditorInspectorTests.swift](Tests/AdaEditorTests/EditorInspectorTests.swift),
[EditorPhysicsInspectorTests.swift](Tests/AdaEditorTests/EditorPhysicsInspectorTests.swift),
[EditorMeshInspectorTests.swift](Tests/AdaEditorTests/EditorMeshInspectorTests.swift).

### UI Designer

Reusable `.ui` YAML resources with visual Design, Interact and source modes.
Palette, hierarchy reorder/nesting, property inspector and ordered modifiers,
including background/overlay content. Inputs, actions, preview data, bindings,
conditional/repeated content and nested UI resources. Entity UI components can
bind designed controls to exported gameplay-script fields. Designer undo/redo
and Swift UI export integration are present.

Guide: [UIScenes.md](Documentation/UIScenes.md).
Entry points: [EditorUISceneEditor.swift](Sources/AdaEditor/UI/Editor/EditorUISceneEditor.swift),
[EditorViewModel+UIExports.swift](Sources/AdaEditor/UI/Editor/EditorViewModel+UIExports.swift).
Coverage: [EditorUISceneTests.swift](Tests/AdaEditorTests/EditorUISceneTests.swift),
[EditorScriptUIBindingTests.swift](Tests/AdaEditorTests/EditorScriptUIBindingTests.swift),
[EditorUIExportIntegrationTests.swift](Tests/AdaEditorTests/EditorUIExportIntegrationTests.swift).

### Assets and animation

Image preview, texture-atlas editing, tile-source (`.tileset`) editing, and
tile-map (`.tilemap`) painting/erasing, layers, pan and zoom.
Tile sources author light-occlusion polygons visually; tile maps select cells to
inherit, disable or replace their shadow shape. Shapes and sparse overrides
persist into scene Play while static atlas rendering remains chunked.
Coverage: [EditorTileOcclusionTests.swift](Tests/AdaEditorTests/EditorTileOcclusionTests.swift).
Tile-source bulk creation skips fully transparent cells, respecting margins and
spacing; individually authored tiles remain available.
Tile-map layer controls and the tile palette live in the contextual Inspector,
sharing the active document's model with the full-width canvas.
The tile palette adapts its column count to the Inspector width and builds only
rows near the visible scroll viewport.
GLSL source editing and shader highlighting. Audio/generic assets currently use metadata previews.
Scene keyframe clips have timeline/curve modes, tracks, keyframe values/timing,
interpolation and repeat modes. This is distinct from skeletal-animation tooling.

GLB/glTF models have a dedicated 3D preview with fitted framing, imported
mesh/material/skin counts, named clip selection and Play/Pause. Add to Scene
places a portable `Model3DSource` reference in an open scene, retaining the
original scale and selected clip settings. Imported Model 3D templates and
the Model 3D inspector picker also support this path. Imported hierarchy and
PBR materials appear in edit and Play, with independent animation players and
child-to-authored-entity picking. glTF imports copy local buffers/textures as a
collision-free bundle. Save/reopen, duplicate and scene undo/redo retain references.

Model preview and the selected model's Animator include skeletal graph authoring:
clip/blend/additive nodes, connections, bone/subtree masks and clip event markers.
Graphs preview through the production model renderer and save as structured
`Model3DSource.animationGraph` scene payloads in one undoable transaction.
Scene Animator adds Seek, preview transport, autoplay and latest-event display.
This authors pose graphs; imported skeletal keyframe and retargeting tools remain
separate gaps. See [AnimationGraphs.md](../Documentation/AnimationGraphs.md).
Coverage: [EditorAnimationGraphTests.swift](Tests/AdaEditorTests/EditorAnimationGraphTests.swift).

Entry points: [EditorModelAssetPreview.swift](Sources/AdaEditor/UI/Editor/EditorModelAssetPreview.swift),
[EditorModelAssetImporter.swift](Sources/AdaEditor/EditorModelAssetImporter.swift),
[Model3DSource.swift](../Sources/AdaScene/3D/Model3DSource.swift).
Coverage: [EditorModel3DTests.swift](Tests/AdaEditorTests/EditorModel3DTests.swift).

Entry points: [EditorTextureAtlasAssetEditor.swift](Sources/AdaEditor/UI/Editor/EditorTextureAtlasAssetEditor.swift),
[EditorTileMapEditorModel.swift](Sources/AdaEditor/UI/Editor/EditorTileMapEditorModel.swift),
[EditorKeyframeAnimation.swift](Sources/AdaEditor/EditorKeyframeAnimation.swift).
Coverage: [EditorTextureAtlasTests.swift](Tests/AdaEditorTests/EditorTextureAtlasTests.swift),
[EditorTileMapCanvasTests.swift](Tests/AdaEditorTests/EditorTileMapCanvasTests.swift),
[EditorKeyframeAnimationTests.swift](Tests/AdaEditorTests/EditorKeyframeAnimationTests.swift).

### Build, Play, preview and export

Build/Run/Stop, SwiftPM test/package commands, build output and navigable Problems.
Scene Play and embedded AdaScript project runtime; AdaScript hot reload compiles
dirty source buffers and keeps previous running code when reload fails.
Swift view previews have a dedicated build/host path. AdaPlayer pairing and
project deployment are implemented separately from embedded Play.
Web run/export paths and AdaScript AOT export to macOS/Web/Android exist, with different
toolchain requirements and component support; check the selected path explicitly.

Android export/run also supports Swift AdaEngine App projects, ADB device discovery,
AVD boot, per-project debug signing and toolbar Run/Stop. Physical devices require
authorized USB debugging; host-side export remains standalone macOS only. See
[Android.md](Documentation/Android.md) for setup and verification scope.
Build & Export settings group Android, iOS, Web, Windows, Linux, macOS and VR / XR
tool paths, with file browsing, path checks and host-local persistence. Android JDK,
SDK/NDK and optional Gradle settings retain the existing preference key. SwiftPM,
Web and macOS AdaScript exports consume the selected tools; iOS/XR game export and
cross-platform Windows/Linux packaging from macOS remain unavailable.
Android startup is generated from a top-level, nongeneric `@main App` in the
export copy; private types and explicit target source lists are supported.

Standalone macOS Studio includes `Contents/MacOS/adastudio` and a bundled source
build SDK. The CLI dispatches before app/UI startup and reuses project inspection,
AdaScript validation and native build/export services, with JSON diagnostics and
stable exit codes. CLI/SDK staging is excluded from iOS and App Store wrappers.
Host Swift/Xcode tools and Python 3 remain required; validation scope and current
export limitations are documented in [CLI.md](Documentation/CLI.md).

Entry points: [EditorViewModel+Commands.swift](Sources/AdaEditor/UI/Editor/EditorViewModel+Commands.swift),
[EditorViewModel+AdaScriptHotReload.swift](Sources/AdaEditor/UI/Editor/EditorViewModel+AdaScriptHotReload.swift),
[EditorAdaScriptNativeExporter.swift](Sources/AdaEditor/Tooling/EditorAdaScriptNativeExporter.swift),
[EditorPlayerSession.swift](Sources/AdaEditor/Player/EditorPlayerSession.swift).
Coverage: [EditorAdaScriptHotReloadTests.swift](Tests/AdaEditorTests/EditorAdaScriptHotReloadTests.swift),
[EditorAdaScriptNativeExportTests.swift](Tests/AdaEditorTests/EditorAdaScriptNativeExportTests.swift),
[EditorPlayerProjectTests.swift](Tests/AdaEditorTests/EditorPlayerProjectTests.swift).

### Debugging and performance

Swift/macOS debugging through `lldb-dap`: breakpoints, pause/continue/step,
threads/frames, variables, watches and LLDB commands, with project persistence.
Game Performance panel: update rate, CPU update/p95, process memory, entity count,
ECS-system/render-node CPU durations, bounded history and Chrome Trace export.
Overview/Timeline views share the panel, with an expanded central-workspace mode.
Delayed, duration-limited CPU captures expose selectable event lanes, graph/node
details, filters, zoom and time navigation; overlapping calls use separate rows.
Profiler MCP tools address individual embedded game sessions and captures.

Guides: [Debugging.md](Documentation/Debugging.md),
[PerformancePanel.md](Documentation/PerformancePanel.md).
Coverage: [EditorDebuggerLaunchTests.swift](Tests/AdaEditorTests/EditorDebuggerLaunchTests.swift),
[EditorPerformanceTests.swift](Tests/AdaEditorTests/EditorPerformanceTests.swift).

### Git and agents

Desktop Studio also offers an **Editor / Agent** interface switch in the top
bar. Agent Interface uses a project session tree, conversation tabs, the existing
agent transcript/composer and a document workspace opened on demand. Conversation
content uses a centered column up to 800 points wide; Retry/New Session stay at
the right edge of the full-width tab toolbar. Completed
agent diff events expose changed files; opening one uses the production document
loader. Both interfaces share document state, panel preferences and agent service;
mode selection restores per project. Switching sessions retains in-memory drafts,
attachments, selected-code context and chat mode. Running turns stay attached to
their originating session; one turn runs at a time per project window.
This interface switch is desktop-only; the dedicated iPhone flow is unchanged.
Guide: [AgentInterface.md](Documentation/AgentInterface.md).
Coverage: [EditorAgentWorkspaceTests.swift](Tests/AdaEditorTests/EditorAgentWorkspaceTests.swift).

Desktop Git status, staging, commit, stash, pull/push, branch creation/checkout,
history and diff review. Agent Chat includes transcript/session persistence,
attachments, context selection, permissions, skills and agent settings.
macOS ACP and iPhone SloppyRuntime replies stream native A2UI cards. Ordinary
submissions return to the owning session; reserved local actions apply scene tools
without a new model turn. NPC subtree spawning, color-field editing, structured
scene batches and the system color palette are available. Scene revisions guard
repeat Apply/Undo; desktop uses document history, iPhone uses atomic saved-scene
changes with durable Undo. Card inputs and ownership persist. Desktop Open in UI
Designer creates a project-local `.ui`; iPhone Open UI Source opens its YAML.
Coverage: [EditorChatToolTests.swift](Tests/AdaEditorTests/EditorChatToolTests.swift).
Guide: [A2UI.md](Documentation/A2UI.md).
Entry points: [EditorAgentA2UIController.swift](Sources/AdaEditor/Agent/EditorAgentA2UIController.swift),
[EditorAgentA2UISurfaceCard.swift](Sources/AdaEditor/UI/Editor/EditorAgentA2UISurfaceCard.swift).
Coverage: [EditorAgentA2UITests.swift](Tests/AdaEditorTests/EditorAgentA2UITests.swift),
[EditorAgentA2UITransportTests.swift](Tests/AdaEditorTests/EditorAgentA2UITransportTests.swift).
macOS ACP catalog discovers/installs/connects agents; mobile uses an in-process
SloppyRuntime path when available. The macOS catalog shows bundled ACP Registry logos
and Sloppy branding for installed, discovered and registry agents. New registry logos
load from HTTPS metadata with a shared cache and a generic fallback; icon URLs persist
with managed installations. Editor MCP/host tools expose project/docs/API
context, scene edits, diagnostics, build, simulation, visible Play, frame capture,
web access and asset/image operations. Model texture assignment tools also exist;
they do not constitute a visual 3D asset editor.

Native AI model tools on desktop and mobile inspect/validate GLB/glTF through
CPU native import, import project-local dependency bundles and patch PBR material
factors. Offline docs/API/component/examples tools are shared; bundled workflow
skills are readable on demand through `editor.skills.list/read`. `basic-3d-scene`
is a complete camera/cube/light example. Import validation does not prove GPU
rendering, clip playback or gameplay; Blender execution/generation and rig/clip
authoring remain outside these tools. Desktop scene changes use document revisions
and undo, and asset writes reject matching dirty open documents.

The bundled `ada-game-builder` workflow is advertised in desktop and mobile
session catalogs without per-project installation. Agents load it on demand for
game creation and iteration. It covers playable loops, persistent authoring,
controls/HUD, and build/simulation/visible Play verification using the host's
available tools; catalog discovery does not enforce model selection.

Guide: [Agent3DWorkflow.md](Documentation/Agent3DWorkflow.md).
Entry points: [EditorAgentModelToolService.swift](Sources/AdaEditor/Agent/EditorAgentModelToolService.swift),
[EditorAgentAuthoringMCPTools.swift](Sources/AdaEditor/Agent/EditorAgentAuthoringMCPTools.swift).
Coverage: [EditorAgentModelToolTests.swift](Tests/AdaEditorTests/EditorAgentModelToolTests.swift).

Guides: [AgentCatalog.md](Documentation/AgentCatalog.md),
[MobileAgentTools.md](Documentation/MobileAgentTools.md).
Entry points: [GitReviewService.swift](Sources/AdaEditor/Tooling/GitReviewService.swift),
[EditorAgentViewModel.swift](Sources/AdaEditor/Agent/EditorAgentViewModel.swift).
Coverage: [GitReviewTests.swift](Tests/AdaEditorTests/GitReviewTests.swift),
[EditorAgentCatalogTests.swift](Tests/AdaEditorTests/EditorAgentCatalogTests.swift),
[EditorMobileAgentToolTests.swift](Tests/AdaEditorTests/EditorMobileAgentToolTests.swift).

### Mobile and supporting features

iPhone has dedicated project/files/code/scene/Play/chat/activity/settings screens,
image attachments, screenshot markup and voice input. The shared workspace and
mobile flow have separate implementations and tests.
The iPhone project home and iPad launcher use Studio/Community tabs. Catalog,
search, sorting, details, screenshots and navigation are shared AdaUI views under
`UI/Community`, with no SwiftUI/UIKit dependency. The public client requests PNG
media for the engine's portable decoder. Play rechecks the selected publication. AdaScript API-v1/v2 packages download with
release pinning and SHA-256 verification and run in a separate embedded world/VM;
web builds delegate opening to `Application.openURL` (Android ACTION_VIEW).
The 3D player uses `SceneView(useSceneCameras: true)` to route active authored
cameras into the offscreen viewport while preserving projection and transforms.
API v2 adds 3D rendering/models/physics, scoped `@scriptable` objects and native
Cloud multiplayer. Players choose Solo, Host or Join by code; hosting requires
Cloud sign-in. Room compatibility is bound to the immutable published release,
not authored network settings. The community player rejects native libraries,
external projects/plugins and script UI. It restricts
virtual asset roots from preparation through world teardown, keeps scriptable
registrations local to the game world, and instruments loops/functions with limits;
this is not a separate process or a total native/GPU memory sandbox.
Browsing needs no Cloud sign-in. Studio and Community retain separate navigation;
the last tab restores on launch, and workspace navigation focuses Studio while
preserving its Build/Files/Play tabs.
The home tab bar hides during Studio navigation so it does not overlap workspace controls;
both mobile tab bars use a 6-point bottom padding above the safe area.
The public catalog currently returns up to 100 entries. An Android Studio application shell is not provided by this change.
Entry points: [EditorCommunityView.swift](Sources/AdaEditor/UI/Community/EditorCommunityView.swift),
[MobileEditorHomeTabs.swift](Sources/AdaEditor/UI/Community/MobileEditorHomeTabs.swift),
[EditorCommunityClient.swift](Sources/AdaEditor/Cloud/EditorCommunityClient.swift).
Coverage: [EditorCommunityTests.swift](Tests/AdaEditorTests/EditorCommunityTests.swift).
Bundled offline documentation provides search, sections, history and copyable
examples. Appearance/input settings, notifications/background activities,
achievements/Game Center, cloud account/settings and standalone update UI exist.
Shared AdaUI settings switches place labels and controls at opposite row edges,
with animated thumb movement and track tint; settings rows omit On/Off text.

Ada Cloud AI wallet integration uses the existing account session for catalog,
balance, cursor-paginated usage, quotes, reservations, lookup and cancellation.
Credit counters appear on the start screen, shared workspace toolbar and iPhone navigation;
Cloud settings show available/used/reserved credits and cycle activity. AI credits
are separate from Cloud publishing Pro. Missing/disabled service and signed-out
states do not imply a zero balance. Provider execution, settlement and subscription
SKU activation remain server responsibilities; this client integration does not
turn external/BYOK agents into hosted AI.
Entry points: [EditorCloudAIClient.swift](Sources/AdaEditor/Cloud/EditorCloudAIClient.swift),
[EditorAICreditsModel.swift](Sources/AdaEditor/Cloud/EditorAICreditsModel.swift).
Coverage: [EditorAICreditsTests.swift](Tests/AdaEditorTests/EditorAICreditsTests.swift),
[EditorCloudAILiveTests.swift](Tests/AdaEditorTests/EditorCloudAILiveTests.swift).

Entry points: [MobileEditorRootView.swift](Sources/AdaEditor/UI/Mobile/MobileEditorRootView.swift),
[EditorDocumentation.swift](Sources/AdaEditor/Documentation/EditorDocumentation.swift),
[EditorCloudAccount.swift](Sources/AdaEditor/Cloud/EditorCloudAccount.swift).
Guides: [Notifications.md](Documentation/Notifications.md),
[Achievements.md](Documentation/Achievements.md), [README.md](README.md).

## Confirmed boundaries and incomplete paths

- `EditorDistribution` gates capabilities: Swift projects require standalone;
  App Store distributions expose AdaScript templates. External process tooling
  and local ACP agents must not be assumed available on iOS.
- AdaUI views written in AdaScript (`@view`, UI Script templates/previews,
  `runtime.entry.view`) are temporarily unavailable. The `.ui` Designer and
  gameplay-script field bindings are separate, existing features.
- AdaScript execution debugging / VM pause-resume, mixed Swift/AdaScript debugging
  and an autonomous iPad debugger are not implemented. Saved breakpoint markers
  alone are not execution debugging.
- The embedded AdaScript Web Player's scene validation currently allows only
  Transform, Visibility and TileMapComponent. This restriction belongs to that
  path, not every AOT/Swift Web export path.
- Audio/generic metadata previews do not provide audio playback. GLB/glTF
  import, preview, placement and clip playback exist; visual imported-material
  editing, skeleton editing and skeletal-clip authoring remain incomplete.
  The shared-workbench model preview has not established iPhone UI parity.
- Performance measurements cover CPU/update cadence, not GPU time or display
  FPS. AdaPlayer/external Swift profiling is outside the current panel.
- Agent simulation is logic verification; rendering, audio, network and touch
  interaction require visible Play. Build success is not gameplay verification.

## Keeping this inventory useful

When adding or changing a capability, update its entry and relevant limitations.
Before calling a feature missing, trace its UI entry point, implementation and
nearest tests. Distinguish engine support, editor authoring, platform availability
and runtime validation. Record proposals as proposals; do not list plans or
test filenames as proof of a working feature.
