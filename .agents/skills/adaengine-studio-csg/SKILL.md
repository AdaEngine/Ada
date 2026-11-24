---
name: adaengine-studio-csg
description: Build, edit, or verify constructive solid geometry (CSG) levels in Ada Studio. Use for editable solid groups, Boolean cuts, operation ordering, viewport tools, UVs, or validating CSG mesh and collision in Play and native export. For imported meshes and terrain sculpting, use their own Studio workflows.
---

# Work with CSG in Ada Studio

Read [the Studio CSG guide](../../../Editor/Documentation/CSG.md) for the controls
available in the current checkout. Use the [Two Rooms fixture](../../../Editor/Tests/Fixtures/CSGTwoRooms/README.md)
to reproduce the doorway and collision. Copy the fixture to a writable test
directory before editing it. Open the copy as a Studio project.

## Author or edit a level

- Create a **CSG Group** from the scene hierarchy. Select the group or one of its
  operands to edit its ordered operations. Use the shared scene editor commands
  and history for creation, selection, transforms, and Undo/Redo.
- The first enabled operand supplies the base. Each subsequent enabled row
  applies Union, Difference, or Intersection to the result accumulated so far.
  For a through-cut, extend the cutter beyond both faces of the wall. If the cut
  extends below floor height, place the floor's Union after the Difference so
  the opening stays flush. Select the cutter to inspect its outline.
- Save and reopen the authored scene to check that shapes, transforms, and order
  survive. Let Play prepare the current revision. When the editor retains a
  last valid preview during a rebuild or error, that mesh can represent an
  earlier revision. A valid empty result clears it.
- For a textured result, check both unchanged surfaces and the walls of a cut
  with **Checkerboard**. Use a nonuniform transform and view the result from
  several angles to expose seams or mirrored charts. **UV Repeat** changes the
  whole group. Choose a PNG or JPEG from the project's primary assets folder
  under **Texture**. Cylinder sides and spheres wrap around their local Y axes.

## Change or verify the implementation

- Read the [approved design](../../../Documentation/Designs/studio-csg.md).
  Start in [EditorCSGScene.swift](../../../Editor/Sources/AdaEditor/EditorCSGScene.swift)
  for authored data and Play preparation and [CSGGroupSource.swift](../../../Sources/AdaScene/3D/CSGGroupSource.swift)
  for CPU evaluation. Keep editable operands in the scene document with stable
  IDs; preserve first-enabled and legacy serialization behavior.
- Keep evaluation cancellable and off the UI actor. Replace preview geometry
  only for the current revision and use the viewport world-access boundary.
  Keep the visual mesh and static collider derived from the same result. Test
  transformed ancestors and scene instances as well as top-level groups.
- Native conversion uses the staged scene snapshot for instance validation.
  Bake each definition once and ship portable mesh/collision data. Check the
  packaged player separately from scene conversion. A successful import of a
  generated GLB does not prove that a packaged player started.
- Run the Editor CSG Swift Testing suites and the offline documentation check
  in the [contribution workflow](../../knowledge/workflow.md). For UI work,
  verify first open, operation changes after a selection autosave, and the
  Inspector immediately after Stop in the native app. Report the platforms
  and runtime entry points actually exercised.
