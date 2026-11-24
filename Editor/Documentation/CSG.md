# Build a level with CSG

Constructive solid geometry (CSG) lets you build walls, floors and openings
from editable boxes, spheres and cylinders. A group keeps its blocks and their
operation order in the scene file. You can adjust a doorway after saving and
reopening the scene.

The scene hierarchy uses separate icons for the CSG group, cube, sphere and
cylinder, so you can identify each block even after renaming it.

## Build two rooms with a doorway

To start with the completed example, copy `Editor/Tests/Fixtures/CSGTwoRooms`
from the AdaEngine repository to a writable location and open it as a project
in Studio.

In Studio's agent chat, use the bundled `ada-csg` skill for instructions on
creating, editing and testing CSG groups through the scene tools.

1. Open a 3D scene in desktop Ada Studio. In the scene tree, choose **Add**,
   then **CSG Group**. Expand the group to see its starting box.
2. Select the starting box and name it **Partition**. In **Transform**, set
   Size to `0.4, 3, 6` and Position to `0, 1.5, 0`.
3. In **CSG Group**, set **Block shape** to **Cube** and choose **Add Block**.
   Name it **Doorway**. Set Size to `1, 2.15, 1.5`
   and Position to `0, 0.97, 0`. Choose **Difference**. The box crosses both
   faces of the partition and cuts a floor-height opening.
4. Add another box named **Floor** and keep **Union**. Set Size to
   `10, 0.25, 6` and Position to `0, -0.125, 0`. The floor's top is at Y = 0,
   flush with the opening.
5. Select **Doorway** to see its outline. Use the viewport's **Move**, **Rotate**
   and **Scale** tools to adjust the cut. **CSG Grid Snap** snaps movement
   of blocks to a quarter unit in group coordinates.
6. Try Undo and Redo, then save and reopen the scene. The group and its boxes
   should still be editable.

Use the arrow buttons beside **Add Block** to move the selected operation.
The first enabled block is the **Base**. Studio applies each later operation
from top to bottom. **Intersection** keeps the volume shared by the current
result and the selected shape. An empty result can be valid.

## Add curved shapes and check UVs

Choose **Sphere** to cut a rounded recess or **Cylinder** to make a round hole.
The cylinder stands along Y before rotation. Adjust the cutter with the 3D
gizmos, then set its operation to **Difference**.

In the group inspector, choose **Checkerboard** under **Texture**. Use
**UV Repeat** to set how many times the texture repeats over each chart.
Rotate the view to inspect the seams and the inside of the cut. Box faces and
cylinder caps use planar charts. Spheres and cylinder sides wrap around their
axes. A cut face uses the cutter's chart, so moving or rotating a cutter moves
that chart with it.

Choose a PNG or JPEG from the project's primary assets folder to use your own
texture. Each group has one texture. Texture selection and UV repeat are saved
with the group and are part of scene history. Play and native export carry the
generated UVs and the selected image. Reopen the scene to refresh its preview
after replacing the source image outside Studio.

## Play and export

For an in-editor Play check, add a 3D camera, lighting, and a player character.
Walk through the opening and into the partition beside it. The opening should
be clear and the solid wall should stop the character. Start Play again after
changing the group. The collision is static for the duration of the run.

For native AdaScript export, use a 3D project with the **Model 3D** and
**Physics 3D** runtime plugins enabled. The exporter saves ordinary model
assets and static triangle collision. The exported player does not need the
CSG authoring kernel.

While a group rebuilds, the editor shows the last valid render result. If the
current result fails, check block dimensions, placement, and the texture before
starting Play or exporting. Each group supports up to 128 blocks and is subject
to a triangle budget. CSG textures can be up to 4,096 pixels per side and
32 MiB before import.
