# Terrain

Open a native Studio scene and select **Terrain** in the viewport toolbar. The
terrain dock opens **below the viewport**. It includes **Sculpt**, **Materials**,
**Joining**, **Mesh Instancing**, and **Height Generator**. The Inspector keeps
ordinary entity components. **Mesh Instancing** also has its own viewport toolbar
button. Play uses a separate runtime and does not show the authoring dock.

## Create and join Mesh Terrain

Set **Terrain Type** to **Mesh Terrain** and choose **Create Terrain**. This
creates a saved 128-unit surface from a 64 Ã— 64 grid of cells. Choose **Heightfield**
to create ground for the heightfield workflow described below.

For a first join, add a static cube to the scene and position it so it crosses the
ground surface. In **Joining**, select the cube, choose the **Target Terrain**, set
**Operation** to **Join**, and choose **Join selected mesh**. A closed mesh with
consistent face winding works as a solid. Joining replaces the overlapping faces
with a connected surface. The cube stays in the hierarchy and remains selectable.
A self-contained GLB can contribute its opaque trunk and roots while its
cutout leaves keep their own draw. Joined source triangles keep the original
color, roughness, normal maps and texture coordinates. Keep the model in
project Assets so the joined surface can load its textures when you reopen the
scene.

Use **Contact width** to control the transition around a joined object. Choose
**Subtract** to cut a closed shape out of the terrain, or **Conform** to project
the existing ground toward a static mesh. Conform keeps the source visible and
works with an open surface. **Projection distance** limits the reach of the
projection above and below the ground; **Projection strength** controls how far
the affected vertices move. Choose **Apply operation** to rebuild.

Select the cube and use the viewport's Move tool. While the editor prepares a new
surface, the previous terrain remains visible. Releasing saves the accepted shape
and position in one Undo step. Escape cancels an in-progress move. Undo and Redo
restore the saved surface with the cube's corresponding position. The original
model asset stays available for reuse. Keep the entire joined mesh within the
terrain's boundary. A move past the edge is rejected and the last accepted
position stays in the scene.

To place a joined object precisely, edit its Transform in the Inspector and
press Enter. The terrain and the object's new transform are saved together.
If the new position crosses the terrain boundary, Studio keeps the last valid
position and shows why the edit was rejected.

To move a group of joined objects, select their parent in the hierarchy. All
joined objects in the group must share one Mesh Terrain target. Release the
Move handle or press Enter in the Inspector to save the group and the rebuilt
terrain in one Undo step.

Select the bound object and choose **Detach from terrain** in Joining or in the
Inspector to make it independent again. The ground and its procedural population
rebuild without that object. Undo restores the original binding and surface.

Use the render selector in the 3D viewport to choose **Wireframe** or **Shaded +
Wireframe**. Wireframe shows triangle edges; the combined mode keeps the shaded
surface visible under the edges. Choose **Shaded** to return to the usual view.
These modes are for inspection in the viewport and do not change Play or the
scene's authored materials.

Zoom out in Wireframe to inspect Mesh Terrain's render LOD. Eligible regions
switch to a coarser meshlet level as they occupy fewer pixels. Adjacent terrain
sections keep the same shared edge, even when one section shows finer triangles.
Regions with varying material paint retain their original triangles.

## Create and generate heightfield ground

With **Terrain Type** set to **Heightfield**, **Create Terrain** creates a saved
128-unit terrain with 129 Ã— 129 height samples under an Environment parent. The
resource lives in project Assets. In **Height
Generator**, set **Height Amplitude**, **Noise Frequency**, and the seed, then choose
**Generate Heightmap**. Five deterministic noise octaves create hills and valleys;
**New Seed** changes their arrangement. Generating on an existing source keeps its
other saved channels and creates one undoable resource version.

**Add region** expands a partial region before adding an adjacent 256-cell region.
The runtime uses 64-cell surface chunks, independent persistence regions, distance
LOD, and bounded streaming. Old heightfield Terrain components remain readable.

## Sculpt in the viewport

