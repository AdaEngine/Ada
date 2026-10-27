# AdaEditor Agent Guide

The repository-wide rules in [../AGENTS.md](../AGENTS.md) also apply here.
This file records the editor's existing capabilities so agents can reuse them
and assess gaps before proposing new features.

## Package and workflow

- `Editor/` is a separate Swift 6.2 SwiftPM package, depending on AdaEngine by
  local path. Run editor builds/tests from this directory.
- Release wrappers include Studio for iOS/iPadOS, macOS App Store, native visionOS
  and standalone macOS, plus the separate iOS AdaPlayer. `fastlane/SETUP.md`
  documents the `upload_xcode` targets `ios`, `macos`, `visionos` and `player`.
  The visionOS wrapper uses the shared workbench and a dedicated layered icon;
  archive/upload validation does not establish visionOS interaction parity.
- Shared editor UI uses AdaUI. Native app wrappers and mobile-specific screens
  have separate platform boundaries; do not assume desktop/mobile feature parity.
- Windows Studio is built/launched with [../script/run_studio_windows.ps1](../script/run_studio_windows.ps1).
  Windows distributions are always Standalone. The launcher builds Release and
  stages the complete SDK, compilers, runtime DLLs and resources through the release
  packager before opening it. Do not launch a bare SwiftPM executable or a partial
  staging folder for user validation; Android and Web require the bundled SDK.
  It prepares pinned Tint and a task-local Gravity binding with C-owned UTF-8
  strings, selecting it through `ADAENGINE_GRAVITY_PACKAGE_PATH`. Manual Windows
  builds/tests must use that override too. Native project/asset file pickers,
  RGB color selection (inspector alpha), HTTPS downloads, local Run and D3D12
  readback are implemented. Windows also has a menu row, native Settings window,
  contextual cursors, Cloud browser PKCE sign-in with Credential Manager, and
  WinSock/DNS-SD AdaPlayer pairing (including manual host:port). Apple in-app
  purchases remain Apple-only. WebAssembly and Android compilation use the WSL
  worker prepared by `../script/setup_windows_build_tools.ps1`; adb/emulator run
  natively on Windows. See [README.md](README.md#Windows).
- [Package.swift](Package.swift) owns package dependencies and resources;
  [project.yml](project.yml) owns XcodeGen app configuration.
- Windows release CI uses `../script/build_studio_windows.ps1` and
  `../script/package_studio_windows.py`. It publishes an x64 ZIP and SHA-256 on
  GitHub Release publication; manual/PR builds retain Actions artifacts. Packaging
  bundles Swift/Dawn runtime DLLs, resources, Tint and a relocatable `BuildSDK`
  beside the executable. It checks PE imports and launches the tools with a clean
  PATH. Windows signing and external host/export toolchains remain separate.
- Build & Export scans host tools on page entry and provides Rescan plus official
  Swift/Android setup links. Discovery fills missing/broken paths in the settings
  draft, preserves valid overrides, and requires Save Build Settings to persist.
  Windows discovery rereads registry environment and standard install locations;
  native Windows tools must not fill WSL Web compiler/Tint fields. Setup links
  open browser guides; they do not perform unattended installation.
- Keep mocks, fixtures, and QA harnesses in test targets or separate executables.
  Do not add test-only objects or QA launch hooks to the main app, including Debug builds.
- Linux Standalone uses X11/XWayland and Vulkan. Follow
  [../Documentation/Linux.md](../Documentation/Linux.md) and launch through
  `../script/run_studio_linux.sh` to stage resources, runtime libraries and BuildSDK.
  Use the bundled Gravity compiler and staged Linux Swan overrides for builds/tests;
  native dialogs require Zenity. The initial Linux workbench/local Run port does
  not establish remote AdaPlayer, ACP, debugger, Cloud or cross-export parity.
- Use an isolated scratch/module cache when necessary; never delete the shared
  `.build`. Preserve unrelated engine, demo, and editor changes.
- Debug macOS builds accept `--editor-project=<absolute-path>` to open the
  production workspace directly for native UI validation.
- Public scripting terminology is **AdaScript**. `Gravity*` names are internal
  compiler, VM, and language-tooling implementation names.

## Localization (required for every UI change)

- Ada Studio supports **English (`en`) and Russian (`ru`)**. Always write
  user-facing text for localization, including labels, tooltips, placeholders,
  menus, dialogs, accessibility labels, empty states and app-authored errors.
- Add or update both translations automatically in the same change, under
  `Sources/AdaEditor/Assets/Localization/en.json` and `ru.json`. Do not leave
  Russian translations for a follow-up task. Use clear, friendly Russian that
  a young reader can understand; keep product names and code/API identifiers.
- Use `L10n.text("Text with \(value)")` for interpolated UI messages and
  `L10n.tr(key)` when rendering a stable key supplied by a model or UI helper.
  Preserve numbered placeholders in both catalogs. Never concatenate translated
  sentence fragments or translate user text, source code, file paths, persisted
  enum values, protocol keys or accessibility identifiers.
- `EditorLocalization` owns the saved app language. The default follows the
  system's preferred languages, selecting Russian or English with English as
  fallback. Desktop General > Language and mobile Settings expose System,
  English and Russian; changes update mounted UI through Observation.
- Keep routing, settings page IDs and automation identifiers language-independent.
  Translate at presentation boundaries. Shared AdaUI and native platform UI must
  use the same preference; do not independently check `Locale.preferredLanguages`.
- Run `python ../script/check_studio_localization.py` from `Editor/` and
  `swift test --filter EditorLocalizationTests` after changing
  localized UI. Test switching languages with the existing view mounted, and
  check that longer Russian text fits the affected controls.

## Capability inventory

### Browser Studio

`WebUI/` is the default React/DOM browser shell, with inset floating panels over
a full-width viewport: a full-height assistant on the left, scene panels on the
right, a bottom log console and native text inputs. The scene viewport and Play use one isolated fixed AdaPlayer
with authored cameras, materials and lighting. Opening a project loads the engine;
document/mode changes replace its world without recreating WASM or the GPU device.
There is no separate SVG scene renderer. Editor mode disables gameplay, physics
and autoplay. Hierarchy/viewport bounds picking, move/rotate/scale gizmos, snapping,
duplicate/delete and a transient free camera are available. Gizmo gestures commit
one undo transaction; navigation never changes authored cameras. CodeMirror provides
AdaScript highlighting, indentation and search. It implements the existing
portable snapshot/scene/API contracts with transactions/undo, cloud recovery, ZIP
interchange and an in-tab agent. The entry library uses
Games/Create/My projects/Account navigation and the public catalog independently
of Studio sign-in. Opening a workspace switches the rail
to overview, scene, assets, code and assistant within that project. The Ada mark
returns to Games through the same save/recovery path as All Projects. The overview
button opens the project overview; All Projects waits for cloud save and retains the current document, undo, selection and Player for Continue.
Save failure offers Stay, retry, ZIP or an explicit IndexedDB-backed local exit;
failed local writes keep the project open. Closing a tab with unsaved changes or
an active agent requests browser confirmation. `Web/` retains the prior AdaUI/WASM application
(`AdaEditorWeb`) behind `--legacy-wasm-editor`, including its UGC publication UI;
publication controls are not yet ported to DOM. Native Studio uses the shared
`StudioCore/` value codec and supported runtime component contract. The browser does
not use native ACP, processes, SourceKit, key storage or file dialogs. See
[Documentation/StudioWeb.md](Documentation/StudioWeb.md) for export, service
boundaries and the browser release gate; source presence is not acceptance of a
hosted deployment or a live paid provider.

The browser assistant exports native bundled skills, documentation, examples and
the A2UI prompt at build time. Conversations, drafts, attachments, selected skills,
progress and interactive forms persist with the project. Build/plan modes and
optional per-tool approval use a fixed 38-tool registry. A2UI uses validated DOM
controls and native action envelopes; local scene actions and their durable Undo
are atomic and revision checked. The isolated Player runs native procedural asset
generators and exports `.ui` through AdaA2UI. Browser chrome, inspector, source search and embedded Cloud panels use the shared
en/ru catalogs and language preference enum. Language changes preserve mounted input;
the frontend build rejects hardcoded Russian UI literals and missing translations. OS/process,
external MCP, search, TestWorld and publication tools remain unavailable here.

Web Annotate selects entities via hierarchy/native viewport, A2UI components, or
canvas UI via a marked frame/point. Its popup adds context to the originating
conversation's persistent composer; only Send invokes the agent. Selection
stays active after Add for collecting multiple notes. Numbered chips and current
viewport pins reopen the note for editing; numbers remain stable when other notes
are removed, and one Send includes all pending notes in the same request. Pins
are scoped to the current selection session so camera movement cannot leave stale
screen markers. Selection suppresses form actions and gizmos. Notes survive Cloud reopen; manually edited
composer text remains authoritative. Canvas UI has no semantic native hit tree.

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

The HUB Samples section loads the official AdaExamples catalog, supports search
by name/tags, downloads a separate editable project into a selected folder, and
opens it through the ordinary project loader. Swift projects require standalone.
`ADAEXAMPLES_PATH` selects a local catalog for development; otherwise catalog and
files use one pinned GitHub commit. Games live in AdaExamples, with independent
engine regression fixtures. Guide: [Examples.md](Documentation/Examples.md).
Coverage: [EditorExampleCatalogTests.swift](Tests/AdaEditorTests/EditorExampleCatalogTests.swift).

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
Selection reuses the parsed scene model and retains preview entities for editor-only
state changes. Large terrain payloads use bulk YAML node construction; regression
coverage: [EditorSceneSelectionRegressionTests.swift](Tests/AdaEditorTests/EditorSceneSelectionRegressionTests.swift).
The hierarchy and project tree own hover state and drawing caches per mounted row.
Pointer-motion and neighboring-row cache coverage:
[EditorSidebarHoverTests.swift](Tests/AdaEditorTests/EditorSidebarHoverTests.swift).
Window dispatch coalesces consecutive hover moves while preserving the raw scene
event stream and gesture boundaries. Coverage:
[EditorWindowHoverInputTests.swift](Tests/AdaEditorTests/EditorWindowHoverInputTests.swift).
Viewport annotations are captured with each scheduled scene frame and published
with its completed texture at the next UI tick. Their Canvas drawing revisions
refresh synchronously without rebuilding the viewport; 3D rotation leaves hidden
rulers and unchanged status text alone. The compass observes its own presented
camera orientation. Gizmo hover/drag use the displayed geometry, mapping pointer
coordinates into the captured target while resizing. Coverage:
[EditorViewportPresentationTests.swift](Tests/AdaEditorTests/EditorViewportPresentationTests.swift),
[EditorViewportCompassPresentationTests.swift](Tests/AdaEditorTests/EditorViewportCompassPresentationTests.swift),
[EditorViewportInteractionPresentationTests.swift](Tests/AdaEditorTests/EditorViewportInteractionPresentationTests.swift),
[SceneViewTests.swift](../Tests/AdaEngineTests/SceneViewTests.swift).
2D scene UI previews filter active authored UI components before sorting or
decoding hierarchy transforms; scenes without UI skip preview preparation.
Coverage: [EditorSceneViewportPreviewTests.swift](Tests/AdaEditorTests/EditorSceneViewportPreviewTests.swift).
The Sprite Inspector authors anchor presets/custom coordinates, stretch/fit/fill,
nine-slice borders and tiled axes/scale through normal scene history and Save.
AdaScript constructors and query writes share these layout values; native AOT
uses equivalent factory lowering. Guide: [SpriteLayout.md](Documentation/SpriteLayout.md).
Coverage: [EditorSpriteLayoutTests.swift](Tests/AdaEditorTests/EditorSpriteLayoutTests.swift).
The runtime automatically instances Sprite quads on capable Metal/WebGPU devices,
with an expanded-vertex fallback and render-world reference-mode override.
Metal pixels and CPU/upload/GPU timings are validated; WebGPU compilation is
validated while WebGPU/mobile runtime execution remains unverified for this path.
Guide: [SpriteInstancing.md](../Documentation/SpriteInstancing.md).

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

Design supports palette/hierarchy/canvas drag and drop, stack insertion, and
responsive free placement through AdaUI FreeLayout/relativePosition. Drops use
one history transaction; compact iPad layouts retain pointer capture while
revealing the canvas, with held touches for drag and quick swipes for scrolling.

Guide: [UIScenes.md](Documentation/UIScenes.md).
Entry points: [EditorUISceneEditor.swift](Sources/AdaEditor/UI/Editor/EditorUISceneEditor.swift),
[EditorViewModel+UIExports.swift](Sources/AdaEditor/UI/Editor/EditorViewModel+UIExports.swift).
Coverage: [EditorUISceneTests.swift](Tests/AdaEditorTests/EditorUISceneTests.swift),
[EditorScriptUIBindingTests.swift](Tests/AdaEditorTests/EditorScriptUIBindingTests.swift),
[EditorUIExportIntegrationTests.swift](Tests/AdaEditorTests/EditorUIExportIntegrationTests.swift).

### Assets and animation

Spine 4.2 `.skel`/`.spine` assets have a native 2D preview with clip/skin
selection, Play/Pause and bone overlays. Import/drop carries the atlas and pages;
JSON exports are imported as `.spine`. Add to Scene and the Spine Character 2D
template store a portable `SpineSource` component with playback/bone settings.
Imported 3D skins also have a Show/Hide bones overlay in the asset viewer and
3D scene viewport (edit and Play). `EditorSkeleton3DPlugin` installs the drawing
system after scheduler setup; the overlay follows the current skeletal pose.
See [Spine2D.md](Documentation/Spine2D.md). Skeleton/keyframe authoring and public
player/export integration are separate. Coverage: `EditorSpineTests` and
`SpineSceneTests`; native validation must exercise the Studio viewport.

Image preview includes a shared texture Inspector with sampler filters/wrap/LOD,
CPU-generated mip levels, Color/Normal/Data purpose, sRGB/Linear settings, and
2D/Cube import from a six-face horizontal strip. Apply persists an adjacent
`.texture.json`; preview selects applied levels/faces. Existing Play resources
require reloading. Guide: [TextureSettings.md](Documentation/TextureSettings.md).
Coverage: [EditorTextureSettingsTests.swift](Tests/AdaEditorTests/EditorTextureSettingsTests.swift).
Texture-atlas editing, tile-source (`.tileset`) editing, and
tile-map (`.tilemap`) painting/erasing, layers, pan and zoom.
Tile sources author light-occlusion polygons visually; tile maps select cells to
inherit, disable or replace their shadow shape. Shapes and sparse overrides
persist into scene Play while static atlas rendering remains chunked.
Coverage: [EditorTileOcclusionTests.swift](Tests/AdaEditorTests/EditorTileOcclusionTests.swift).
Tile-source bulk creation skips fully transparent cells, respecting margins and
spacing; individually authored tiles remain available.
Tile-map layer controls and the tile palette live in the contextual Inspector,
sharing the active document's model with the full-width canvas.
The Inspector also authors all eight brush/selected-cell tile orientations.
Canvas previews retain rectangular cell dimensions; layered resources preserve
orientation IDs. AdaScript can enqueue orientation changes to existing tiles.
Coverage: [EditorTileOrientationTests.swift](Tests/AdaEditorTests/EditorTileOrientationTests.swift).
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

MagicaVoxel `.vox` files are model assets too (`EditorModelResource.extensions`). Import
and drop copy the file as is (no dependencies); the preview reports frame count and
rate, and its Play/Pause drives the voxel clock (`VoxelAnimationPlayback3DComponent`)
as well as skeletal clips. The Model 3D inspector adds `voxelSize`,
`voxelMergeStatic` and `voxelFramesPerSecond`; they decode into
`Model3DSource.voxel` (nil while all are default) and reach the importer as an
asset query through `Model3DSource.assetPath`. Scene loading uses `assetPath` too.
glTF-specific tooling (agent model tools, texture assignment) uses
`EditorModelResource.gltfExtensions` and rejects `.vox`. Community packages still
accept only glTF models; adding `.vox` there needs a content validator.

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
AdaScript projects run their `@test` functions in process (ADR-0024) through
`EditorAdaScriptTestRunner` and `EditorViewModel.runAdaScriptTests`: sources from the project's
source root and `Tests/`, a 30 s per-test limit, streamed PASS/FAIL lines in Output, and counts
in `editor.task.status` (`adaScriptTests`). Coverage:
[EditorAdaScriptTestRunnerTests.swift](Tests/AdaEditorTests/EditorAdaScriptTestRunnerTests.swift).
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

Standalone desktop has a workspace-owned SwiftTerm/AdaUI terminal backed by
Unix PTY or Windows ConPTY. Terminal mode shows only shell tabs and icon actions;
each tab retains an independent shell and the grid follows window/panel resizing.
The left console tool opens Terminal; Output keeps
the Game/Editor logs. Windows launchers prepare LF SwiftTerm sources through
`ensure_windows_swiftterm.py` and `ADAEDITOR_SWIFTTERM_PACKAGE_PATH`; manual builds
need that override too. Tests lists discovered AdaScript/Swift tests with statuses
and exact single-function runs. See [WorkbenchPanels.md](Documentation/WorkbenchPanels.md)
and `EditorTestExplorerTests`, `EditorTerminalTests`, `EditorWorkbenchPanelTests`.
These source paths do not establish macOS/Linux UI validation.

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

Project-local AdaScript `@tool` extensions can mount right-sidebar `.ui` panels
in the macOS workspace's Studio Tools section. An explicit access dialog grants the
declared document read/write permissions before activation. Project Settings →
Studio Tools owns enablement and immediate access revocation. Exported scalar inputs and synchronous
named actions use detached UI data; successful entity batches enter scene Undo/Redo.
Disable/close removes contributions, and invalid reloads retain the previous
working version. iPadOS activation and command/menu/formatter/settings/event
registrations remain unavailable in this initial host.
Guide: [StudioTools.md](Documentation/StudioTools.md).
Coverage: [EditorStudioToolsTests.swift](Tests/AdaEditorTests/EditorStudioToolsTests.swift).

Desktop and visionOS Studio offer an **Editor / Agent** interface switch in the top
bar. Agent Interface uses a project session tree, conversation tabs, the existing
agent transcript/composer and a document workspace opened on demand. Conversation
content uses a centered column up to 800 points wide; Retry/New Session stay at
the right edge of the full-width tab toolbar. Completed
agent diff events expose changed files; opening one uses the production document
loader. Both interfaces share document state, panel preferences and agent service;
mode selection restores per project. Switching sessions retains in-memory drafts,
attachments, selected-code context and chat mode. Running turns stay attached to
their originating session; one turn runs at a time per project window.
The dedicated iPhone flow is unchanged. visionOS hides editor panel/tab ornaments
in Agent mode and restores the last normal window size after leaving immersion.
Guide: [AgentInterface.md](Documentation/AgentInterface.md).
Coverage: [EditorAgentWorkspaceTests.swift](Tests/AdaEditorTests/EditorAgentWorkspaceTests.swift).

Desktop Git status, staging, commit, stash, pull/push, branch creation/checkout,
history and diff review. Agent Chat includes transcript/session persistence,
attachments, context selection, permissions, skills and agent settings.
The shared sidebar/workspace composer offers a debounced, full-draft completion
while typing and up to three next-message suggestions after a successful saved
reply. Chips fill an editable draft without sending; Enter retains ordinary
submission and slash/@ completion behavior. Suggestions can be dismissed and
refresh with the app language. Generation uses the local Foundation Models model
only on supported, available Apple systems, with contextual/history suggestions
as a fallback; it does not make a separate ACP or hosted-model request.
Coverage: [EditorAgentSuggestionUITests.swift](Tests/AdaEditorTests/EditorAgentSuggestionUITests.swift).
macOS/Windows ACP and iPhone SloppyRuntime replies stream native A2UI cards. Ordinary
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
macOS/Windows ACP catalog discovers/installs/connects agents; mobile uses an in-process
SloppyRuntime path when available. Windows reuses ACPModel and the shared editor service
with native stdio JSON-RPC, suspended process/job startup, explicit inherited handles,
literal argv, file/terminal callbacks and MCP stdio bridging. Native Windows registry
binaries are preferred; npm launchers resolve to Node.js without a command shell.
Node.js/uv remain prerequisites for their package distributions. Windows process-backed
coverage includes session/model state, streaming, cancellation, permissions, files,
terminals, MCP and A2UI. Provider account authentication requires the agent's own setup.
The macOS catalog shows bundled ACP Registry logos
and Sloppy branding for installed, discovered and registry agents. New registry logos
load from HTTPS metadata with a shared cache and a generic fallback; icon URLs persist
with managed installations. Editor MCP/host tools expose project/docs/API
context, scene edits, diagnostics, build, simulation, visible Play, frame capture,
web access and asset/image operations. Model texture assignment tools also exist;
they do not constitute a visual 3D asset editor.

Desktop game verification: `editor.play.capture` and `render.capture_screenshot`
(through AdaMCP's `captureOverride`) return the completed frame of the running
game's own camera (2D or 3D `SceneView` that opted in with `frameCaptureLabel`),
never the editor window; without a running game `editor.play.capture` errors and
`render.capture_screenshot` falls back to the editor window, labelled as such in
its `world` field. `editor.play.run_scenario` replays timed key/mouse input in an
isolated offscreen runtime (or the running Play game), saves frames under
`.ada/workspace/agent-captures`, and returns entity/component snapshots, script
logs and limits-bounded results; the offscreen runtime renders scene cameras, not
the `@view` HUD. Snapshots include `componentFields` for native and world-scoped
AdaScript component schemas, preserving structured scalar/vector values. Watch
filters accept qualified native names and runtime stable IDs/aliases. Timed pointer
moves emit relative motion events as well as position updates. Coverage:
`EditorScenarioComponentSnapshotTests`. Guide: [MobileAgentTools.md](Documentation/MobileAgentTools.md#desktop-game-verification).
Coverage: [EditorPlayScenarioTests.swift](Tests/AdaEditorTests/EditorPlayScenarioTests.swift),
engine [SceneViewFrameCaptureTests.swift](../Tests/AdaEngineTests/SceneViewFrameCaptureTests.swift).

Native AI model tools on desktop and mobile inspect/validate GLB/glTF through
CPU native import, import project-local dependency bundles and patch PBR material
factors. Offline docs/API/component/examples tools are shared; bundled workflow
skills are readable on demand through `editor.skills.list/read`. `basic-3d-scene`
is a complete camera/cube/light example. Import validation does not prove GPU
rendering, clip playback or gameplay; Blender execution, rig/clip authoring and
organic or skinned model generation remain outside these tools. Desktop scene changes use document revisions
and undo, and asset writes reject matching dirty open documents.

The bundled `ada-game-builder` workflow is advertised in desktop and mobile
session catalogs without per-project installation. Agents load it on demand for
game creation and iteration. It covers playable loops, persistent authoring,
controls/HUD, and build/simulation/visible Play verification using the host's
available tools; catalog discovery does not enforce model selection.

Scripted asset generation ([ADR-0026](../Documentation/ArchitectureDecisions/0026-scripted-asset-generation-and-autonomous-studio.md)):
`editor.voxel.generate` (`.vox`), `editor.model.generate` (`.glb`), `editor.audio.generate` (`.wav`)
and `editor.sprite.generate` (`.png`) run an agent-authored AdaScript `build` function in an isolated VM and
write a new file under the assets root (never overwriting); `editor.audio.inspect` measures any WAV (peak,
loudness, clipping, silence, pitch, envelope). Skills `ada-voxel-models`, `ada-procedural-models`,
`ada-pixel-art` and `ada-sound-design` document the script APIs, and a test runs their examples.
`ada-autonomous-studio` is the whole-game workflow (clarify, `DESIGN.md` with acceptance criteria,
`PLAN.md` milestones, build-play-check loop, acceptance pass). The `AudioSource` component plays WAV/MP3/FLAC
in scenes and from scripts and has an inspector descriptor. Music and voices need a provider (not implemented);
agent sounds are measured, never heard; desktop has no stepped gameplay simulation yet.
Autonomous-run harness rules (skill text, not enforced by code): `ada-autonomous-studio` opens with a start
card (context once into `PROGRESS.md` "Facts", only the required skills, one research pass, notes before code),
plans M1 playable core, M2 art and sound (3-6 generated sounds wired through `AudioSource`) right after it,
then content and polish, forbids planning "primitives"/"silence" when generators exist, and limits stalling
(about 10 reads in a row, 3 attempts per check, unavailable checks become `blocker:`/`manual:` and the run
continues). `ada-coding` requires a file layout decided in `DESIGN.md` before code: one responsibility per
file, `Components`/`Systems`/`Rules`/`Config`/`UI`/`Tests`/`Generators` folders, size limits, balance numbers in `Config`;
Swift projects get the same rules in their own `AGENTS.md`.
`editor.examples.list` takes an optional `query` over ids, descriptions and tags. `side-scroller-3d`
([Assets/Examples/side-scroller-3d](Sources/AdaEditor/Assets/Examples/side-scroller-3d)) is a complete multi-file
3D flappy/runner game (files on disk; the project JSON and scene are generated by
[EditorAgentBundledExamples.swift](Sources/AdaEditor/Agent/EditorAgentBundledExamples.swift)) with `@query` systems,
input actions, a reused obstacle pool, collisions, score, restart, `AudioSource` cues, a `.ui` HUD, `@test` tests and
asset generator sources. Its production sources and tests are compiled and run, its scene is checked against the scripts,
and the `// recipe` blocks of [AdaScriptGameplayRecipes.md](Documentation/AdaScriptGameplayRecipes.md) (also in the offline
documentation) are executed. Regenerate the offline snapshot with `python3 scripts/update-offline-documentation.py`.
Entry points: [EditorAgentGeneratorToolService.swift](Sources/AdaEditor/Agent/EditorAgentGeneratorToolService.swift),
[EditorAudioSourceComponentDescriptor.swift](Sources/AdaEditor/EditorAudioSourceComponentDescriptor.swift).
Coverage: [EditorAgentExampleTests.swift](Tests/AdaEditorTests/EditorAgentExampleTests.swift),
[EditorAgentMediaGenerateTests.swift](Tests/AdaEditorTests/EditorAgentMediaGenerateTests.swift),
[EditorAgentModelGenerateTests.swift](Tests/AdaEditorTests/EditorAgentModelGenerateTests.swift),
[EditorAgentVoxelToolTests.swift](Tests/AdaEditorTests/EditorAgentVoxelToolTests.swift).

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

Mobile Studio's project settings include Publish, opening title/description, cover and
up to five screenshot fields. Cloud sign-in and Pro are required. Saved AdaScript
projects are packaged on-device and submitted as permanent Community releases in
`pending` review; approval updates the same app card. Identical retries reuse the
submission and uploaded media. Native libraries, external/custom resource roots,
custom plugins and script UI are unavailable in the public player.
The bundled `ada-community-publish` skill and `editor.community.submit` tool share
this path on mobile and desktop; desktop requires saving dirty documents first.
Coverage: [EditorPublicationTests.swift](Tests/AdaEditorTests/EditorPublicationTests.swift).
Guide: [CommunityPublishing.md](Documentation/CommunityPublishing.md).

iPhone has dedicated project/files/code/scene/Play/chat/activity/settings screens,
image attachments, screenshot markup and voice input. Dictation uses on-device
`SpeechAnalyzer`/`SpeechTranscriber` on iOS/visionOS 26+ (language model downloads on
first use) and falls back to `SFSpeechRecognizer` on older systems or unsupported locales. The shared workspace and
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
Both mobile tab bars use automatic placement: a vertical glass strip on phone
displays with a side safe area, or bottom controls with 6-point padding on ordinary
displays. Native hinge updates expose angle, posture and opening percentage through
the AdaUI environment and `WindowHingeChanged`. The old simulated Foldable Preview
selector and saved preview setting have been removed; legacy projects still decode.
The public catalog currently returns up to 100 entries. The Android mobile host
reuses the mobile screens and adds NativeActivity services for keyboard input,
Back, document selection, dictation, speech output and encrypted credentials.
Build it with `Platforms/Android/studio.py`; see [AndroidMobile.md](Documentation/AndroidMobile.md).
Android background agent execution, clipboard image paste and Google Play Billing
remain unavailable. Compilation and packaging checks do not establish interaction parity.
Entry points: [EditorCommunityView.swift](Sources/AdaEditor/UI/Community/EditorCommunityView.swift),
[MobileEditorHomeTabs.swift](Sources/AdaEditor/UI/Community/MobileEditorHomeTabs.swift),
[EditorCommunityClient.swift](Sources/AdaEditor/Cloud/EditorCommunityClient.swift).
Coverage: [EditorCommunityTests.swift](Tests/AdaEditorTests/EditorCommunityTests.swift).
Bundled offline documentation provides search, sections, history and copyable
examples. Appearance/input settings, notifications/background activities,
achievements/Game Center, cloud account/settings and standalone update UI exist.
Shared AdaUI settings switches place labels and controls at opposite row edges,
with animated thumb movement and track tint; settings rows omit On/Off text.

Cloud Pro includes 500 shared monthly AI credits. Browser Studio selects hosted Coder Next from the server registry and shows remaining/used/reserved credits and renewal; missing service is distinct from an empty balance. BYOK/local connections remain independent.

Ada Cloud AI wallet integration uses the existing account session for catalog,
balance, cursor-paginated usage, quotes, reservations, lookup and cancellation.
Credit counters appear on the start screen, shared workspace toolbar and iPhone navigation;
Cloud settings show available/used/reserved credits and cycle activity. AI credits
are separate from Cloud publishing Pro. Missing/disabled service and signed-out
states do not imply a zero balance. Hosted Ada AI uses the shared Cloud account transport, Coder Next tool loop and server wallet. Desktop selects the built-in Ada AI entry; mobile selects Ada AI in Providers. Tool mutations require approval; Cloud conversations persist separately from external runtime sessions. Provider keys and settlement stay server-side, and external/BYOK agents remain independent.
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

- Native Shader Graph includes typed graph/GLSL, Sprite and PBR materials,
  the AdaUI workbench editor and real AdaScript VM/AOT parameter bindings.
  Graph preview and editing controls live in the contextual Inspector. Search
  has a bordered search input and typed result rows; toolbar actions use visible
  icon buttons and parameter cards show selection. Color nodes have the native
  color picker and named RGBA channels; vectors use X/Y/Z/W fields.
  Source uses the shared read-only code editor with GLSL highlighting, line numbers,
  folding, selection/copy and workbench font/palette preferences; graph edits refresh it.
  Search overlays the canvas; canvas-local input updates after layout/zoom changes and
  supports middle-button panning over nodes/ports. Wires can be selected and
  deleted with Delete/Backspace or the context menu, with Undo. File trees and tabs use the
  Shader Graph icon. Coverage: `EditorNodeCanvasTests`, `EditorShaderGraphWorkbenchTests`,
  `EditorShaderGraphControlsTests`, `EditorShaderGraphSourceTests`.
  Export acceptance is incomplete: browser Player startup, packaged native
  playback, final device Play and performance checks remain. See
  [ShaderGraph.md](Documentation/ShaderGraph.md) and
  [ShaderGraphHandoff.md](Documentation/ShaderGraphHandoff.md) for current limits.
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
- Audio/generic metadata previews do not provide audio playback in the asset browser; sounds play
  through the `AudioSource` component in Play. GLB/glTF
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

### Unified Playground web entry

`Editor/WebUI` owns Games/Create/My projects and the editor in one shell. Robot
artwork stays in `assets/playground`. Canonical routes include `/games`, `/create`,
`/projects/:id`, `/account` and `/publications/:id`; `/studio/` is a compatibility
entry and `/studio/*` serves static assets. Shared account/auth/legal/publication
panels are built from adawebsite (`npm run build:panels`) and embedded without an
iframe. Every navigation uses the existing save/leave guard. Keep publication
page IDs separate from private workspace IDs and retain native/Store auth callbacks.
