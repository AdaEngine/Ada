# Animation Authoring Implementation Plan

Date: 2026-11-04.

Design: [Accepted animation authoring design](../Designs/animation-authoring.md).
Approval: explicit human approval in this Codex conversation on 2026-11-04.
Requested first delivery: skeletal animation editing and the shared API for agents and developer Tools.

Status: **M1 implementation and validation in progress.** Runtime libraries, the bone keyframe editor,
agent commands and developer Tool API 2 are implemented. Final editor regressions, native acceptance
and independent review remain in progress; required macOS evidence and SwiftLint are unavailable on
the current Windows host. M1 is not closed. Native temporal-curve work in M2 and the
3D modifier/IK foundation are in progress; other remaining stages are not delivered. The local approval record
attests to the conversation message, not identity.

## 1. Delivery Strategy

### Approved visual-workspace correction, 2026-11-05

The human approved design section 11 on 2026-11-05. Implement these behavior slices through the
existing shared document/preview owners, with focused production-path Red/Green/Refactor evidence:

1. Replace the existing Graph list with the shared node canvas: cards/ports/wires, selection,
   connection validation, grouped gestures/history and contextual property editing.
2. Add the resizable Model hierarchy and contextual animation Inspector. Share stable node/track/key
   selection with the viewport and timeline; preserve workspace/preview lifetime across panel changes.
3. Replace the selected-track strip with the common skeletal timeline: hierarchy/channel rows,
   ruler/playhead/transport, clip/duration/loop controls, grouped key insertion/selection/drags and
   atomic error/Undo handling through the shared service. Include imported read-only timelines.
4. Complete preview settings, project workspace persistence, keyboard/compact layouts and dense-data
   interaction checks. Keep semantic scene graph persistence distinct from asset preview/layout state.
5. Update Studio/Graph/DocC guides, navigation, real Tool example and EN/RU catalogs; run owning
   regressions, staged native acceptance and independent review of the final state.

Initial additional owned paths: `EditorAnimationGraphModel+Canvas.swift`,
`EditorAnimationTimelineModel.swift`, `EditorAnimationTimeline.swift`, `EditorAnimationModelPanel.swift`
and `EditorAnimationInspector.swift` under the existing Editor animation/UI owners, plus
`EditorContextualInspector.swift` and the nearest animation tests. Record exact paths before editing.
This brings basic visual/grouped-key editing into M1. Advanced M2 curves/playback and M3 orchestration
remain separate. Existing unavailable required checks still block full acceptance.

Deliver one usable skeletal authoring workflow first, through the same production service in Animator,
agent tools and a real project-local `.ada` Tool. Internal foundation work is not a standalone completed
first milestone. Ship documentation, examples, validation and independent review with each milestone.

| Milestone | User-visible result | Prerequisites |
| --- | --- | --- |
| M1. Skeletal authoring and shared API | Extract/create a clip, key a bone, edit through all three clients, save/reopen and use it in the existing graph and Play | Approved design; environment/tooling preparation |
| M2. Curves, properties and playback | Manual tangents, easing families, richer tracks, loop regions and complete repeat/stop behavior | M1 |
| M3. Graph orchestration | Parameters, transitions, blend spaces and live graph controls | M1 clip identity/bindings; M2 curves and clock/event contract |
| M4. Procedural pose foundation | Ordered modifiers work after mixing and LOD interpolation, with consistent final bones and skin palettes | M1 ownership/finalization constraints; regressions against M2/M3 |
| M5. Spatial paths in 2D/3D | Author curves and animate movement along them by distance/progress | M2 temporal tracks; M1 shared service |
| M6. Native 2D bones and deformation | Author bone/cutout animation and deform a weighted native 2D mesh | M1/M2 schema and bindings; native mesh/weight/render support |
| M7. Spline-driven 2D bone deformation | An editable spline drives a bone chain and the weighted mesh through the shared API | M4, M5 and M6 |

Both path following and 2D bone/spline deformation are confirmed requirements. Completing M5 does
not complete M6/M7. Actual IK solvers remain a subsequent scoped feature; M4/M7 must leave a usable
modifier boundary for them. Retargeting, automatic rig inference, direct FBX import, root-motion
extraction and a full weight-painting product remain separate follow-ups under the accepted design.

