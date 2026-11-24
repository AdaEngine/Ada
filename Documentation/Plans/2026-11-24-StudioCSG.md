# Ada Studio CSG Minimum Release

Design approved in the Codex conversation on 2026-11-24. See the
[approved design](../Designs/studio-csg.md) and [desktop interface proposal](../Designs/studio-csg-mockup.png).
Implement in the dedicated `codex/studio-csg` worktree.

## Delivery sequence

| Step | Production work | Evidence required |
| --- | --- | --- |
| 1. Ordered box evaluation | In AdaScene, define versioned authored group and operand data and a renderer-independent evaluator using `TriangleSurface.box`, transforms and the existing cancellable `TriangleMeshBoolean` API. Share the state and evaluation contract between preview and build. Keep the native authoring capability check at the integration boundary. | Swift Testing fixtures for union, a through-cut, intersection, order dependence, empty output, a later union after an empty result, reflected/nonuniform transforms, invalid dimensions and work limits. Compare volume or spatial samples and check generated topology. |
| 2. Scene document and history | Wire group creation, child box creation/deletion, operation changes, and reordering through the Editor scene mutation/history path. Use stable child entity IDs and the standard local transform fields. Persist a single explicit evaluation order. The first row is Base and retains its stored operation for later use. Keep box-only editor metadata out of shipping scenes. | Real temporary `.ascn` save/reopen tests, Undo/Redo for creation, deletion, reorder, and transform, grouping and duplication with remapped IDs, and a compatibility round trip for an existing scene. |
| 3. Preview and controls | Reuse the hierarchy Add flow, Inspector sections, themed dropdown, number fields, and viewport Move/Rotate/Scale controls. Add placement snap to the existing 3D controls. Select the same operand from the hierarchy and ordered Inspector rows. Render its outline and existing transform gizmo over the evaluated surface. Store one history entry per completed drag and restore the starting edit on cancel. | Native event-path tests for picking, operation selection, order boundary buttons, placement snap, cancel, focus, and one-step Undo. In the mounted desktop viewport, verify default selection, Add/dropdown, disabled, pending, error and empty states, English/Russian, narrow panels, and increased scale. |
| 4. Play and export | Use one preparation path for the current revision. Convert its surface to a renderable mesh and a static triangle collider. Account for inherited transforms and bake scale into collision where required by `Physics3DSystem`. Integrate with Editor Play and stage portable resources during the existing native scene conversion. Validate GLB plus `Model3DSource` and an ordinary serialized static body first. Preserve the previous export until staging succeeds. | Use the actual Play and native exporter entry points on a two-room project. A character walks through the opening and collides with the wall. Repeat under a rotated, nonuniformly scaled parent. Start the exported native player without the authoring trait and verify assets, collision, and the exclusion of authoring entities. |
| 5. Guide and integrated review | Publish the two-room example, document platform scope, and run contribution validation and independent review on the integrated change. | Verified guide instructions, offline catalog check, native screenshots, smoke and export logs, and a review verdict tied to the final diff. |

Before expanding the authoring UI, prove the portable mesh and collision option
with a small real generated fixture. Review the authored data and runtime paths
at that point while the scene schema has few callers.

## Integration and failure behavior

- Scope authored data to the group and evaluate in group-local coordinates. Use the
  same validated surface to prepare both render and collision products. Account
  for hierarchy pose changes in publication and for nonuniform parent scale in
  transform and collision tests.
- Schedule bounded CPU evaluation off the UI actor. Coalesce drag updates, cancel
  work when superseded or closed, and check document, group and revision identity
  again on publication. Keep the last valid preview during pending/invalid edits.
  When the current revision validly evaluates to empty, remove its mesh and
  collider. Play and export await current preparation and surface an actionable
  error for invalid geometry.
- Follow the existing
  [scene editor paths](../../Editor/Documentation/AgentGuides/scenes.md) and
  [native build and Play paths](../../Editor/Documentation/AgentGuides/build-play.md).
  The current native exporter converts scene documents via
  `EditorAdaScriptNativeExporter.convertScenes` and handles authored ordinary
  `Mesh3D` as a built-in primitive. Exercise the macOS AdaScript native export
  as the existing desktop export destination. Also exercise desktop local Play
  on supported authoring hosts through their normal launch paths.
- Document the operator order in the Inspector. Use the same operand identity
  for selection, transform editing and row movement. Keep the error text near the
  result and field errors at the field. Verify keyboard operation, selection
  visibility and the outline through a cut.

## Documentation and validation

- Author `Editor/Documentation/CSG.md` and link it from
  [the Studio guide](../../Editor/Documentation/EditorGuide.md). Add it to the
  [offline guide input list](../../Editor/scripts/update-offline-documentation.py).
  Run the generator and its `--check` command. Follow the guide with the real
  two-room project and keep the result reproducible as an integration fixture.
- Add exact task paths to the contribution runner as work lands. Use focused
  Red, Green and Refactor cycles with Swift Testing and task-local SwiftPM scratch
  paths. Run the engine geometry/scene and Editor suites, then the applicable
  contribution checks. Include kernel-enabled authoring and kernel-disabled
  native-player builds in the evidence.
- On Windows, use the staged Studio launcher and the pinned Swift/MSVC toolchain.
  Obtain real desktop rendering and input evidence for macOS and Linux through
  their existing Studio launch paths. Record coverage by host and state. Run
  applicable shared-runtime compatibility checks and the native export smoke.
  Report unavailable evidence as blocked.
- Run `python script/check_contribution.py run --task studio-csg --stage review`.
  Give the independent reviewer the approved design, this plan, exact diff,
  screenshots, native Play/export logs, and documentation evidence. Address
  findings, rerun affected checks, and finish with
  `python script/check_contribution.py verify --task studio-csg --stage done`.

## Interface proposal

[Rendered desktop proposal](../Designs/studio-csg-mockup.png) ·
[Rendered creation and result states](../Designs/studio-csg-mockup-states.png) ·
[Preview source](../Examples/studio-csg-mockup.html)

The preview uses Studio's dark theme, Open Sans and Material Symbols.
It places CSG group creation under the hierarchy Add action and keeps the
ordered operations and the selected shape's fields in the Inspector.
The central view illustrates a through-cut in a wall with the cutting box selected.
The source also supports English via `?lang=en` and the state board via
`?view=states`. This proposal illustrates the UI before native implementation.

Preview evidence on Windows Chromium covers the Russian desktop view and six
state examples, an English 800-pixel layout with a scrollable Inspector, menu
dismissal and focus return, selection, operation changes, reordering, and box
insertion. The viewport geometry is an illustration. Native Studio interaction,
mesh generation, Play and export are validation work for the implementation.