Choose **Raise**, **Lower**, **Smooth**, or **Flatten**. On Mesh Terrain, Smooth
follows connected triangles on the selected surface. Flatten uses the plane at
the start of the stroke. The Heightfield workflow also offers presets for ramps,
terraces, noise, erosion and brush shapes. Radius and strength are shared
controls. Hold the left button and drag over visible terrain. A blue
ring follows its surface. Source strokes publish worker batches **while the button
is held**. Releasing finishes the stroke and saves one resource version; Escape
cancels it. Each complete stroke is one ordinary scene Undo action. Undo, Redo,
Save and reopening the scene retain the selected resource version.

Terrain authoring uses coherent asynchronous worker publication. Large volumetric
regions can take longer to prepare than a simple heightfield. The previous valid
mesh stays visible while a batch is prepared, and camera navigation remains usable.
Height tools edit the base heightfield; volume tools address additional strata.

## Materials and texture variation

In **Materials**, choose a card to paint its layer. **Add Materialâ€¦** opens the
system file picker and imports a PNG or JPEG as a new layer, with a thumbnail.
Imported textures are copied into the terrain resource directory. Terrain layers
have stable IDs; choosing another card does not renumber saved paint.

**Automatic Grass / Rock / Snow** initializes height and slope rules. Grass covers
lower gentle ground, rock covers steeper surfaces, and snow covers higher ground.
Existing layers are retained when applying variation settings again. Painted
material overrides these rules; **Erase material paint** reveals them again.

On Mesh Terrain, select its entity in the hierarchy before painting. Each stroke
follows the connected side under the brush. Paint on the ground stays in place;
paint on a joined rock or root follows the source when it moves. If that part of
the surface disappears, the stroke stays saved and can apply again when a
matching surface returns. Erasing reveals the current contact and automatic
layers. Paint and erase each create one Undo step and leave the mesh shape alone.

New texture layers use deterministic flips, quarter-turn rotations, random offsets,
macro variation and triplanar projection. Terrain-local coordinates keep variation
stable across chunk boundaries and camera movement. Volume material fields evaluate
actual surface height and normal, including multiple strata at the same X/Z.

## Mesh instancing and solids

Select the separate **Mesh Instancing** button, then **Add Meshâ€¦** to import a
self-contained GLB or VOX. Choose its palette entry, density and brush radius.
**Paint meshes** and **Erase meshes** edit persistent instance records. Copies share
mesh buffers rather than becoming thousands of authored hierarchy entities.
Decorative instances do not create per-instance physics bodies by default.

On Mesh Terrain, **Paint meshes** records where to generate the selected
prototype. **Erase meshes** clears its generated coverage without deleting
manual placements or pinned overrides. A pin that loses its supporting surface
is retained in the resource for recovery. If a joined object moves, the ground
it uncovers can grow the painted vegetation again. The area around its new
position clears according to the rule's exclusion distance.

**Add solid** and **Subtract solid** use a sphere, box, capsule or a registered
palette mesh as an ordered volume operation. Position it with the brush and release
to apply. Caves and overhangs are real generated surfaces, with matching runtime
collision. Mesh operands must be supported closed static solids. Self-contained
models avoid silently omitting external model dependencies. Invalid resources keep
the last valid terrain generation.

## Saved sources and compatibility

An entity's **Terrain Source** component references a project `.aterrain` resource,
for example `@res://Terrain/playground.aterrain`. Keep its immutable region, mesh
document, model, texture and volume files together. The editing runtime resolves absolute paths;
scene references stay portable. Missing or outside-project terrain roots are rejected.

Strokes operate on private same-directory manifest versions and publish their URI
through scene history. Earlier resources remain exact for Undo; unpublished manifests
are removed only after active filesystem writers finish. Shared payloads are never
deleted by gesture cancellation. Intermediate versions can therefore accumulate.

The edit viewport omits source collision cooking; authored collision settings and
Play retain runtime physics. A nil streaming radius retains full-declared-set
residency, while newly added generic Source components use the engine's camera
streaming default. The old Terrain component still supports its four legacy brushes.
Advanced presets and saved palettes belong to Terrain Source resources.

Native Windows is exercised during development. Other platform acceptance and full
portable export validation remain separate checks; local editor tests do not prove
those platforms. Three-dimensional manual paint storage and volumetric curvature
rules are not yet equivalent to the heightfield paint channels.