## 2. Preparation Before M1 Code

1. Recheck the worktree and the accepted design against current source. Preserve unrelated edits.
   Create an implementation task with exact file ownership, the approved design reference and this
   plan. Record the real approval source; do not fabricate another approval or reclassify the work.
2. Run `python ada_tool.py doctor --profile studio --json`. Prepare missing prerequisites using the
   unified CLI and existing Windows/macOS staging workflows. Provision Python 3.11+ with pinned
   `script/contribution-requirements.txt` tools before full validation. The planning host's default
   Python is 3.9.13; content-only runner support does not establish analyzer readiness.
3. Use task-owned engine/editor SwiftPM scratch directories and reuse them across checks. Preserve
   the shared `.build`. Follow the Windows Gravity-package override in the platform guide. Verify
   package dependencies before changing them, and keep Swift language mode 6.2.
4. Establish a real small skinned GLB fixture containing named bones, LINEAR/STEP/CUBICSPLINE TRS
   channels and morph channels, plus duplicate-name/reimport variants. Reuse existing fixtures when
   suitable; add fixture files to task scope explicitly. Record source checksums and sample tolerances.
5. Run the nearest existing suites before edits and retain results. Fix prerequisites rather than
   using a build failure as Red evidence. Start each behavior increment with a meaningful Swift
   Testing assertion, then production code, Green and Refactor through the contribution runner.

Use [the workflow commands](../../.agents/knowledge/workflow.md),
[platform guide](../../Editor/Documentation/AgentGuides/platforms.md) and
[validation reference](../../.agents/skills/adaengine-development/references/validation.md).

## 3. M1: Skeletal Animation Editing and Shared API

### First completed workflow

Open a skinned GLB, extract `Walk` into `Assets/Animations/Hero.animlib`, adjust a hand rotation key,
create `Wave` from rest or a captured pose, combine it with the imported walk using the existing
blend/additive graph and bone mask, and save/reopen the project. Repeat equivalent edits from an
agent and a developer Tool, then verify distinct instances in rendered Play.

### Work packages, in implementation order

**1.1. Define portable authoring data and contracts.** Introduce version-1 `.animlib` JSON resources
with library/clip/track/key IDs, display names, explicit duration, repeat metadata, typed local TRS
values, imported interpolation/tangents and provenance. Keep common DTOs/validators in `AdaAnimation`;
add the resource codec/dependency integration in `AdaAssets`. If that wrapper needs animation types,
add only the `AdaAssets -> AdaAnimation` dependency after confirming there is no inverse edge.
Keep editor objects and resource handles out of the portable schema.

Validate finite values, quaternion magnitude, key order/uniqueness, duration, supported versions and
target types. Return structured diagnostics with operation and target IDs. Define duplicate-time
replace-versus-reject explicitly. Add round-trip/rejection tests before editing clients consume data.

**1.2. Extract source clips and compile stable bindings.** Convert the native imported rig and channels
into editable data without rewriting the GLB. Preserve cubic derivatives, quaternion sampling and
morph channels exactly before edits. Store source asset/clip and rig fingerprints plus imported-node
mapping. Compile authored bone identities into hierarchy indices; palette offsets are not identities.
Diagnose changed/missing/ambiguous nodes and keep unresolved authoring data available for explicit remap.
Do not silently rebase authored keys after reimport.

Support new clips from rest/captured pose and track/key insert, update, move and delete. M1 exposes
step/linear authoring and preserves/editably round-trips imported cubic data; the full manual curve
editor arrives in M2. Cubic edits must retain valid derivatives and equivalent production sampling.
M1 keeps existing repeat/one-shot, speed, seek and crossfade behavior available.

**1.3. Integrate resource playback, current graphs and export.** Resolve imported and authored clips
through qualified stable references. Extend legacy graph/scene encoding additively, with optional
library/clip references and library dependencies on the model owner; retain old name-based clip fields,
embedded graphs and six-channel scene timelines. Validate before installing a compiled draft. An
invalid change keeps the last valid preview/runtime graph.

