# Terrain Authoring V2

Status: **Accepted**.
Approval: user approval in the project conversation on 2026-11-04 after reviewing
the document and removing external-reference discussion.
Date: 2026-11-04.
Classification: feature spanning terrain runtime, materials, asset storage and Studio authoring.
Local implementation validation task: `terrain-authoring-v2-implementation`.
Implementation plan: `Documentation/Plans/2026-11-04-TerrainAuthoringV2.md`.

## Purpose and requirements

Build a terrain authoring system in which users can shape large landscapes, paint
natural surfaces, scatter meshes, and form real caves and overhangs using mesh union
and subtraction. Tool organization includes brush modes near the viewport, brush
settings, a texture/mesh asset palette, and additional terrain settings in the Inspector.

The request includes all six capabilities below. Delivering only heightfield stamps
does not satisfy mesh Boolean operations. The user explicitly confirmed in this
chat on 2026-11-04 that caves and overhangs are required.

| Requirement | Observable result |
| --- | --- |
| Mesh instancing | Paint and erase many copies of grass, rocks or trees using shared assets and spatial batches. |
| Texture flips and detiling | Repeated surfaces vary through deterministic mirroring, rotation and offsets, without a visible chunk grid or incorrect normal lighting. |
| Chunks | Extend terrain through sparse regions; editing and loading operate on bounded subsets, with continuous borders and distance LOD. |
| Automatic textures | Height, slope, curvature, noise and painted masks select and blend materials; manual painting remains available. |
| Many brushes | Multiple real operations, procedural/imported shapes and reusable presets; not merely different names for Raise. |
| Mesh union/subtraction | Drop a supported mesh, preview Add/Subtract, and commit solid terrain changes with matching collision, including caves and overhangs. |

## Verified baseline

AdaEngine currently has a single square `Terrain3D` heightfield with 2–257 samples
per axis, a solid-color PBR material, and one generated mesh/static triangle collider.
Any terrain or transform change rebuilds the whole mesh and collider.
Studio has Raise, Lower, Smooth and Flatten, circular falloff, radius/strength,
triangle picking, and one history entry per stroke. Existing scenes retain their
height samples through Codable scene loading and native export.

Sources inspected:

- `Sources/AdaScene/3D/Terrain/Terrain3D.swift` and `Terrain3DSystem.swift`.
- `Editor/Sources/AdaEditor/EditorTerrainBrush.swift` and
  `UI/Editor/EditorSceneViewportTerrain.swift`.
- `Editor/Documentation/Terrain.md`, `EditorTerrainTests` and
  `EditorTerrainInspectorTests`.
- `Sources/AdaCorePipelines/CorePipelines/VisibleMesh3DLists.swift`:
  existing renderer batching requires shared mesh buffers and material identity.
- `Sources/AdaScene/3D/Voxel/VoxelWorldStorage.swift` and `VoxelWorld3D.swift`:
  sparse 32-cubed occupancy chunks, dirty halos and budgeted remeshing already exist.
  This block-voxel system is not a smooth density field or a mesh Boolean implementation.

ADR-0027's historical “no terrain” statement predates the current basic terrain.
Its tiled-LOD/splat-material direction remains relevant. ADR-0025 supplies occupancy
chunking precedent. Do not rewrite their historical decisions. Record the new hybrid
terrain decision in a new ADR after approval and cross-link these precedents.

## Ownership and public compatibility

- **AdaScene:** terrain component/data access, region revisions, surface queries,
  instance placement and terrain runtime systems. Keep authored state independent
  of a renderer or an open Studio document.
- **AdaRender / AdaCorePipelines:** terrain material descriptors, texture-array
  bindings, shared PBR lighting integration, detiling and terrain render extraction.
  General-purpose scalar-field surface extraction belongs in the renderer-neutral
  geometry area; do not introduce a dependency from AdaRender back to AdaScene.
