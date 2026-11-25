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

## Proposed Studio authoring and AdaScript API

Extend 3D decals with two workflows. A scene author can place a permanent
sticker on a wall or a car from the native 3D viewport. An AdaScript author
can apply, change, and remove a decal during gameplay. Both use the existing
native SAGA raster decal renderer and its opaque indexed PBR mesh and budget
requirements.

### Studio workflow

- Add a **Decals** mode to the 3D scene toolbar alongside the existing
  surface tools. Use Studio's shared toolbar, image asset picker, Inspector
  and axis fields. Entering the mode exits another active surface tool.
  Keep normal scene navigation available while placing a decal.
- Choose a color image from the project's imported assets. Alpha sets
  coverage. Point at a surface to see a transient placement guide with
  the image's orientation and projection bounds. The nearest visible
  triangle determines the receiver and normal. An unsupported foreground
  surface or an empty hit shows why placement is unavailable. A click
  commits one decal through the existing renderer. Escape cancels the
  pending placement and preserves earlier edits. Keep the chosen image
  ready for the next placement until the mode closes.
- Select a receiving object to see its decal list in the Inspector.
  Select a decal to change the color image, three projector dimensions
  (width, height, depth), rotation around the surface normal and overlap
  priority. Optional normal and roughness images use the same project
  asset picker. **Move** starts a new surface pick on the same receiver.
  **Delete** removes the selected entry. **Done** closes the tool. Document
  undo/redo covers a placement, removal, or committed edit as one action.
  Invalid edits preserve the last valid preview and show a localized error.
- Target the desktop scene workspace on Windows, macOS and Linux.
  Keep toolbar overflow, keyboard focus, localized accessible names,
  narrow Inspector widths, and English and Russian text within existing
  Studio controls. Support accepting a valid preview with Enter once the
  viewport has focus, and restore focus when a picker or placement closes.
  Gate the tool in other workspaces and in unsupported rendering modes.
- Author onto primitive meshes and static or rigid meshes from imported
  models. Studio placement on a skinned, morphed, terrain, or generated CSG
  surface is outside this increment. AdaScript retains the engine's
  ability to stamp the current deformed pose on supported models.

### Scene data and publication

Store an ordered decal list on the authored owner in the scene file. Each
record has a stable ID, project image references, a receiver-local projector,
size and appearance settings. For an imported model, resolve the underlying mesh
through a validated model source and node locator scoped to the authored owner.
Two instances of one model keep independent lists. A source change that makes
the locator ambiguous or incompatible shows a broken target instead of placing
the decal on a different mesh. Missing images leave the authored data editable.

The scene retains the authored records across Save, reopen, duplicate, scene
instancing and native export. The decal preview and game runtime resolve the
same asset references and publish through the existing Decal3D operations after
the target mesh exists. Persist the full local frame so parent movement and
nonuniform scale preserve the placement through reload. Reconcile changes by
record ID. Cancel superseded asset work on edits or world replacement and
rebuild attachments when compatible meshes are regenerated. Preserve saved
tie ordering and the shared limits for authored and gameplay decals on a
receiver. Load affected assets only when their references change, and keep
the hover guide out of scene history and the persistent render atlas.

A precomposited model texture would affect all instances using the material
and require a new texture for each independent edit. The receiver-local
projector keeps instances independent and allows later edits in the Inspector.

### AdaScript gameplay operations

Expose the same world-scoped operations in the interpreted runtime and the
compiled native backend. The proposed entry points on `context.world` are
`placeDecal`, `updateDecal`, `removeDecal`, and `decalResult`. Placement takes a receiver
entity ID, a project image reference, the world-space point and surface normal,
and a three-component size. Optional settings cover rotation, priority and
normal and roughness image references. Update changes appearance in place.
Remove and update take the receiver and its decal handle.

A command returns a detached request token immediately. Poll `decalResult` in
a later callback. It returns `null` while pending, then the existing result
shape with `isSuccess()`, `value()`, `errorCode()` and `message()`. A successful
placement returns a detached handle to the decal. Completed results are
consumed on retrieval, with bounded retention for results no script reads.
Expired and unknown tokens produce a defined error. Handles are scoped to the
receiver and world. Deletion, mesh replacement and world teardown invalidate
them. Script handles address decals placed through this API.

Use a bounded world-owned command queue with detached arguments. Resolve
portable project image references through the existing asset system and
apply commands on the main-actor world path after pose evaluation and
before render extraction. Process commands for the same receiver in submission
order even if asset loads finish in another order. Report missing assets,
invalid arguments, unsupported receivers or backends, misses, capacity and
stale handles as operation failures. Failed operations preserve existing
decals. Publish signatures and result help through the AdaScript API catalog
for completion and diagnostics.

The first release targets native SAGA Vulkan and Metal playback. WebGPU,
headless rendering and path-traced views retain the existing decal limits.
Unsupported script calls report a recoverable result without decoding images.

### Acceptance and documentation

- In Studio, place two decals on one wall and one on a moving, imported car.
  Use two instances of the same model to verify receiver identity. Exercise
  image selection, surface preview, invalid targets, numeric editing,
  replacement, cancellation, undo/redo, duplicate, Save and reopen. Inspect
  an English and a Russian layout and capture default, active, focused,
  disabled and error states at normal and narrow widths.
- Play and export a native project with an authored decal. Verify attachment
  after moving the receiver or a parent, ordering with a gameplay decal,
  texture resolution after moving the project, and diagnosed missing
  assets or changed model nodes. Check that earlier scene files still load.
- Execute the same AdaScript example through a real interpreted game scene
  and the native compiled path. Verify placement on a wall and a bent skinned
  receiver, appearance update, removal, stale handles, errors and backend
  parity. Use the existing 3D decal GPU suite on Vulkan and Metal to confirm
  visible results along both authoring paths.
- Extend the existing [3D Decals article](../../Sources/AdaEngine/AdaEngine.docc/Articles/3D/Decals.md)
  with a Studio placement walkthrough and link it from
  [the Studio guide](../../Editor/Documentation/EditorGuide.md). Add a
  runtime recipe in Sources/AdaScripting/AdaScripting.docc/AdaScriptDecals.md
  and link it from AdaScript's DocC Topics. Show how to place, check, update
  and remove a runtime decal, and explain supported surfaces and backends.
  Run the example in both script modes, build the DocC catalogs and regenerate
  and verify Studio's offline documentation.