Load `.animlib` through the real asset pipeline, include referenced libraries in project export, and
exercise interpreted/AOT scene-loading paths where supported. Preserve current graph-time-derived
clip phases, masks, additive order and marker behavior. Imported source bytes and unrelated channels
must survive extraction and edits. Consider the later modifier finalization boundary now; keep pose
writes centralized instead of introducing a second bone writer.

**1.4. Add one editor document service.** Implement revisioned snapshots and typed command batches,
validation, compilation and local/global pose sampling against the production evaluator. Add a proper
animation-resource document with normal dirty state, Save/reopen and Undo/Redo. A bulk change or drag
is one history transaction. Validate the complete batch before commit; return operation-specific
errors without partially applying it.

Use explicit resource revisions, project-path confinement and dirty-open-file checks. Keep the scene
binding step separate from asset save unless coordinated cross-document history is implemented and
tested. Sampling and previews are transient, do not dispatch gameplay callbacks, and restore the edit
pose on close/cancel. Invalid drafts preserve the last valid preview.

**1.5. Expose the service to agents and API discovery.** Register proposed `editor.animation.inspect`,
`.apply`, `.sample`, `.validate` and `.preview` tools using the existing host/MCP registration paths.
Include extract/create/duplicate clips and track/key/loop/binding operations in the typed command
catalog. Return revisions, IDs, diagnostic codes and discoverable limits; paginate large data.
The final advertised schema must match the implementation, including save and binding boundaries.

Update both agent-facing tool descriptions and AdaScript API tooling where applicable. Do not expose
unimplemented M2-M7 commands as available, or use procedural model generation as an editing fallback.

**1.6. Expose the same contract to developer Tools, including Windows.** Extend the schema/parser,
scoped VM bridge and host for an API version supporting animation resources. Preserve API 1 behavior.
Expose a proposed `editor.animations` facade with detached data and the same service diagnostics.
Add explicit resource-read/write and preview capabilities/grants; document-write permission alone
must not acquire asset write access. Test changed permissions and revocation.

Extend platform declarations and the current macOS-only activation path for Windows. Exercise the
real shared panel, project settings and permission UI there. Keep synchronous bounded callbacks;
submit expensive work as host-owned jobs with pollable results and generation-scoped cancellation.
No async callback redesign or relaxed VM budgets is required for this delivery. Closing/reloading or
revoking a Tool invalidates queued edits, jobs and preview ownership.

**1.7. Connect Animator to the service.** Add library/clip selection, **Extract Editable Copy**, new
clip creation, bone/channel selection, local TRS key insertion and a usable timeline with key value/time
editing and scrubbing. Reuse the skeleton overlay and real model preview. Make source/read-only state,
binding errors, dirty state and explicit capture/auto-key visible. Keep the existing graph editor
usable with both source and authored clips. Ship English/Russian strings together.

User-directed layout correction (2026-11-04): place all clip, bone/keyframe and Graph controls in
the bottom Animator. Route active GLB/glTF and `.animlib` assets before scene selection, including
projects with no scene open. Keep one document-owned preview/camera shared with the large center
viewport; mode switches and panel mounting do not own its loading/cancellation. Verify the empty-scene
asset target, shared document/history, resource switching and the real native bottom-panel interaction.

**1.8. Ship examples, documentation and acceptance evidence.** Add a complete Animation Helper
`.ada`/`.ui` Tool example and a compilable Swift usage example. Both edit a known compatible bone,
sample results and demonstrate save/bind behavior. Update the bundled animation skill's stale morph
restriction and document actual capabilities/platforms. Run the documentation delivery in section 11.

### M1 exit criteria

- Animator, agent and a real Tool callback apply equivalent edits through one service and produce
  equivalent serialized data and sampled poses; all three support create/extract/edit/save workflows.
- An untouched extracted clip matches production import sampling at keys and between keys, including
  cubic rotations and morph weights. The source GLB checksum is unchanged after editing and saving.
- Resource and scene save/reopen, Undo/Redo, compatible duplication and export retain the authored
  animation. Old scene/keyframe/graph fixtures continue to load and sample compatibly.
- Stale revisions, invalid keys, unknown versions, dirty-file conflicts, incompatible rigs, duplicate
  bone names, revoked permissions and retired generations fail explicitly without partial writes.