- **AdaAssets:** versioned terrain asset loading and ordinary model/texture resources.
- **AdaPhysics integration:** static triangle collision generated from the authoritative
  terrain surface, including interiors; decorative instance collision is explicit.
- **Editor:** palette, localized controls, strokes, drag/drop previews, transactions
  and project resource handling. Use AdaUI and existing scene history.

Retain existing `Terrain3D` scene decoding, default appearance and public heightfield
operations. Existing scenes open without conversion prompts or missing-resource errors.
New data uses an optional versioned terrain-asset reference. Editing a legacy patch
in the new system creates its asset through one undoable conversion; the unchanged
legacy format remains readable. Do not silently discard the old payload.
`surfaceHeight(at:)` remains a legacy/top-surface convenience; add a ray query returning
the nearest hit, normal and material for surfaces with multiple heights at one X/Z.
Do not infer cave floors from a single height sample.

## Sparse data, rendering and streaming

Use three distinct units: a **region** for persistence/residency, a **surface tile**
for mesh/LOD/collision invalidation, and a **volume brick** for edited 3D density.
Proposed defaults are 256-by-256 base cells per region, 64-by-64 cells per surface
tile and 32-cubed cells per volume brick, with 1-unit base spacing. Region and brick
coordinates are signed, use floor division for negative positions, and are independent
of camera placement. Spacing and volume precision are explicit terrain settings.

Canonical shared samples have one logical owner; halos are derived. An edit across
a tile/region/brick corner invalidates all dependent geometry, normals, rule caches
and colliders. Unallocated regions are empty. Creating terrain there is an explicit
undoable operation. An untouched distant region must not rebuild during a local stroke.

Terrain assets contain a versioned manifest plus independently addressable region
payloads, layer/mesh asset references, painted masks, placed-instance records and
volume edits. Persist through the project asset system with staged writes and a
manifest commit so a failed save cannot reference partially written region data.
Collect these resources in native exports. Validate sizes, versions, finite samples,
indices, paths and decoded memory budgets before allocation. Reject unsupported
versions with an actionable error, rather than loading corrupted terrain as empty.

Residency uses camera distance, an explicit byte budget and hysteresis. Authoring
pins dirty, selected and in-flight transaction regions. Collision residency includes
active physics bodies, rather than relying only on a possibly distant editor camera.
Cancel obsolete loads and remesh jobs. Use immutable Sendable snapshots and revisions;
only publish results if their source revision is still current. GPU resource creation
and world mutation remain on their established isolation boundaries.

Use tiled heightfield LOD with neighbor differences limited to one level and explicit
edge stitching/morphing. Collision and editing queries use the authoritative detail,
not a distant visual mesh. Volumetric tiles and their seam neighbors initially pin
to their canonical surface resolution; distance culling and streaming still apply.
Adaptive volumetric LOD is outside this version. No per-frame full-array equality scan,
full-world copy or mesh/material recreation is allowed for unchanged terrain.

## Materials and automatic painting

Provide up to 32 named terrain layers, addressed through stable asset IDs. A layer
contains albedo, tangent normal, roughness/metallic/AO data, optional blend height,
tint, physical scale, projection and detiling settings. Use a dedicated bounded
terrain texture-array layout instead of adding unbounded samplers to the existing
PBR material. Normalize/import texture dimensions and formats at asset preparation;
report incompatible or missing maps with a usable fallback. Validate the actual
Metal and WebGPU binding limits before finalizing GPU layouts.

Resolve a bounded set of at most four active material contributions per shading
location; deterministic pruning and interpolation must preserve continuity at tile
borders. Layer count must not multiply the base shader cost by 32. Share the same
PBR lighting, shadows and color-space conventions as other 3D meshes.

Randomization uses terrain coordinates, layer ID and a saved seed, never camera or
chunk IDs. Optional U/V flips, quarter-turn rotations and offsets apply consistently
to all maps. Transform normal orientation and gradients correctly, including reflection
handedness. Blend neighboring randomized samples to avoid replacing a repetition grid
with hard UV seams. Add low-frequency macro variation. Provide planar projection
for ground and triplanar projection for cliffs, cave walls and ceilings.

