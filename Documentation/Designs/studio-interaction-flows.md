# Ada Studio interaction flows

Status **Proposed** · 2026-11-07

An agent can inspect a running Studio workbench, write a short YAML flow, replay it without desktop control, and get a pass or a reproducible failure. The first flow verifies that a user can move a scene entity with a viewport gizmo and undo the resulting document edit. A second flow exercises hierarchy reparenting with the same drag command.

## Existing building blocks

- The adjacent AdaMCP checkout provides `ui.get_tree`, `ui.hit_test`, and YAML/JSON execution through `automation.run` and `adamcp.run_file`. Its low-level input commands queue events. A successful queue operation gives the caller no evidence that Studio processed the input or that a gesture succeeded. Its selector-based tap dispatches directly to the resolved AdaUI container. The exact capabilities of the staged desktop dependency need verification.
- Studio already exposes AdaUI identifiers for hierarchy rows and viewport panels. Gizmo handles are drawn and hit-tested using viewport geometry. They need an inspection adapter that can describe an actionable point within the current viewport.
- `editor.play.run_scenario` targets the game running in Play or an offscreen game runtime. Studio interaction flows target the editor window and assert against the editor document. Both can use the existing conventions for bounded execution, captures, and structured diagnostics. [Game scenario runner](../../Editor/Sources/AdaEditor/Agent/EditorPlayScenarioRunner.swift)
- UI Designer tests already drive press, move, release, and cancel through the AdaUI container and verify document changes and undo. They are useful focused coverage for the behavior beneath a full workbench flow. [UI Designer drag tests](../../Editor/Tests/AdaEditorTests/EditorUIDesignerDragTests.swift)

## Execution model

Use AdaMCP as the entry point. Extend its existing flow format with a versioned, allowlisted Studio test profile, and expose the same runner to a local CLI for CI. Keep existing `automation.run` arrays compatible. Advertise the test profile and its command schemas only when the connected host supports them. Agents inspect before writing a flow, run inline YAML while debugging, and replay the saved file through the same runner.

Run flows in a separate Studio test executable composed from the real workbench, editor models, and rendering/input plugins. Give each run a temporary copy of a fixture project, isolated settings and caches, and a session-scoped local connection. Keep fixtures and harness lifecycle in the test executable. Start with a rendered macOS workbench on a host that can create a window and GPU surface. A developer can run it alongside their normal workspace. Windows is the next validation target. Linux, mobile, browser Studio, OS dialogs, and dragging files from Finder or Explorer require separate coverage.

AdaMCP owns parsing, sequencing, and reporting. Studio supplies workbench target discovery, dispatch acknowledgement, and read-only document probes. AdaUI owns normal hit-testing, routing, focus, and gesture capture. The profile takes an explicit session and window binding before the first step. It validates the complete flow before acting, serializes runs per session, bounds time and output, and accepts a small set of input, assertion, and capture commands. Project setup happens at launch. Assertions cannot invoke scene edits, ECS mutations, arbitrary scripts, or shell commands.

## Target resolution and input