- A full staged Windows Studio and macOS Studio exercise the Tool panel and visible skeletal preview/
  Play path. Completed frames at chosen times show the changed hand and independent model instances.
- User guides, discovery metadata and executable examples match the shipped API. Full applicable
  checks and independent implementation review pass; unavailable required evidence blocks M1 completion.

## 4. M2: Curves, Track Types and Playback

Implement in small behavior slices:

1. Separate temporal easing from interpolation in the portable schema/compiler. Add named polynomial,
   sine, exponential, circular, back, elastic and bounce families with in/out/in-out and parameters.
   Preserve legacy linear/hold/cubicInOut and imported cubic behavior during migration.
2. Implement Hermite derivatives and scalar temporal Bezier handles, monotone time inversion and
   free/broken/aligned/mirrored/auto/linear/flat editing modes. Preserve handles in save/Undo/API edits.
3. Add the curve editor and bulk-key operations: multi-select, copy/paste, retime/trim, snapping and
   mute/solo. Extend agent/Tool operations and discovery with the same typed data as they become usable.
4. Extend registered bindings to entity rotation and scalar/vector/color/morph properties. Diagnose
   competing writers and incompatible mixing domains. Keep 3D rotation quaternion-safe; Euler editing
   specifies units/order, and 2D angle bindings distinguish shortest-path and continuous turns.
5. Add loop regions, ping-pong, finite repetition, explicit stop policies and consistent seek/reverse
   behavior. Preserve legacy clock behavior through adapters; keep markers bounded and scrub silent.

**Exit evidence:** round-trip every mode, compare evaluator output at boundaries and representative
times, test overshoot/invalid handles/quaternions, zero/one-key clips, reverse/multi-loop/ping-pong marker
crossings and explicit trim/retime rollback. Dragging a tangent changes rendered motion and undoes in
one step. Equivalent UI/agent/Tool edits produce equal results. Update the guide with runnable curve
and loop examples; rerun M1 compatibility and parity checks affected by the schema/playback changes.

## 5. M3: Animation Graph Orchestration

1. Add per-instance typed parameters, one-shot triggers and defaults. Retain legacy graph-time-derived
   phases; define explicit state-activation clock and opt-in phase-sync behavior for new graph nodes.
2. Add state-machine states/transitions, conditions, exit times, priorities, crossfade curves and
   interruption rules. Specify deterministic tie-breaking, trigger consumption and transition budgets.
   State transition cycles are allowed; cyclic pose dependencies still fail validation.
3. Add BlendSpace1D/2D with defined sample geometry, duplicate/degenerate cases and out-of-range policy.
   Add one-shot/time-control nodes without changing existing mask/additive/rest-fill behavior.
4. Extend shared graph commands, agent/Tool discovery and the editor graph canvas with parameter,
   active-state and live-weight inspection; retain a usable list-based editing path.

**Exit evidence:** locomotion driven by speed/direction plus an upper-body one-shot; deterministic
transition/interrupt/trigger tests; independent instances, silent seek and bounded marker delivery;
graph save/reopen and bad-draft rollback from each client. Ship a documented runnable graph example.

## 6. M4: Procedural Pose Foundation for IK

1. Introduce the finalization boundary anticipated in M1: sampled/mixed base pose, visual LOD
   interpolation, ordered modifiers, final hierarchy rebuild, then node/palette publication.
2. Separate immutable rest, evaluated base and modified buffers. Define stable modifier order,
   enabled/influence/mask behavior, local/model/world space conversions and generation invalidation.
   Apply influence once; never reuse the last corrected pose as the next base pose.
3. Resolve world targets from a current owner-transform snapshot; handle singular transforms and
   paused clips. Stateful modifiers remain separately scoped with explicit cadence/reset semantics.
4. Implement a small stateless custom offset/look-at modifier to prove the API and expose its
   configuration through the shared authoring clients. Preserve animation clocks/events under LOD.

**Exit evidence:** a moving target affects a paused or LOD-interpolated character without accumulation,
double application or mismatched globals/palettes. Exercise seek, disable/reset, hierarchy changes and
duplicated instances. Compare rendered deformation and numerical poses across the finalization path.
Document modifier ordering/spaces/limits. This milestone does not claim a shipped two-bone/CCD/FABRIK solver.