Rules have enabled state, target layer, weight, height/slope ranges, soft transitions,
optional curvature and seeded noise, and an optional painted mask. Height and slope
are measured in terrain-local units relative to its origin/up axis; this makes moving
or rotating the terrain preserve authored biomes. Explain these coordinates in the UI
and guide. Evaluate curvature from derived surface data with neighbor halos. A moisture
mask is artist-authored data, not a claim of hydrology simulation.

Combine enabled rule weights, prune deterministically and normalize. If all weights
are zero, use the configured fallback layer. Manual paint uses an explicit override
mask; erasing the override reveals automatic rules. Sculpting invalidates derived
rules where surface shape changed without overwriting painted data. Volume interiors
use the same rule/material system with a configurable interior fallback.

## Mesh instancing

Register reusable static model assets in the palette. Paint/erase instances with
density, spacing, scale range, yaw, normal alignment, height offset, seed and
height/slope/material filters. Stable instance IDs and saved placement transforms
survive streaming, reload and Undo/Redo. Do not randomly regenerate authored placements
on each frame. After sculpting, surface-anchored placements reproject locally; instances
whose anchor surface disappeared are removed in the same undoable edit.

Partition placement records into spatial cells and share imported mesh buffers,
materials and textures across all copies. Preserve multi-primitive model structure
and imported child transforms; do not flatten every source model into its first mesh.
Integrate existing frustum/distance culling, mesh LOD and compatible render-pass batching.
Do not promise a single draw for different materials or depth-sorted transparent meshes.
Avoid creating one authored scene entity per blade of grass. Runtime extraction must
consume placement buffers or cell groups without retaining one full ECS entity per instance.

Decorative instances default to no collision. An opt-in nearby static collision mode
uses source colliders for suitable props and has explicit count/distance budgets;
dynamic gameplay objects use ordinary scene entities. Document this distinction.

## Brushes and Studio interaction

Terrain mode exposes tool categories near the viewport, a collapsible texture/mesh/
brush palette, quick brush settings and advanced Inspector groups. Keep the viewport
usable when the palette is collapsed and at the existing narrow Inspector width.
Preserve camera navigation, selection, Play isolation and accessibility identifiers.
Every label, tooltip, validation error and preset name ships in English and Russian.

Ship these actual operation families:

- Surface shaping: Raise, Lower, Smooth, Flatten, Set Height, Ramp, Terrace, Noise,
  and bounded local Talus Relaxation with explicit iteration limits.
- Surface painting: layer paint/erase, automatic-rule mask, tint and roughness.
- Instances: scatter and erase, with the placement controls above.
- Region tools: add/remove regions, with a destructive-result preview before committing removal.
- Volume tools: Add/Subtract solid brush, smooth density and imported-mesh Add/Subtract.

Shapes are separate from operations: soft/hard round, square, line/ridge, crater,
ridged noise, stamps and imported grayscale alpha masks. Ship at least 24 useful
named presets spanning shaping, painting, scattering and volumes. Presets reference
real parameters and have thumbnails; users can save their own and import additional
alpha masks. Bound image dimensions, decoded bytes and iteration/sample budgets.
Procedural masks and bundled original assets avoid depending on unlicensed samples.

Controls include radius, strength, falloff, spacing, rotation/jitter, seed and applicable
height/slope masks; unsupported controls disappear for the active operation. Flatten
retains stroke-start height by default. Time-based tools remain time-scaled and
movement-based tools use deterministic distance spacing, independent of frame rate.
Tablet pressure is optional when the platform already provides it, with a normal
mouse fallback; adding new tablet platform support is not required by this feature.

