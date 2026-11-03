# Build, Play and Export

Read this reference only when the task touches this area. Return to [the editor guide](../../AGENTS.md) for routing and shared rules.

Paths in code spans and commands retain their original `Editor/` working-directory context unless explicitly repository-relative; Markdown links resolve from this file.

This inventory was originally recorded on **2026-10-04** and subsequently maintained. Implementation and test links identify existing coverage, not a validation run or platform acceptance.

### Build, Play, preview and export

The shared desktop toolbar has named build targets and an Edit Build Targets
dialog (create/duplicate/rename/delete, scene, Debug/Release, destination, arguments
and file/resource selection). `.ada/project.json` stores `buildTargets` and
`activeBuildTargetID`. Activation projects settings onto the ordinary project
fields; `ProjectSystem.saveProject` captures subsequent Project Settings edits
into the active target. Preserve this projection when adding consumers. Target
editing is a disposable draft until Save. Legacy projects gain no targets until
the user saves the editor. AdaScript project-source membership applies to the
builder and scriptable-object/export catalog; dependencies stay included. Desktop
native exports use per-target output subdirectories. Browser/phone target editing
is not exposed. See [BuildExport.md](../../Documentation/BuildExport.md) and
`EditorBuildTargetsTests`.

The shared desktop toolbar includes Movie Maker capture settings: project/current
scene, FPS, resolution, duration, output path and audio. Preferences persist per
project in `.ada/workspace/movie-maker.json`. Recording uses the engine's fixed-step
PNG/WAV writer, prepares scene assets before frame zero, reports progress and supports
Stop/cancellation without replacing existing takes. Project recording uses the AdaScript
Play configuration; Swift projects can record Current Scene through Scene Play, rather
than their external executable. Camera-external HUD overlays are not included.
Guide: [MovieMaker.md](../../Documentation/MovieMaker.md). Entry points:
`EditorMovieMakerModel`, `EditorMovieMakerRuntime`, `EditorMovieMakerDialog` and
`EditorViewModel+MovieMaker`. Coverage: `EditorMovieMakerTests`, the mounted dialog
test in `EditorLocalizationTests`, and opt-in `EditorMovieMakerGPUTests`.

Build/Run/Stop, SwiftPM test/package commands, build output and navigable Problems.
AdaScript projects run their `@test` functions in process (ADR-0024) through
`EditorAdaScriptTestRunner` and `EditorViewModel.runAdaScriptTests`: sources from the project's
source root and `Tests/`, a 30 s per-test limit, streamed PASS/FAIL lines in Output, and counts
in `editor.task.status` (`adaScriptTests`). Coverage:
[EditorAdaScriptTestRunnerTests.swift](../../Tests/AdaEditorTests/EditorAdaScriptTestRunnerTests.swift).
Scene Play and embedded AdaScript project runtime; AdaScript hot reload compiles
dirty source buffers and keeps previous running code when reload fails.
Swift view previews have a dedicated build/host path. AdaPlayer pairing and
project deployment are implemented separately from embedded Play.
Web run/export paths and AdaScript AOT export to macOS/Web/Android exist, with different
toolchain requirements and component support; check the selected path explicitly.

Android export/run also supports Swift AdaEngine App projects, ADB device discovery,
AVD boot, per-project debug signing and toolbar Run/Stop. Physical devices require
authorized USB debugging; host-side export remains standalone macOS only. See
[Android.md](../../Documentation/Android.md) for setup and verification scope.
Build & Export settings group Android, iOS, Web, Windows, Linux, macOS and VR / XR
tool paths, with file browsing, path checks and host-local persistence. Android JDK,
SDK/NDK and optional Gradle settings retain the existing preference key. SwiftPM,
Web and macOS AdaScript exports consume the selected tools; iOS/XR game export and
cross-platform Windows/Linux packaging from macOS remain unavailable.
Android startup is generated from a top-level, nongeneric `@main App` in the
export copy; private types and explicit target source lists are supported.

Standalone macOS Studio includes `Contents/MacOS/adastudio`; Windows distributions
include a console `adastudio.exe` beside `AdaEditor.exe` and an adjacent source
build SDK. Linux stages an `adastudio` launcher through `ada-studio` and supports
headless inspection/validation, but not CLI app export. The standalone application
menu installs the command in the current user's PATH on all three desktop platforms
(macOS/Linux shell profiles and `~/.local/bin`; Windows user environment registry).
Coverage: `EditorCommandLineTests` and `EditorMenuBarTests`.
The CLI dispatches before app/UI startup and reuses project inspection,
AdaScript validation and native build/export services, with JSON diagnostics and
stable exit codes. CLI/SDK staging is excluded from iOS and App Store wrappers.
Windows inspect/validate run without external compilers; Web/Android export uses
the configured WSL worker. Native Windows game packaging is not a CLI target yet.
Host Swift/Xcode tools and Python 3 remain required for macOS builds; validation scope and current
export limitations are documented in [CLI.md](../../Documentation/CLI.md).

Runtime scene replacement decodes JSON scenes directly and prepares referenced
models, LODs and Spine skeletons asynchronously before main-actor installation.
Strong asset handles are retained through installation so synchronous component
instantiation reuses the cache. Nested scenes are included and cycles fail before
the active scene is replaced. SceneNavigator exposes monotonic progress and
stage/error queries to AdaScript; request generations isolate stale callbacks.
Windows pointer capture hides/confines/recenters the cursor, forwards relative
motion and releases on focus loss/teardown. Coverage:
`EditorRuntimeScenePreparationTests`, `EditorSceneLoadingProgressTests` and
Last Autumn's `LastAutumnPointerTests` integration suite.

Entry points: [EditorViewModel+Commands.swift](../../Sources/AdaEditor/UI/Editor/EditorViewModel+Commands.swift),
[EditorViewModel+AdaScriptHotReload.swift](../../Sources/AdaEditor/UI/Editor/EditorViewModel+AdaScriptHotReload.swift),
[EditorAdaScriptNativeExporter.swift](../../Sources/AdaEditor/Tooling/EditorAdaScriptNativeExporter.swift),
[EditorPlayerSession.swift](../../Sources/AdaEditor/Player/EditorPlayerSession.swift).
Coverage: [EditorAdaScriptHotReloadTests.swift](../../Tests/AdaEditorTests/EditorAdaScriptHotReloadTests.swift),
[EditorAdaScriptNativeExportTests.swift](../../Tests/AdaEditorTests/EditorAdaScriptNativeExportTests.swift),
[EditorPlayerProjectTests.swift](../../Tests/AdaEditorTests/EditorPlayerProjectTests.swift).

## Boundaries and incomplete paths

- The embedded AdaScript Web Player's scene validation currently allows only
  Transform, Visibility and TileMapComponent. This restriction belongs to that
  path, not every AOT/Swift Web export path.
- Agent simulation is logic verification; rendering, audio, network and touch
  interaction require visible Play. Build success is not gameplay verification.
