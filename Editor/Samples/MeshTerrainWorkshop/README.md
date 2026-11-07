# Mesh Terrain Workshop

Open this directory as an Ada Studio project. It contains a ready-to-run terrain
with a joined rock, a shaped platform, a cave with different materials on its
floor and ceiling, and two populations made from small VOX models.

1. Open the terrain tools, choose **Joining**, and select **Join and move this
   tree** in the hierarchy. Select **Mesh Terrain** as the target and choose
   **Join selected mesh**. The trunk joins the ground; the canopy keeps its own
   material.
2. Drag the tree along the red X handle. Grass and stones move out of the new
   footprint and grow back where the tree used to be. Use Undo and Redo to
   restore both the tree and the ground.
3. Switch the viewport from **Shaded** to **Wireframe** or **Shaded + Wireframe**
   to see the triangles. Zoom out to inspect the coarser triangles where the
   terrain can simplify. Use the cave entrance on the left to inspect the painted
   floor and ceiling separately.
4. Save and reopen the project to keep the move. Copy the whole project if you
   want a clean copy for further edits; the joined terrain references the
   original model under Assets for its bark texture.
5. Press **Play** in the scene viewport to see the orange ball drop and stop on
   the joined rock. Stop Play to return to editing.

The example includes a manually placed rock, a pinned procedural stone, and a
suppressed grass candidate in the authored terrain file. Mesh Terrain compiles
them with the ground so runtime scenes load the same placement decisions.

Validate the project from the engine checkout:

```text
adastudio validate --project Editor/Samples/MeshTerrainWorkshop
```