- Resolve UI targets using stable accessibility IDs scoped to the bound window and, when necessary, the workbench pane. A missing, ambiguous, clipped, or covered target produces a diagnostic. Resolve canvas points relative to a named surface. Use logical window coordinates internally, applying each container's transform and the display scale only at the appropriate boundary.
- Expose named anchors such as `translate.x` through a read-only viewport inspection adapter. Wait for the presented geometry matching the current selection, camera, tool, and viewport. Choose a point in the handle's active region, convert it from rendered geometry into window coordinates, and include the geometry generation in the result. Re-resolve if layout changes before the gesture starts. Validate that the point reaches the viewport and that the production picker identifies the intended handle. An obstructed or unavailable handle fails with the reason and geometry. The pointer-down still runs normal picking. [Presented gizmo geometry](../../Editor/Sources/AdaEditor/UI/Editor/EditorSceneViewportGizmos.swift)
- Submit synthetic events to the same window-scoped input queue the platform uses. This preserves UI interception, hit-testing, pointer capture, and forwarding into the hosted scene viewport. A drag is a single flow step that sends down, ordered moves with the pressed button and correct deltas, and up. Preserve the path through the gesture threshold and onto the destination. Bare hover events can terminate existing mouse capture. Use monotonic timing and release or cancel any held input on error, cancellation, or timeout. [Window input routing](../../Sources/AdaUI/CoreUI/UIWindow+InputEvents.swift) · [Viewport drag handling](../../Editor/Sources/AdaEditor/UI/Editor/EditorSceneViewportModel.swift)
- Advance after the target window has dispatched the step's input and the relevant workbench or hosted viewport update has observed it. Captures await a rendered frame newer than the triggering action. Use deadline-bound predicate waits for loading and assertions. Continue driving the real frame loop during the wait. Report timeouts with the last observed frame and state.

## Example

The names and fields below illustrate the proposed Studio profile. The fixture opens a scene with a cube at the origin, an unrotated parent, and a camera facing the scene. It has stable entity IDs.

```yaml
version: 1
profile: studio-ui
steps:
  - tapOn: { id: AdaEditor.SceneHierarchy.Select.fixture-cube }
  - tapOn: { id: AdaEditor.SceneViewport.Control.Move }
  - drag:
      from:
        id: AdaEditor.SceneEditor.ViewportPanel
        anchor: translate.x
      by: { x: 100, y: 0 }
      durationMs: 350
  - assertScene:
      entity: fixture-cube
      localPosition:
        x: { greaterThan: 0.1 }
        y: { near: 0, tolerance: 0.001 }
        z: { near: 0, tolerance: 0.001 }
  - pressKey: { key: z, modifiers: [main] }
  - assertScene:
      entity: fixture-cube
      localPosition: { near: [0, 0, 0], tolerance: 0.001 }
```

The hierarchy flow uses the same `drag` step with `from.id` and `to.id` set to two row identifiers. It checks the resulting parent ID and undo. The source and destination describe input geometry. The existing hierarchy gesture determines whether the reparent is valid.

## Results and acceptance

- Return a structured outcome and a CLI exit status. On failure, include the step index, resolved targets, coordinates, last observed frame, expected and actual state, and a bounded event trace. Attach the test window's capture and a relevant UI subtree when available. Identify editor-window captures explicitly because the generic capture tool can prefer the running game's camera.
- Prove that the same saved flow passes through the MCP and CLI entry points on the rendered workbench. Verify that an intermediate move updates the preview while the document revision stays stable, release moves the cube only along X in the document, and one undo restores it. Use a fixture with prior history to distinguish one undo entry from several. Repeat at two window sizes and across English and Russian to exercise layout and selector stability.
- Test cancellation after an intermediate move, a covered start point, and a missing or ambiguous selector. Cancellation restores the initial document and leaves the next flow able to click and drag. Obstruction and bad selectors fail with distinct results. A deliberate wrong transform expectation produces a failing exit status and actionable evidence.
- Drag one hierarchy row onto another and verify its document parent and undo. Verify an invalid drop leaves the document intact. Use real input, a real fixture, and a real workbench for these checks.

## Alternatives and delivery

Direct authoring commands remain useful for arranging fixtures. They cannot validate hit-testing or gesture ownership. Raw screen coordinates work for fixed diagnostic replays and make durable tests dependent on window layout and scaling. An external Maestro driver would also need access to custom-rendered gizmo geometry. Reuse Maestro's inspect, replay, and assert workflow through Studio's own surfaces.

Ship a user guide in `Editor/Documentation/StudioInteractionFlows.md` and link it from the Studio README and agent catalog. Include a verified fixture flow, instructions for MCP and CLI, selector discovery, supported targets, and sample failure output. Add the guide to the Studio offline documentation and verify its navigation, the offline snapshot, and replay of the published example as part of implementation.