## 7. M5: Spatial Splines and Path Following in 2D/3D

1. Add reusable cubic Bezier curve resources with stable point IDs, handles and open/closed state.
   Put reusable math in `Math`, resource support in `AdaAssets`, and scene followers in `AdaScene`.
2. Implement position/tangent sampling, approximate arc length and revisioned bounded-error baked
   caches. Support distance/progress tracks, reverse/loop/ping-pong and optional tangent orientation.
3. Define stable 3D frames/up-vector policy, closed seams and degenerate/zero-length behavior.
   Compile/cache edits outside steady-state frame evaluation.
4. Add viewport curve editing and equivalent inspect/edit/sample commands for agents and Tools.

**Exit evidence:** 2D and 3D scenes move objects along the same edited path at the intended distance
rate, with stated tolerance; verify seams, orientation, nesting, reverse playback and save/reopen.
Test cache invalidation and shared API parity. Ship path examples and a guide update. Spatial-path
completion is recorded separately from the required native 2D deformation milestones.

## 8. M6: Native 2D Bones and Weighted Deformation

1. Add explicit native 2D hierarchy/rest-pose resources, local translation/angle/scale tracks and
   scene bindings using the common library and graph conventions. Preserve optional Spine playback.
2. Provide minimal authoring of mesh vertices, triangles, UVs and normalized bone weights through
   explicit editor/shared-service operations. Validate hierarchy, indices, influences and rest state.
   This enables real deformation without committing to a full weight-painting product.
3. Implement native 2D mesh deformation/render integration and bounds, preserving 2D material/layer
   semantics. Verify the owning renderer paths before selecting CPU/GPU details; a material departure
   from the accepted ownership/scope returns to the human rather than being silently implemented.
4. Add bone/cutout/mesh editing workflows and the same creation/binding/key/weight operations to
   agent and Tool clients. Keep proprietary/exported Spine source editing outside the native API.

**Exit evidence:** animate a real weighted native 2D mesh, verify rest/posed vertices and rendered
frames, test bad weights/topology and independent instances, and round-trip rig/mesh/library bindings.
Exercise the three clients and ship a native 2D example plus documentation of supported materials,
bounds and weight limits. Relevant rendering/backend validation is required.

## 9. M7: Spline-Driven Native 2D Bone Deformation

1. Add a procedural bone-chain modifier consuming M5 curves and M6 rigs. Specify chain order,
   bone-length preservation, orientation, explicit stretch policy and local-space conversions.
2. Make curve/progress/influence animatable through ordinary tracks. Author the modifier and its
   bindings from Animator, agent commands and a project Tool using M4's finalization path.
3. Handle short/closed/degenerate curves, invalid chains and curve edits without cumulative drift;
   preserve last valid preview and revisioned resources.

**Exit evidence:** edit a curve and visibly bend a weighted 2D tail/rope-like mesh along it; test key
animation, loops, reverse, influence, save/reopen, Undo/Redo, invalid-edit rollback and all-client parity.
Compare chain poses with final deformed vertices and GPU frames. Publish the complete spline-deformation
example and guide. This completes the confirmed second interpretation of 2D spline support.

## 10. Implementation File Map and Ownership

Current planning edits are limited to the accepted design's status/approval metadata and this plan.
Future documentation paths are declared to the runner for the plan gate; they are not created now.
The following is the initial implementation inventory. Add exact paths to each implementation task
before editing; inspect current owners first and expand scope when additional files are necessary.
New filenames listed here are planned, not existing APIs or completed files.

