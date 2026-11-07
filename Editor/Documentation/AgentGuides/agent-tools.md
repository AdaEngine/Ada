# Agent Tools, Verification and Generation

Read this reference only when the task touches this area. Return to [the editor guide](../../AGENTS.md) for routing and shared rules.

Paths in code spans and commands retain their original `Editor/` working-directory context unless explicitly repository-relative; Markdown links resolve from this file.

This inventory was originally recorded on **2026-10-04** and subsequently maintained. Implementation and test links identify existing coverage, not a validation run or platform acceptance.

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
`EditorScenarioComponentSnapshotTests`. Guide: [MobileAgentTools.md](../../Documentation/MobileAgentTools.md#desktop-game-verification).
Coverage: [EditorPlayScenarioTests.swift](../../Tests/AdaEditorTests/EditorPlayScenarioTests.swift),
engine [SceneViewFrameCaptureTests.swift](../../../Tests/AdaEngineTests/SceneViewFrameCaptureTests.swift).

The Windows AdaMCP staging patch adds world-scoped runtime schemas to
`entity.list_components`, `component.get` and `entity.find`, including stable IDs
and aliases. Native component reflection exposes live fields without a separate
MCP registration; unknown value types have bounded read-only reflection with
explicit partial-value markers. Explicit MCP serializers remain authoritative.
Coverage: `EditorMCPComponentInspectionTests` and `script/test_ensure_windows_mcp.py`.
This requires rebuilding Studio; already running processes retain their old tools.

Native AI model tools on desktop and mobile inspect/validate GLB/glTF through
CPU native import, import project-local dependency bundles and patch PBR material
factors. Offline docs/API/component/examples tools are shared; bundled workflow
skills are readable on demand through `editor.skills.list/read`. `basic-3d-scene`
is a complete camera/cube/light example. Import validation does not prove GPU
rendering, clip playback or gameplay. `editor.model.generate` supports explicit
procedural joints, rigid/two-joint weights and linear translation/rotation clips
in its interpreted AdaScript recipe. The builder ships precompiled; recipe
execution needs no Swift compiler or JIT. Windows VM/buffer checks are covered by
`AdaScriptModelRigTests`; physical iPad execution and a rebuilt Studio bundle
remain unverified. Blender execution, automatic organic mesh generation,
anatomy inference and visual imported-rig editing remain outside these tools.
Desktop scene changes use document revisions
and undo, and asset writes reject matching dirty open documents.

The bundled `ada-game-builder` workflow is advertised in desktop and mobile
session catalogs without per-project installation. Agents load it on demand for
game creation and iteration. It covers playable loops, persistent authoring,
controls/HUD, and build/simulation/visible Play verification using the host's
available tools; catalog discovery does not enforce model selection.

Scripted asset generation ([ADR-0026](../../../Documentation/ArchitectureDecisions/0026-scripted-asset-generation-and-autonomous-studio.md)):
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
([Assets/Examples/side-scroller-3d](../../Sources/AdaEditor/Assets/Examples/side-scroller-3d)) is a complete multi-file
3D flappy/runner game (files on disk; the project JSON and scene are generated by
[EditorAgentBundledExamples.swift](../../Sources/AdaEditor/Agent/EditorAgentBundledExamples.swift)) with `@query` systems,
input actions, a reused obstacle pool, collisions, score, restart, `AudioSource` cues, a `.ui` HUD, `@test` tests and
asset generator sources. Its production sources and tests are compiled and run, its scene is checked against the scripts,
and the `// recipe` blocks of [AdaScriptGameplayRecipes.md](../../Documentation/AdaScriptGameplayRecipes.md) (also in the offline
documentation) are executed. Regenerate the offline snapshot with `python3 scripts/update-offline-documentation.py`.
Entry points: [EditorAgentGeneratorToolService.swift](../../Sources/AdaEditor/Agent/EditorAgentGeneratorToolService.swift),
[EditorAudioSourceComponentDescriptor.swift](../../Sources/AdaEditor/EditorAudioSourceComponentDescriptor.swift).
Coverage: [EditorAgentExampleTests.swift](../../Tests/AdaEditorTests/EditorAgentExampleTests.swift),
[EditorAgentMediaGenerateTests.swift](../../Tests/AdaEditorTests/EditorAgentMediaGenerateTests.swift),
[EditorAgentModelGenerateTests.swift](../../Tests/AdaEditorTests/EditorAgentModelGenerateTests.swift),
[EditorAgentVoxelToolTests.swift](../../Tests/AdaEditorTests/EditorAgentVoxelToolTests.swift).

Guide: [Agent3DWorkflow.md](../../Documentation/Agent3DWorkflow.md).
Entry points: [EditorAgentModelToolService.swift](../../Sources/AdaEditor/Agent/EditorAgentModelToolService.swift),
[EditorAgentAuthoringMCPTools.swift](../../Sources/AdaEditor/Agent/EditorAgentAuthoringMCPTools.swift).
Coverage: [EditorAgentModelToolTests.swift](../../Tests/AdaEditorTests/EditorAgentModelToolTests.swift).

Guides: [AgentCatalog.md](../../Documentation/AgentCatalog.md),
[MobileAgentTools.md](../../Documentation/MobileAgentTools.md).
Entry points: [GitReviewService.swift](../../Sources/AdaEditor/Tooling/GitReviewService.swift),
[EditorAgentViewModel.swift](../../Sources/AdaEditor/Agent/EditorAgentViewModel.swift).
Coverage: [GitReviewTests.swift](../../Tests/AdaEditorTests/GitReviewTests.swift),
[EditorAgentCatalogTests.swift](../../Tests/AdaEditorTests/EditorAgentCatalogTests.swift),
[EditorMobileAgentToolTests.swift](../../Tests/AdaEditorTests/EditorMobileAgentToolTests.swift).


### 3D IK authoring

`.animmod` resources use the shared revisioned modifier draft and ordered two-bone/FABRIK
runtime. Model panel selection, Inspector settings and viewport handles use the same edit
commands as `editor.animation.modifier*` and API 2 Tool jobs. Save is explicit; saved resources
bind to compatible `Model3DSource` instances with separate current scene revisions and stable
marker IDs. Marker snapshots use current local transforms, including while paused/under LOD.
The actual `IKHelper` Tool example is in `Documentation/Examples/StudioTools/IKHelper`.
See [Animation authoring](../../Documentation/AnimationAuthoring.md#ik-modifiers).
Native 2D weighted/spline deformation and typed IK timeline bindings remain separate stages.