One stroke or committed mesh operation is one history transaction across all touched
regions, masks, volumes and placements. Escape cancels and restores the complete
transaction. Use dirty-data deltas rather than copying the whole terrain for each
pointer event. Chunk-aware bounds and acceleration structures replace rebuilding and
ray-testing every terrain triangle on every hover.

## True mesh union, subtraction and caves

Use smooth scalar-density volume bricks for local volumetric edits, initialized from
the heightfield solid. The sign convention is negative inside, positive outside.
Union is `min(terrain, operand)` and subtraction is `max(terrain, -operand)`.
The derived density need not remain an exact signed-distance function after CSG.
Extract a smooth triangle surface rather than rendering occupied voxel cubes.
The existing block-voxel mesher remains available for its original use cases.

For regions containing volume edits, affected surface tiles become owned by the
volume extractor, including the base surface through those tiles; suppress the
corresponding heightfield triangles. Extend conversion over a halo and construct
shared boundaries from canonical samples. Include explicit seam geometry where
heightfield and volume triangulation differ. The result must have no holes, duplicate
coplanar faces or collision cracks at the ownership boundary. This invariant requires
dedicated geometry and actual rendering/collision tests, not only a density test.

Keep the heightfield as an editable base and persist volume operations in ordered,
non-destructive form, with spatially indexed density caches. Subsequent base sculpting
re-evaluates relevant cached bricks with those operations; deleting a cut restores
the base. Persist stable source references, transforms, operation order, precision
and material assignment. Invalid source assets produce an error and retain the last
valid saved result until repaired. Baking is explicit and undoable.

Drop a static mesh asset from the project browser or mesh palette into terrain mode.
Show a movable/rotatable/scalable preview with Add/Subtract and resolution controls,
affected bounds and estimated brick/memory cost before the user applies it. The source
asset remains reusable and the terrain operation appears under the terrain in a
readable hierarchy. Escape cancels without changing either the terrain or source.

Solid operands must be finite, closed, consistently wound, non-self-intersecting,
manifold triangle meshes; support spheres, boxes and capsules directly as well.
Validate before mutating terrain. Open/non-manifold meshes receive an actionable
message; provide explicit thickness conversion for suitable open stamps only if
implemented and documented separately. Animated/deformed operands require a baked
static mesh. Apply full source/parent transforms, including nonuniform scale and
reflections; reject singular transforms. Solid classification must work for concave
operands. Bound voxelization and validation work and allow cancellation.

Union may use the terrain's material rules or an assigned operand layer. New cut faces
use the configured interior layer/rules, not undefined source UVs. Precision is an
explicit cell size: features below it may disappear, and a finer choice costs memory
and processing time. This is solid terrain editing at sampled precision, not an exact
CAD triangle Boolean or a promise to retain all source topology/UVs.

Regenerate visual geometry, ray-query acceleration and triangle collision from the
same committed surface revision. During editing show a pending preview; Play must
wait for coherent collision or report why the operation is still pending. Test actual
movement through a subtracted tunnel and standing on an added ledge.

## Alternatives and scope boundaries

- **Heightfield-only mesh stamps:** simpler, but cannot meet the explicitly confirmed
  caves/overhangs requirement.
- **Dense global volume:** handles caves uniformly but wastes memory for broad open
  landscapes; use sparse local conversion instead.
- **Exact arbitrary triangle CSG:** strong topology guarantees require a substantial
  robust geometry kernel; sampled smooth solids fit editable terrain and bounded chunks.
- **Geometry clipmaps immediately:** useful for very large distant surfaces, but do
  not solve volumetric ownership; tiled LOD fits incremental meshes and collision first.

All six requested capabilities belong to this feature. Browser-shell authoring parity,
multiplayer editing, water simulation, hydraulic erosion, runtime deformable physics,
adaptive volumetric LOD and exact CAD CSG are separate work. Do not present those as
implemented. Existing mobile/VR input parity is not established by desktop validation.

## Platforms, documentation and acceptance evidence