| Area | Existing integration points | Initial new paths / later owner |
| --- | --- | --- |
| M1 data/compiler | `Sources/AdaAnimation/Skeletal/SkeletalAnimation.swift`, `SkeletalAnimationPlayer.swift`, `AnimationGraph.swift`, `CompiledAnimationGraph.swift` in that directory | `Sources/AdaAnimation/Authoring/AnimationLibrary.swift`, `AnimationAuthoringCommands.swift`, `AnimationLibraryCompiler.swift`, `AnimationBinding.swift` |
| M1 resources | `Package.swift`, `Sources/AdaAssets/GLTF/NativeGLTFLoader+Animations.swift` | `Sources/AdaAssets/AnimationLibraryResource.swift` |
| M1 scene/export | `Sources/AdaScene/3D/ModelAsset3D+Animation.swift`, `Model3DSource.swift`, `SkeletalAnimation3D.swift` in that directory; `Editor/Sources/AdaEditor/EditorSceneFileLoader.swift`, `Editor/Sources/AdaEditor/Tooling/EditorAdaScriptNativeExporter.swift` | Additive library/binding resolution; scope other export dependency collectors after tracing callers |
| M1 service/history | `Editor/Sources/AdaEditor/UI/Editor/EditorDocumentHistory.swift`, `EditorWorkbenchViewModel+Documents.swift` in that directory | `Editor/Sources/AdaEditor/Animation/EditorAnimationAuthoringService.swift`, `EditorAnimationLibraryDocument.swift`, `EditorAnimationPreviewSession.swift` |
| M1 agent | `Editor/Sources/AdaEditor/Agent/EditorAgentAssetTools.swift`, `EditorAgentMCPTools.swift`, `EditorAgentAuthoringMCPTools.swift` in that directory | `Editor/Sources/AdaEditor/Agent/EditorAgentAnimationTools.swift` |
| M1 Tools | `Sources/AdaScripting/AdaScriptToolRuntime.swift`; `Sources/AdaScriptCompilerCore/AdaScriptSchemaModels.swift`, `AdaScriptToolSchemaParser.swift`, `AdaScriptAPICatalog.swift` in that directory; `Editor/Sources/AdaEditor/StudioTools/EditorStudioToolHost.swift`, `EditorViewModel+StudioTools.swift` in that directory | `Sources/AdaScripting/AdaScriptAnimationToolBridge.swift`; scope panel/settings/permission UI and tests explicitly when extending them |
| M1 Animator | `Editor/Sources/AdaEditor/EditorKeyframeAnimation.swift`, `EditorAnimationGraphModel.swift` in that directory; `Editor/Sources/AdaEditor/UI/Editor/EditorAnimationPanel.swift`, `EditorSkeletalAnimatorPanel.swift`, `EditorSkeleton3DOverlay.swift`, `EditorModelAssetPreview.swift` in that directory | Bone/library timeline UI files under the owning shared editor directories |
| Localization | `Editor/Sources/AdaEditor/Assets/Localization/en.json`, `ru.json` in that directory | English/Russian strings in the same behavior change |
| M2-M7 | `Sources/AdaAnimation/KeyframePrimitives.swift`, `KeyframeSampler.swift`; `Sources/AdaScene/3D/AnimationLOD3D.swift`; owning `Math`, `AdaAssets`, `AdaScene`, `AdaRender`/`AdaSprite` modules | Declare exact curve, graph, modifier, native-2D and renderer paths at each milestone start |

Initial new test files: `Tests/AdaAnimationTests/AnimationLibraryTests.swift`,
`Tests/AdaAssetsTests/AnimationLibraryResourceTests.swift`,
`Tests/AdaSceneTests/AuthoredSkeletalAnimationTests.swift`,
`Tests/AdaScriptingTests/AdaScriptAnimationToolTests.swift`,
`Editor/Tests/AdaEditorTests/EditorAnimationAuthoringTests.swift`, and
`Editor/Tests/AdaEditorTests/EditorAgentAnimationTests.swift`.
Extend `EditorStudioToolsTests.swift`, existing skeletal/import/graph/keyframe tests and applicable
compiler schema/catalog tests rather than replacing their coverage.

## 11. Documentation, Validation and Review Gates

### User documentation in every milestone

- Author `Sources/AdaEngine/AdaEngine.docc/Articles/Developers/AnimationAuthoring.md`, linked in
  `Sources/AdaEngine/AdaEngine.docc/AdaEngine.md`, with a production Swift example and current limits.
- Author `Editor/Documentation/AnimationAuthoring.md`, linked from `Documentation/AnimationGraphs.md`
  and `Editor/Documentation/StudioTools.md`. Expand it as curves, graphs, paths, 2D and modifiers ship.
- Add `Editor/Documentation/Examples/StudioTools/AnimationHelper/AnimationHelper.ada` and
  `AnimationHelper.ui` in that directory. Execute the example through the real Tool host on each
  supported desktop platform; document the fixture/model it expects.
