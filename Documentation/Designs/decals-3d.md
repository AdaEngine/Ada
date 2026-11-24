# Surface decals for static and dynamic 3D meshes

## Scope

Game code can put a sticker, scuff, or paint mark on a wall, a moving car, or
an animated character through the same Swift API. A decal stays on the chosen
surface as the object moves. On a character, a decal across an elbow bends
with the sleeve and can be placed while the elbow is already bent.

The first release targets opaque triangle meshes using the standard PBR
raster path. Placement works at scene setup and during gameplay. Place,
update appearance, and remove operations apply to individual decals. Studio
placement tools, scene-file authoring, transparent receivers, and path-traced
decals are follow-up work.

## Placement and attachment

- A placement request specifies a receiver entity, optionally a mesh part,
  an oriented projection box, and a decal material. The base color texture
  supplies alpha coverage. Normal and roughness textures are optional.
  Size and depth set the volume. The projection direction and surface-facing
  cutoff restrict the affected faces.
- Placement tests the chosen render mesh. A physics raycast can select a
  candidate entity and give an approximate position and normal. A placement
  that misses the visible mesh or targets unsupported geometry returns a
  failure and creates no decal. See
  [the current physics raycast result](../../Sources/AdaPhysics/Physics3D/PhysicsWorld3D+Raycast.swift).
- Static and rigid receivers use the same attachment in receiver-local
  coordinates. The decal inherits the receiver's full world transform,
  including changes from parents and physics.
- For a skinned receiver, project onto the current posed triangles at placement.
  Clip the footprint to the projection volume and record the originating
  triangle and the weights of its three corners at each clipped point, along
  with its decal texture coordinates. Evaluate the attachment using those
  same weights on the animated triangle so its texture follows the surface
  through bends. Use the same morph-then-skin order as the visible mesh when
  both deformations are active. Keep the stored footprint independent of
  the model's existing texture coordinates. See
  [mesh part geometry](../../Sources/AdaRender/Mesh/Mesh.swift) and
  [ADR-0027's morph evaluation](../ArchitectureDecisions/0027-3d-rendering-pipeline-gap-roadmap.md#stage-3-first-slice-morph-targets-2026-10-19).
- Bind a skinned attachment to its source topology. In the first release,
  keep compatible geometry active for that receiver while it has attached
  decals. Release that requirement on removal. Replacing the receiver's mesh
  invalidates old attachments. Removing the receiver also releases its
  decals and render resources.

## Rendering and ownership

Own placement and receiver lifetime in `AdaScene`. Extract per-receiver
decal data into the existing 3D render snapshot. Let `AdaCorePipelines`
apply decal channels in the forward PBR path before lighting so the mark
shares the receiver's shading. The receiver controls the visible silhouette,
depth, and occlusion. Resolve overlaps in a stable order using explicit
priority followed by creation order. Preserve shared material assets and
keep decal data per receiver.

During implementation, prototype a clipped mesh patch driven by the
receiver's source triangles and use it to verify surface tracking. Confirm
how to feed the resulting coverage and channels into the forward PBR path
on both native backends before freezing the GPU representation. The
projection is evaluated at placement. Animation updates the attachment
from the current pose, and stationary decals reuse their footprint. Measure
placement cost, ongoing render cost, and memory as decal counts rise, and
use that evidence to set bounded budgets. Keep the existing rendering path
for receiver draws without decals.

A screen-space box can project across multiple surfaces and would need a
receiver mask to isolate the intended object. It also needs separate surface
tracking to carry texture coordinates through an elbow bend. Bevy's forward
decal implementation illustrates a projected approach using a camera depth
prepass. A full posed-mesh snapshot is another placement option, with a
distinct CPU cost in implementations such as Unity's `BakeMesh`. Evaluate
only the candidate geometry needed for a stamp when practical.
[Bevy forward decal source](https://docs.rs/bevy_pbr/latest/src/bevy_pbr/decal/forward.rs.html),
[Unity BakeMesh documentation](https://docs.unity.com/en-us/engine/6000.6/script-reference/unityengine/skinnedmeshrenderer/bakemesh)

## Acceptance and documentation

- Render a wall mark and a car sticker in the same scene. Move and turn the
  car past the wall and a second car that shares its mesh and material.
  Verify that each decal stays on its own receiver, respects occlusion,
  receives lighting from the scene, and remains stable at a grazing angle.
- Stamp across a two-joint sleeve in a bent pose. Straighten it and bend it
  again. Verify that recognizable points of the decal remain at the same
  locations on the surface across the joint. Also check morph plus skin,
  visibility and LOD transitions, overlapping decal order, individual removal,
  and receiver deletion.
- Add focused Swift Testing cases for placement and lifecycle and extend
  `Render3DGPUTests` with rendered comparisons. Run the SAGA GPU validation
  on Vulkan and Metal and compare CPU/GPU timings with and without decals
  using the 3D benchmark workflow. Validate a browser render on WebGPU before
  listing browser support. The shared contribution checker and independent
  review cover the implementation and its validation evidence.
- Add `Sources/AdaEngine/AdaEngine.docc/Articles/3D/Decals.md` and link it from
  `Sources/AdaEngine/AdaEngine.docc/AdaEngine.md`. Show a Swift placement
  example for a moving object and a skinned character, explain the receiver
  and backend limits, and build DocC and run the example through the actual
  game API before review.