Keep runtime storage and geometry backend-neutral under Swift 6.2 isolation rules.
Exercise native Studio on Windows and macOS, material rendering on WebGPU and Metal,
and compile/runtime compatibility on supported Linux, Android, Apple mobile/visionOS
and WASM paths as selected by the validation profile. The browser can consume exported
terrain assets without gaining the native authoring UI. Missing host/hardware evidence
remains blocked; Windows results do not establish Metal or mobile interaction.

Deliver substantial user documentation in the same implementation change:

- Update `Editor/Documentation/Terrain.md` with the full authoring workflow,
  migration, presets, materials, instances, caves, limitations and troubleshooting.
  Link it from `Editor/Documentation/EditorGuide.md` and `Editor/README.md`.
- Add `Sources/AdaEngine/AdaEngine.docc/Articles/3D/Terrain.md` for runtime configuration,
  asset loading, surface queries, collision and export; link it in `AdaEngine.md` Topics.
- Add the editor terrain guide to the maintained offline generator inputs, regenerate
  `Editor/Sources/AdaEditor/Assets/Documentation/catalog.json`, and run its `--check`.
- Provide a reproducible example project/scene with automatic grass/rock/snow layers,
  manually painted path, shared rock/grass instances, a carved tunnel and an added
  overhanging ledge. Build its actual code and test packaged save/reopen/Play/export.

Acceptance requires evidence for all of the following:

1. Legacy scenes retain shape, transforms, color, queries and static collision; an
   explicit conversion round trip preserves them and supports Undo/Redo.
2. A 1024-by-1024-unit sparse test landscape includes negative coordinates and missing
   regions. Cross-corner strokes are continuous. Unrelated chunks do not remesh; a
   residency traversal loads/unloads clean data and retains dirty/pinned data.
3. Visual LOD transitions and heightfield/volume boundaries have no visible cracks.
   Collision/picking remain accurate across those seams and transformed terrain.
4. Shared-asset placement supports 100,000 decorative instances in a benchmark fixture
   without one authored/full-runtime ECS entity per instance. Record CPU/frame time,
   draw counts and memory, comparing batching with separate draws on the same hardware.
   Use the repository performance harness; no universal frame-rate promise is implied.
5. Golden images on Metal and WebGPU show matching detiling, normal orientation,
   continuous chunk boundaries, cliff/ceiling mapping and correctly normalized rules.
   Tests cover zero weights, manual override/erase and layer reordering by stable IDs.
6. Every brush operation has a meaningful production-path test. Preset/alpha import,
   frame-rate variation, extreme settings and one-transaction multi-region cancellation
   are covered. At least 24 shipped presets are accessible in localized mounted UI.
7. Concave mesh union/subtraction creates a cave/tunnel and an overhang across chunk
   boundaries. Save/reopen, reordering/removing operations, Undo/Redo, source transforms,
   brush edits and Play collision preserve the committed result. Invalid meshes and
   canceled/budget-exceeding work leave the original terrain unchanged.
8. Region resources, layers, placements and density edits survive project relocation
   and native export; truncated/untrusted assets fail within declared memory limits.
9. Packaged native Studio exercises the palette, preview, narrow Inspector, language
   switching, stroke input and Play. Backend/material checks use real GPU pixels, not
   compilation or cached WGSL alone. Browser export is served and exercised where applicable.
10. Required lint/analyzers, focused then owning/downstream tests, WebGPU validation,
    applicable platform builds, docs/example/offline checks and independent review cover
    the final change. Record TDD Red/Green/Refactor through the shared runner. Missing
    prerequisites and failed checks cannot be labeled inapplicable or passed.

Before implementation, enumerate exact task-owned files as each slice is introduced;
preserve unrelated contributor-workflow edits. Run the shared contribution runner at
stage transitions. Independent review uses a separate subagent and includes user-guide
accuracy, applicable third-party license compliance and all six requirements. Implementation and
the permanent implementation plan begin only after the human receives and approves
this document, as required by the accepted contributor workflow.