- Update `Editor/Documentation/Agent3DWorkflow.md`, bundled
  `Editor/Sources/AdaEditor/Assets/AgentSkills/ada-3d-animation/SKILL.md` and owning subsystem references.
- Add the guide to `Editor/scripts/update-offline-documentation.py` inputs, regenerate
  `Editor/Sources/AdaEditor/Assets/Documentation/catalog.json`, and run the generator with `--check`.
  Build DocC using the root AGENTS command and compile/run usage examples separately.

Register article/navigation paths with the runner before code. A design/plan, generated docs or
placeholder guide is not a substitute for the shipped user article. Stage-specific examples must use
actually implemented APIs and label platform limitations explicitly.

### Validation commands and evidence

Use focused symbol/suite filters first; confirm that each selects and executes relevant tests.
The following are commands for implementation, not test results from this planning change:

```text
swift test --scratch-path .build-tools/animation-authoring/engine --filter AnimationLibraryTests
swift test --scratch-path .build-tools/animation-authoring/engine --filter GLTFSkeletalImportTests
swift test --scratch-path .build-tools/animation-authoring/engine --filter AnimationGraphTests
swift test --package-path Editor --scratch-path .build-tools/animation-authoring/editor --filter EditorAnimationAuthoringTests
swift test --package-path Editor --scratch-path .build-tools/animation-authoring/editor --filter EditorAgentAnimationTests
swift test --package-path Editor --scratch-path .build-tools/animation-authoring/editor --filter EditorStudioToolsTests
python Editor/scripts/update-offline-documentation.py --check
```

Resolve scratch arguments to one task-owned absolute directory per package before invoking commands
on each host. Windows runs additionally require the documented Gravity package override. After focused
Green/Refactor, run owning/downstream targets and full engine/editor checks selected by the contribution
runner. Rendering changes require actual supported-backend golden-frame checks, including
`script/validate_webgpu.sh` with its pinned tools where applicable. GPU suites stay serialized under
`Render3DGPUTests`; disabled gates or empty suites are not passing evidence.

Build/stage Studio with `python ada_tool.py build studio` and the platform's existing distribution
workflow; visible acceptance must use a complete distribution. Verify Windows/macOS independently.
Use a real temporary project for edit/Undo/save/reimport/export/Tool tests and capture completed
animation frames at controlled times. The logic-only offscreen scenario does not prove skeletal Play.

Record realistic CPU/allocation/memory/edit-latency baselines before setting performance budgets.
Exercise dense imported tracks and repeated edits; prove no binding compilation or curve-cache
rebuild in unchanged steady-state evaluation. Follow the repository benchmark path when asserting
3D rendering performance; visual impressions are not performance measurements.

For every implementation milestone:

1. Capture exact ownership, approved design and article declarations in the runner; retain initial
   unrelated work. Run/verify the plan gate before code.
2. Record meaningful Red -> Green -> Refactor cycles and exact commands/logs; do not weaken checks,
   suppress findings or replace behavioral failures with missing-tool failures.
3. Run the complete applicable review profile, runtime/platform checks, example/DocC/offline checks
   and `git diff --check`. Missing required environments/results remain explicit blockers.
4. Obtain a separate-context `adaengine-review`, including shipped guides, navigation and examples.
   Fix findings and repeat affected checks/review; substantive design deviations return to the human.
5. Record the final review and `verify --stage done`. Report implemented behavior, successful evidence
   and remaining limitations. Pending CI does not count as passed or establish branch protection.

### Implementation status

M1 is in progress on `codex/animation-authoring`: portable libraries/commands/compiler,
resource loading, scene bindings, shared Studio drafts/history, skeletal-key UI, agent actions
and API 2 Tool jobs have been implemented. Focused core and real-VM tests have recorded genuine
Red/Green/Refactor cycles. Full integration, Editor transaction/preview/Play and required platform
evidence remain under validation; this status does not close M1. Native macOS acceptance is not
available from the current Windows host. M2 now has easing families, temporal Bézier
validation/sampling, schema-2 persistence, and Inspector fields in implementation.
The separately accepted IK plan records the implemented 3D modifier slice. These
changes do not close M2, M4 or the remaining native 2D/spline deliveries.
