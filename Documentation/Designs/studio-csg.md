# CSG Level Building in Ada Studio

Status — Proposed design for approval.

Date — 2026-11-24.

## Goal

Build playable 3D level geometry directly in the scene editor. A level designer
can construct two rooms from solid shapes, cut a doorway between them, and
adjust the opening later by editing its source shape.

## Scope

| Capability | Minimum release | Full scope |
| --- | --- | --- |
| Solid shapes | Box, created as a cube and sized independently on each axis. | Box, sphere, and cylinder. |
| Boolean operations | Union adds volume, Difference removes volume, and Intersection keeps the shared volume. Each group evaluates its shapes in a visible, editable order. | All three operations accept any combination of the three supported shapes. |
| Undo and Redo | Use scene history for shape creation, deletion, operation changes, reordering, and transforms. A drag is one history entry. | The same history applies to all shape types and UV edits. |
| Surface appearance and UVs | One preview material per group. Geometry and collision can ship as a playable level. | Automatic UVs for all shapes and for surfaces created by cuts. Textured results survive further edits, save/reopen, and native export. |
| Placement | Move, rotate, and scale shapes with the 3D gizmos. Support grid snapping for placement. | The same controls apply to all three shapes. |
| CSG tools | Create a group and add shapes from the scene editor, select an operand from the scene tree, see its outline in the viewport, and set or reorder its operation in the Inspector. | Extend these tools to all shapes and expose the UV workflow in the Inspector. |
| Scene and shipping | Save the editable group in `.ascn`. Use the generated mesh with matching static collision in Play and native export. | Preserve the same workflow for textured groups and all shape types. |

The authoring target is native desktop Studio. The minimum release is a complete
box-based workflow from authoring through a playable native export. The full
scope completes the shape library and textured workflow on top of that path.
The UV proposal is automatic mapping for level textures. Use a checker texture
to verify primitive surfaces, UV seams, and the inside of a cut doorway.

## Minimum release behavior

1. Create a CSG group with a starting box. Adding another box inserts a new
   shape in the ordered group. A shape has a stable identity, a local transform,
   dimensions, and an operation. The first shape establishes the starting solid
   and is labeled Base. If reordered, the new first shape becomes the base and
   the former base resumes its stored operation. Union is the default operation.
2. Editing or selecting a shape uses the existing scene hierarchy, Inspector,
   and transform gizmos. Display the resulting solid and the selected shape's
   outline together so a subtracting shape remains easy to find and adjust.
3. Save shapes, transforms, and their order as authored scene data. Undo and Redo
   restore this data and refresh its generated result. Reopening the scene
   restores the editable group.
4. Evaluate geometry off the UI actor. Publish only the current revision and
   keep the last valid preview visible while rebuilding. A successful empty result
   clears both mesh and collision. Show a diagnostic on failure. Play and export
   require a valid result for the current revision and report an invalid group
   before starting a run or producing a build.
5. Generate the render mesh and static triangle collider from the same surface
   and revision. Account for the group's inherited transform in both products.
   A native player loads the generated data through its normal scene and asset
   path. Boolean evaluation belongs to the desktop authoring and build path.

## Implementation boundaries

- Use [AdaGeometry's triangle Boolean API](../../Sources/AdaGeometry/TriangleSurface.swift)
  for closed solids. Follow the existing cancellation and resource-budget model.
  The [Manifold adapter](../../Sources/CManifold/README.md) is available through
  the native desktop authoring trait. Build the CSG group model in the scene and
  editor layers. Terrain and scene CSG use the same lower-level geometry API.
- Use the existing scene document and history for authored state. Treat preview
  and export geometry as derived data. Investigate the existing portable model
  asset path as the first option for generated mesh export. The current native
  exporter interprets ordinary authored `Mesh3D` payloads as built-in primitives.
- Present a rendered interaction proposal covering creation, shape selection,
  operation ordering, rebuild state, and errors before production UI work.
  Use Studio controls and verify the actual desktop UI in English and Russian.

## Acceptance

- In the minimum release, build a two-room level with boxes, union floor and wall
  geometry, cut a doorway, and verify intersection on overlapping boxes. Move and
  rotate the cutting box, then resize it. Check that operation reordering changes
  a fixture with an order-dependent result.
- Undo and redo the edits, save and reopen the scene, and reproduce the same
  result from editable shapes. Check rapid edits, successful empty results, and
  failed rebuilds against the same scene path.
- Use a player character to walk through the opening and collide with the wall
  in both Play and a native export. Repeat with a transformed parent group so
  the displayed opening and physics stay aligned. Verify that the native player
  loads the result in a build with the authoring kernel disabled.
- For full scope, exercise all Boolean operations with mixed shapes. Verify
  checker texture scale and orientation on the box, sphere, and cylinder and
  on cut surfaces, including after transforms, regeneration, and native export.

## User documentation

Publish `Editor/Documentation/CSG.md` for level designers. Link it from
[the Studio guide](../../Editor/Documentation/EditorGuide.md), add it to the
[offline guide inputs](../../Editor/scripts/update-offline-documentation.py),
and regenerate and check the offline catalog. Use the verified two-room example
to teach creation, cutting, Undo/Redo, saving, Play, and export. Update the same
guide as the new shapes and UV workflow ship.
