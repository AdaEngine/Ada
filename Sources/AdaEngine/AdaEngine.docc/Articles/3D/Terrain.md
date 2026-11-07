# Terrain

Create editable ground with `Terrain3D`. Its heights describe one square surface
in the entity's local X/Z plane. `Model3DPlugin` generates the visible geometry;
`Physics3DPlugin` adds matching static triangle collision.

## Load Mesh Terrain

Mesh Terrain uses a `Terrain3DSource` whose `.aterrain` manifest references an
`.atmesh` document. Keep the manifest, its document, and its relative resources
together. The document retains the source sections and ordered modifiers. Its
compiled product contains the triangles and placement records that the runtime
can use without the desktop authoring kernel.

With `MainSchedulerPlugin`, `TransformPlugin`, `RenderWorldPlugin`, and
`Model3DPlugin` installed, pass the resolved manifest path to the source:

```swift
let terrain = world.spawn("Mesh Terrain") {
    Transform()
    Terrain3DSource(source: manifestPath, generatesCollision: false, queries: .init())
}
```

Enable `generatesCollision` and install `Physics3DPlugin` if you need terrain
collision. When the source is ready, read `MeshTerrain3DSourceSurface` on the
authored entity. The optional `queries` value supports terrain-local `raycast`
and `closest` queries against the accepted triangles, including surfaces that do
not fit a single height at each X/Z position. Convert world coordinates into the
terrain's local coordinates before querying. A retained query value continues to
describe its original surface after a newer version is published.

When building authoring tools on desktop, enable the `MeshTerrainAuthoring`
package trait and check `TriangleMeshBoolean.isAvailable` before compiling a
document. `MeshTerrainDocumentAsset.compiling()` produces an immutable asset
with an input key covering its geometry and population rules. Recompile changed
inputs before distributing them; the runtime rejects a missing or mismatched
compiled product and retains the last valid surface after a failed update.

A Mesh Terrain manifest can use the shared `TerrainMaterialPalette`. Set a join
modifier's `materialLayer` to an existing palette ID. The operand uses that
layer and `contactWidth` controls how far its material blends along connected
ground, independently of optional geometry rounding. Subtraction uses the
interior layer by default. The renderer stores material fields per triangle;
palette changes do not change the geometry used by queries or collision.

The source prepares one optional coarser meshlet level for eligible display
sections within its geometry budget. The renderer selects it by projected error,
using a two-pixel threshold. Simplification preserves section boundaries and
retains full detail where triangle material fields vary. Shaded and Wireframe
use the same selected index ranges. Set `maximumLOD` to zero to keep full
detail. Terrain queries and collision use the full accepted surface.

An opaque join can retain per-part source materials and vertex attributes in the
triangle document. Portable source maps are read from their self-contained
glTF or GLB resource under `@res://`; keep that resource when moving or packaging
the terrain. The display uses source UV sets on retained source faces and terrain
projection for the palette and cut interior. Transparent or custom shader parts
stay on the original model.

Author material strokes in `MeshTerrainDocument.paint`. Capture a
`MeshTerrainSurfaceAnchor` from the selected triangle hit: ground anchors are
section-local and joined-source anchors are operand-local. Compilation
reprojects each stroke onto a compatible connected side and stores its material
coverage alongside the compiled patch. The player loads that coverage without
replaying brushes. Missing surfaces leave recoverable IDs in
`MeshTerrainCompiledProduct.paintOrphans`; the authored strokes stay in the
document. Erase removes authored coverage so the current rule and contact
materials can show through.

A population rule can also retain `MeshTerrainPopulationCoverage` stamps.
These stamps limit where the selected prototype is generated and can erase
previous coverage. Their anchors preserve the chosen side and source.
Compilation re-evaluates source clearances after a join moves and includes the
resulting placements in the same accepted generation. The player groups the
records into three-dimensional cells using the rule's cell size and shares
prototype geometry across those cells. Authoring reuses previously accepted
cells when the surface, masks and source clearance in their spacing halo
stay the same. Compiled products retain unsupported pins as recoverable
`orphanedPins`.

Use Mesh Terrain authoring to publish new `.atmesh` generations.
`AssetsManager.saveTerrainRegions` edits height and volume sources and rejects
Mesh Terrain manifests, including an outdated heightfield manifest aimed at
the same destination.

## Create a heightfield

Install `MainSchedulerPlugin`, `TransformPlugin`, `RenderWorldPlugin` and
`Model3DPlugin` in your app. Add `Physics3DPlugin` when the ground must block
physics bodies. Create the entity in its main world:

```swift
import AdaEngine

@MainActor
func createGround(in world: World) {
    var terrain = Terrain3D(resolution: 129, size: 128)
    terrain.heights[10 * terrain.resolution + 10] = 3
    terrain.color = [0.28, 0.43, 0.18, 1]
    world.spawn("Ground") {
        Transform()
        terrain
    }
}
```

`resolution` is the number of height samples along each axis; there is one fewer
cell. Heights are row-major along Z. The example creates a 128-unit square centered
on the origin, with one raised sample. Keep heights finite and preserve the
`resolution * resolution` array length. `validate()` rejects malformed data.

## Tile geometry and updates

The runtime divides the patch into tiles of at most 64 Ã— 64 cells. The example
above produces four tiles. Tiles are generated children of the authored entity,
marked by `TerrainTile3DComponent`; save the `Terrain3D` component rather than
these transient meshes or colliders. Generated entities carry `TransientEntity`;
World/Scene serialization omits them and their descendants, and terrain regenerates
them when the scene initializes. Authored parent/child relationships and local
transforms survive the round trip; generated child IDs are omitted from saved
relationships. The raw ECS hierarchy is otherwise unchanged: even
when its owner is removed nonrecursively, terrain cleans its generated mesh and
collision children while ordinary authored children remain.

Changing heights replaces the affected tile meshes and their collision. The
normal's neighbor samples also invalidate adjoining tiles when needed, preserving
continuous lighting at their borders. An edit at a shared corner can update four
tiles. Changing the ground color retains the geometry and updates the shared
material; moving the terrain retains meshes and updates world-space collision.
Parent rotation, scale and reflected transforms are included in collision.

For custom tools, `meshTiles(cellCount:)` returns CPU mesh descriptors with stable
`TerrainTileCoordinate` addresses. `meshTile(at:cellCount:)` builds one tile directly.
Positions and UVs remain in the parent terrain's coordinates. Partial edge tiles
preserve the original cell count; cell counts outside `1...256` throw a validation
error. Runtime tile size uses `Terrain3D.defaultTileCellCount`.

## Queries and persistence

`surfaceHeight(at:)` takes a terrain-local X/Z position as a `Vector2`. It returns
the height on the same triangles used by rendering and collision, or `nil` outside
the patch. Transform a world point into terrain-local coordinates before querying.

The Codable component retains heights, size, color and collision settings through
scene loading and native export. Set `generatesCollision` to `false` to remove
generated colliders. Removing the component removes generated tile geometry and
collision. Geometry is rebuilt from authored data after reopening a scene.

## Sparse height data

Terrain manifests can retain a `TerrainMaterialPalette` with up to 32 named
`TerrainLayerReference` entries and 128 automatic `TerrainMaterialRule` entries.
Each layer has a stable `UInt16` ID: changing its display order preserves rule
references. Choose existing IDs for the fallback surface and volume interior.
Texture paths are relative to the manifest directory. Albedo, normal, packed
occlusion/roughness/metallic and blend-height maps are optional; scale is measured
in terrain-local units per repetition. Height and curvature ranges use local units,
and slope ranges use degrees from the terrain's up axis.

```swift
let palette = TerrainMaterialPalette(
    layers: [
        TerrainLayerReference(id: 7, name: "Grass", albedoPath: "Textures/grass.png", scale: 2),
        TerrainLayerReference(id: 12, name: "Rock", albedoPath: "Textures/rock.png", projection: .triplanar)
    ],
    fallbackLayerID: 7,
    interiorLayerID: 12,
    rules: [TerrainMaterialRule(layerID: 12, slope: TerrainMaterialRange(minimum: 40, maximum: 90, transition: 8))]
)
let layout = TerrainManifestAsset(materials: palette)
try layout.validate()
```

`validate()` rejects duplicate IDs, missing rule/fallback references, invalid
ranges and escaping texture paths. Both native region-save modes preserve this
palette. A manifest containing materials uses version 3; height-only and model-
palette manifests keep versions 1 and 2 respectively.

Source rendering resolves rules into four canonical layer IDs and weights per
sample, then interpolates those fields independently of visual LOD. The strongest
four contributions shade layer tints, roughness and metallic values through the
shared PBR lighting pipeline. `Terrain3DSource.color` multiplies the palette tint;
use `.one` to preserve its authored colors. Color-only edits retain tile meshes
and material fields. Removing the palette on reload restores the ordinary source
material. Albedo maps load relative to the manifest into shared mipmapped arrays;
layer scale controls their repetitions. Preparation caps normalized dimensions at
256 pixels, bounds encoded/decoded/staging memory before allocation, and reports
missing or incompatible images in `Terrain3DSourceStatus.warnings` while preserving
a usable fallback. Tangent-space normal maps share the existing PBR normal frame.
Packed ORM maps use linear R/G/B for occlusion, roughness and metallic; G/B multiply
the layer factors. Missing maps preserve those factors. Triplanar projection samples
terrain-local ZY/XZ/XY planes and blends by the local surface normal, reducing
stretching on cliffs. Its normal-map blend preserves the geometric baseline,
including ridges and mixed planar/triplanar layers under nonuniform owner scale.
Optional `blendHeightPath` maps use linear red-channel heights from black (low)
to white (high). Their bounded influence favors raised details in material
transitions while preserving equal-height proportions and fading layers smoothly
to zero. Height samples share all UV flips, rotations, mip filtering and projection
with the other maps. Missing or invalid height maps warn and remain neutral;
without height maps, the ordinary automatic-rule blend stays unchanged.

`TerrainLayerReference.variation` stores opt-in `TerrainTextureVariation` controls:
a full `UInt64` seed, U/V flips, quarter-turns, offsets, variation cell size and
low-frequency macro strength/scale. Missing settings default to disabled. Cell
size accepts 0.25...64 texture repetitions and macro strength accepts 0...1;
macro scale is positive terrain-local units. Both native save modes preserve these
settings. Enable variation to randomize flips, quarter-turns and offsets from the
terrain-local coordinates, stable layer ID and seed. Neighbor samples blend
smoothly; the same transforms apply to all maps, gradients and tangent normals.
Moving the owner and camera together preserves the pattern. Macro variation adds
seeded low-frequency albedo modulation; disabled variation preserves the ordinary
single-sample texture path. Scales below the shader coordinate range use filtered
fallbacks: unresolved layer sampling reads the coarsest prepared mip, while
unresolved macro modulation averages to its neutral value. Material-field uploads
require a finite reciprocal sample spacing; an unsupported spacing reports a load
error before publication and retains the previous working generation.

`TerrainHeightStorage` is a separate data API for sparse regions. It uses signed
region coordinates, 256 cells per region and 64 cells per tile. Allocate a surface
explicitly with `allocateRegion(at:)`, then edit its canonical samples with
`setHeight(_:at:)`. Missing surfaces return `nil` from height queries. The default
64 MiB budget covers allocated height pages; mesh snapshots and GPU resources need
separate budgets. Flat regions do not allocate height pages until a nonzero edit.

Use `snapshot(of:)` to obtain immutable tile geometry and `tileRevision(at:)` to
detect affected tiles. Shared border samples have one owner. Normals sample across
borders, so an edit can invalidate adjacent tiles. `takeDirtyTiles(limit:)` drains
a bounded batch from a single-consumer queue; independent consumers should inspect
the storage and tile revisions. The queue holds at most 65,536 distinct pending
addresses. Removed-tile history can exceed that bound even when no terrain remains.
Check `dirtyOverflowGeneration` before and after draining: if it changed since your
last successful synchronization, discard your derived tile set and rebuild it from
`tileCoordinates`. An overflow discards earlier queue entries; height data remain
unchanged. Source-managed runtime data use revisions rather than this FIFO. `init(importing:)` preserves a legacy patch's
positions, sample spacing and partial edge tiles.

`TerrainRegionAsset` stores independently loadable height pages in `.atregion`
files. Version 1 starts with the eight-byte signature `ADATRN01`, signed little-endian
32-bit region X/Z coordinates, and two unsigned 32-bit counts. Up to 16 four-byte
tile records contain local X/Z and cell counts. Up to 16 page records contain local
X/Z, two zero reserved bytes and 4,096 little-endian R32F samples. Pages own samples
by integer grid address rather than duplicating neighbors' borders. The positive
grid boundary permits data-only pages. Decoding rejects unsupported versions,
invalid dimensions or addresses, duplicate records, nonfinite heights and mismatched
byte lengths. `encodedData()` validates in-memory records before encoding.

Region assets with artist-authored surface channels use `ADATRN03`. Sparse
`surface` records retain up to four stable layer IDs and normalized weights,
an explicit `overrideStrength`, tint and roughness overrides. `ruleMasks` store
nonzero values by mask ID; absence means zero. Values use little-endian Float32
without requantization on save. These optional sections coexist with heights and
placements; files without surface channels retain their earlier encoding. The
codec rejects duplicate coordinates/IDs, invalid weights, reserved bytes, unbounded
counts and payloads above 8 MiB before allocating record arrays. These data types
provide persistence. A material-palette source resolves saved rule masks and layer
paint into its full-resolution fields. Manual weights blend with the automatic
result by `overrideStrength`; zero override reveals the rules. Active painted IDs
must exist in the palette or publication fails with a diagnostic. `tintStrength`
mixes white toward the saved RGB tint, then multiplies the resolved layer color.
`roughnessStrength` blends the resolved roughness toward the saved value. These
canonical fields retain their full resolution across visual LOD changes; unpainted
tiles share a neutral fallback. Runtime edits and brushes use the atomic authoring path
described below; native Studio controls remain in development.
`TerrainRegionCache.Limits.maximumResidentSurfaceBytes` separately bounds decoded
paint/mask records (32 MiB by default); it does not consume the height-page or
placement allowances. Canonical `TerrainHeightStorage` has its own
`surfaceMemoryBudgetBytes` allowance (32 MiB by default), conservatively charging
sparse hash tables and COW staging. `statistics.residentSurfaceBytes` reports the cache charge,
and eviction releases that allowance. A rejected load retains the resident generation.
Canonical pages also retain exact tint/roughness coverage metadata, so moving the
camera or changing LOD does not repeatedly walk unchanged layer-paint records.

Shared palette images initialize over multiple updates, submitting at most 1 MiB
per source per update. Array slices and mip levels stay private until the complete
palette is ready; a replacement retains the previously published surface meanwhile.
Tile meshes, canonical material fields and collision preparation use the separate
`maximumTileUpdatesPerFrame` allowance. Completed arrays are shared across tiles
and retained across idle frames and visual LOD changes.

Terrain layer shading uses the raster PBR pipeline. When a view requests the
experimental portable path tracer, layered terrain selects the existing raster
fallback for that view and records the reason in `Render3DPathTracingStatistics`.
Its layer colors, maps and manual fields remain visible. Ordinary PBR meshes and
terrain without a layer palette keep their existing tracing behavior.

For a region-file round trip, enumerate `resourceCoordinates` and call
`regionAsset(at:)` for each address, then encode its returned asset. This list
includes canonical data-only regions that `regionCoordinates` omits. Keep them
when saving: a shared border may be stored there. Restore a set of loaded
`TerrainRegionAsset` values with `TerrainHeightStorage(regions:spacing:origin:)`,
using the original spacing and origin. Restore validates every payload, rejects
duplicate region addresses and checks the total resident height-page budget.
It preserves partial tiles and queues their initial geometry generation.
Capturing individual regions during concurrent edits does not form an atomic
whole-terrain save; stop edits while collecting that set.

`TerrainManifestAsset` describes spacing, `originX`, `originZ` and a table of
`TerrainRegionReference` values in a portable `.aterrain` JSON resource. Each entry
contains signed X/Z coordinates and `fileName`, a basename beside the manifest.
Version 1 accepts at most 16,384 entries and 4 MiB of encoded input. File names must
start with an ASCII letter or digit, use letters, digits, dots, hyphens or underscores,
end in `.atregion` and fit within 128 bytes. Paths, URI references and percent escapes
are rejected. Region addresses and file names must be unique; filename comparisons
ignore case for portability. Unknown versions and invalid spacing/origins throw.
The decoder checks the table count before constructing its reference array.

Native tools can persist a complete immutable region set with
`AssetsManager.saveTerrainRegions(_:manifest:at:mode:maximumStagedBytes:onProgress:)`.
Pass the previous layout manifest and all region assets. Changed regions receive
new, uniquely named files beside the destination `.aterrain`. Byte-identical regions
retain their previous filenames and references after a bounded comparison; symbolic
links are not reused. Capture the whole region set while edits are stopped.
An omitted `.aterrain` extension is appended and included in the returned asset's
reload path. The default 128 MiB staging budget includes
all encoded regions and the manifest. Validation and budget checks happen before
creating files. Progress reports completed region writes; cancellation is checked
between writes and immediately before the manifest commit.
Progress callbacks are asynchronous and may await a UI actor update. Only one save
to a given manifest can run in a process. An overlapping call throws
`TerrainSaveError.saveInProgress`; retry after the active operation completes.
The reservation is released on success, failure and cancellation.

For streamed terrain, pass `mode: .update(removing: [])` and only the changed
region assets. Untouched manifest references remain present without reading their
payloads; the staging budget covers the supplied payloads and resulting manifest.
Pass exact prior `TerrainRegionReference` values in `removing` to delete regions.
Duplicate, mismatched or simultaneously replaced removals throw
`TerrainSaveError.invalidRemoval`. The omitted-mode default replaces the complete
set, so callers must explicitly choose incremental mode for a partial snapshot.

Incremental saves require an existing destination matching the supplied baseline.
The writer checks that generation before staging and again before publication;
a mismatch throws `TerrainSaveError.staleManifest` and discards unpublished files.
The in-process reservation serializes engine saves to the same path. This is not a
cross-process lock: independent tools must coordinate their own simultaneous writes.
Retain the returned manifest as the baseline for the next save.

The writer flushes each file, stages the manifest beside its destination and
replaces it without deleting the previous manifest first. A failed or cancelled
operation removes its completed unpublished files and leaves the previous manifest
readable. A successful commit returns its published generation even if cancellation
arrives afterward. Previous generation files stay available to existing readers;
automatic collection of those files is not yet provided. Use the returned manifest
or load the destination with `AssetsManager.loadFresh` to observe the new version.
Saving through this API is native-only; WASM consumers can load exported resources.
The commit uses the native same-directory rename operation on Windows and POSIX
hosts. A focused Linux filesystem test exercises the actual codecs and writer;
complete package, renderer and Studio platform validation remain separate checks.

`TerrainRegionCache.open(manifestAt:limits:)` opens an immutable manifest generation
and loads individual regions with `loadRegion(at:)`. A coordinate absent from the
manifest returns `nil`; a declared resource that is missing, malformed or has the
wrong coordinate throws. Loaded values remain resident until explicit eviction,
even if the underlying file is later modified. This keeps a running generation
consistent. Evict and reload to observe a changed file.
The cache captures its originating app-world asset scope. A request made from
another world retains that scope rather than resolving the same virtual filename
under the requesting world's resource directory.

Cache limits default to 64 MiB of decoded Float height pages, 128 resident regions
and four concurrent loads. Region count bounds metadata separately; encoded input
and decoder temporaries are bounded by the resource format and load count. Returned
values retained by callers, mesh snapshots and GPU resources have separate lifetimes
and budgets. Failed admission preserves existing resident values. Use `statistics`
to inspect resident regions, height bytes and active loads.

Pin a region with `.dirty`, `.selected`, `.transaction` or `.physics` to prevent
`evictRegion(at:)` from releasing it. Each reason must be unpinned independently.
The cache provides explicit residency controls. `Terrain3DSource` uses it to stage
camera and physics region residency.

For render-only heightfield LOD, call `snapshot.meshLOD(level:finerEdges:)` with a
level from 0 through 6. A full 64-cell tile reduces from 4,225 vertices at level 0
to 1,089 at level 1 without stitched edges. Samples retain their canonical positions,
normals and UVs. Continue using the full snapshot for collision and editing queries.

Adjacent levels must differ by at most one. On the coarse tile, mark each boundary
with a finer neighbor using `TerrainLODEdges.minX`, `.maxX`, `.minZ` or `.maxZ`.
The coarse mesh explicitly includes the finer boundary samples. Center fans handle
corners, preserving complete upward-facing coverage without degenerate triangles
or unmatched border vertices. Partial tiles retain level 0, and their adjoining
tiles must also stay at full detail. This API builds geometry independently of the
runtime camera policy.
`TerrainLODBalancer.select(proposed:fullDetailTiles:partialTiles:)` refines proposed
levels until edge neighbors differ by at most one, then returns each tile's level
and finer-neighbor mask. Requested detail is never coarsened. Full-detail pins stay
at level 0; partial tiles also force adjoining tiles to level 0. Disconnected tiles
retain their own proposals, and the result does not depend on dictionary ordering.
Inputs are limited to 65,536 tiles and validated grid coordinates before traversal.

To render a saved manifest, attach `Terrain3DSource` to an entity in a world with
`Model3DPlugin`:

```swift
world.spawn("Landscape") {
    Transform()
    Terrain3DSource(source: "@res://Terrain/world.aterrain")
}
```

The system loads nearby manifest regions within explicit limits, prepares tile
geometry and creates generated children. Defaults allow 64 MiB of canonical
height pages, 128 regions and 128 MiB of conservatively estimated mesh data.
`streamingRadius` defaults to 384 terrain-local X/Z units around active cameras.
Set it to `nil` to load the complete declared set within limits. With no usable
active cameras or physical interests, the conservative fallback also requests the
complete set.

Residency includes neighboring declared resources for canonical border heights
and normal coverage, so the region count includes this halo. Halo topology does
not create visible meshes or make height queries report an unloaded surface.
Changing camera regions stages a replacement, retains unaffected tile generations
and releases distant generated meshes while preserving the runtime storage object.
The manifest generation and its originating asset scope remain stable across moves.

Local edits retain region overrides across residency changes. Those data remain
pinned within the same height/count budgets; if the requested set cannot fit, the
previous valid surface remains available and status reports the admission error.
New geometry and collision are prepared before committing the staged storage.
A revision check prevents staging from discarding an intervening author edit.
Changing the region or height budget stages against those same live edits instead
of reloading the original files. An accepted height-budget change updates the
existing storage object; a rejected change retains its last valid budget and data.
Staging may retain both old and new page generations, each within the configured
page budget; metadata, CPU mesh descriptors and GPU allocations have separate costs.

`Terrain3DSourceSurface.storage` exposes the loaded height storage for local edits
and queries. The system watches tile revisions and retains unaffected mesh buffers.
Source-owned storage uses revision tracking instead of the standalone storage's
single-consumer dirty FIFO.
`Terrain3DSourceStatus` reports readiness, generated tile count and load/build errors.
A failed source replacement keeps the last working geometry and collision. Its
retained collision continues to follow valid parent/owner transform changes using
the same incremental preparation budget. Admission failure preserves the published
visual LOD and mesh buffers while recovery updates changed samples and collision. Change
the source or increment `reloadGeneration` to retry a failed load. Local storage
edits update the retained generation without silently adopting a repaired file;
the error remains visible until a successful explicit retry. Camera/transform
updates also preserve that failed request, including when no generation has loaded
yet; they do not repeatedly read the same missing resource. Emptying the path
clears generated geometry, and removing the component also clears transient state,
including a pending height request and its completion status. Ordinary authored
children remain; only generated terrain children are removed.

For a bounded height change, attach `Terrain3DHeightEdit` to the loaded source owner:

```swift
@MainActor
func raiseGround(_ owner: Entity) {
    guard let surface = owner.components[Terrain3DSourceSurface.self] else { return }
    let edit = Terrain3DHeightEdit(
        storage: surface.storage,
        updates: [.init(point: .init(x: 64, z: 64), height: 5)]
    )
    owner.components[Terrain3DHeightEdit.self] = edit
}
```

The request captures the storage identity and revision. It accepts at most 65,536
unique sample addresses on resident surfaces. Nonfinite heights, duplicate/missing
samples, insufficient page budgets and stale requests fail without changing live
samples or mesh buffers. Observe `Terrain3DHeightEditStatus` and match its `id` to
your request. Invalid edits report a separate error while preserving the working
source's readiness. Residency, collision, LOD and memory settings must already be
published before capturing a height edit. Changing those settings rejects the edit
and lets the normal source pipeline admit the new settings or report their error;
resubmit after it finishes. Color and the per-frame upload budget do not invalidate
residency admission. An applied result contains a compact `TerrainEditDelta`.
For each Undo command submit `Terrain3DEdit(storage: storage, undoing: delta)` at
the current revision. The result is itself reversible for Redo. This restores exact
placement channels together with heights; `reversedUpdates` contains heights only.
An unchanged request produces an empty delta rather than a new data revision.

Preparation copies metadata once and copies touched Float pages on write. It checks
the final page count before allocating; a batch can free one complete page and
allocate another within the same budget. The live storage object stays unchanged
while the replacement tile meshes and collision resources are prepared. Removing
the request before publication cancels its prepared work and preserves the live
generation. Direct `setHeight` remains an immediate low-level data API; use edit
requests when preparing a coherent scene replacement. A ready result exposes its
native collision immediately, including Undo, without waiting for a later physics
tick. `physicsWorld3D.collisionPreparationMetrics.snapshot` exposes cumulative
successful native BVH creations and their triangle count. Compare snapshots around
an update to inspect real collision preparation rather than generated-child counts.
Runtime height changes are not automatically written to asset files; save
resource data separately through the terrain persistence API. Scene files retain
the source reference.

With `Physics3DPlugin`, colliders use full-detail triangles and include the owner's
parent transforms, rotation and reflected scale. Geometry and collision replacements
are prepared before world changes are published. Changing color retains geometry;
changing transforms retains visible mesh buffers and rebuilds world-space colliders.
The runtime selects stitched render levels from the nearest active camera's distance
to each tile in terrain-local X/Z. `lodDistance` defaults to 128 units; subsequent
boundaries double. `maximumLOD` defaults to 6, and setting it to 0 keeps full detail.
A 15% hysteresis band avoids buffer replacement from small boundary oscillations.
Camera parent transforms are included. Multiple cameras retain the detail required
by the nearest one; with no active camera or more than 16 active cameras, the
conservative fallback is full detail. Partial tiles and their neighbors remain at
full detail. Collision and queries always use canonical samples, including narrow
features that disappear from a distant visual mesh.

This initial runtime retains canonical CPU descriptors for resident collision and
pose updates, and its mesh budget uses a conservative full-tile bound. LOD reduces
draw geometry, while camera and physics residency control the retained region set.
Dynamic and kinematic bodies request terrain around their complete collision bounds;
character controllers request their capsules, including requested height changes.
The margin `physicsPadding` defaults to 64 terrain-local units. Swept interests
include at least a quarter-second of motion (or the fixed tick if longer), including
rigid-body gravity and the character's possible downward motion. Rotating bodies
receive conservative rotation coverage. Sleeping rigid bodies retain their ground. More than 64 distinct
physical interests conservatively request all declared terrain instead of dropping
actors from residency planning.

`Physics3DPlugin` installs `PhysicsSimulationGate3D`. If collision-enabled terrain
cannot admit its requested data while physical actors are present, rigid simulation
and character movement wait. The source status reports the error; successful
publication resumes movement. Removing a source or despawning its owner releases
its hold. Other providers' hold reasons remain independent. Ray queries may still
inspect the last valid collision generation while movement waits.

After body synchronization, terrain rechecks physical coverage before each fixed
step. A character teleported by a script after `preUpdate` waits until the new region
is resident. The check also verifies source/data revisions, owner transforms and
native collider initialization. It resumes after coherent publication; independent
owner/reason holds remain active until their own provider releases them.

Region reads and CPU meshing run in owned background tasks. At most two sources
prepare concurrently, including completed CPU jobs awaiting GPU publication.
Waiting sources enter a FIFO queue so repeated camera updates cannot indefinitely
occupy both preparation slots ahead of another terrain.
`maximumTileUpdatesPerFrame` defaults to 4 and accepts 1 through 64; it limits tile
mesh uploads and actual native collision tree preparation in each frame. Prepared
immutable collision data are reused when the completed generation activates its
bodies, so final publication does not recook all tiles. Prepared children stay hidden
until the complete replacement can publish together. `Terrain3DSourceStatus` reports
`isPreparing`, `preparedTileCount` and `pendingTileCount` while the last valid
generation remains available. Changing the source or removing its owner cancels
pending work. Revision checks reject results superseded by local edits. Camera
motion can finish an already prepared generation before requesting its next view,
so continuous navigation does not repeatedly discard useful work.
Native Studio exposes source sculpting, material import/painting, mesh instancing and seeded height generation in a terrain dock below the viewport. Height, surface and placement strokes publish asynchronous batches while dragging and save one private resource version through ordinary scene history. A visible surface ring follows the brush; Escape restores the previous resource. Attaching `Terrain3D` continues to use the compatible legacy patch described above.

Terrain resource loaders can bound encoded input before decoding by declaring
`static var maximumEncodedBytes: Int?` on their `Asset` type. The default is `nil`.
Native loads check the file size and read bounded chunks, including a check for
files that grow while being read. Browser loads consume the response stream and
reject a chunk that would exceed the limit. The limit also applies during hot reload;
decoders still need their own validation of counts, coordinates and numeric values.

## Runtime height brushes

`TerrainHeightBrushSettings` selects raise, lower, smooth, flatten, set height,
ramp, terrace, seeded noise or bounded local talus relaxation. Supply settings and
terrain-local `TerrainBrushPoint` events to `TerrainHeightBrushStroke`, then attach
`Terrain3DHeightEdit(storage:brush:)`. Completion and inverse Undo use the same
height-edit status and delta as explicit sample updates.

Raise, lower, smooth, flatten and talus sample time at fixed intervals, scaling
by elapsed seconds and optional pressure. Stamp operations use deterministic path
distance spacing. Flatten defaults to the surface height at stroke start. Set height
requires `targetHeight`; ramps interpolate the first/last input heights. Terraces
use `terraceStep` and an optional height offset. Noise uses the seed and canonical
sample coordinates. Talus has explicit iteration and angle controls.

The worker reads an immutable input generation and publishes one complete delta;
invalid settings or excessive work retain the previous surface. At most 4096 input
points/dabs and 65536 affected samples are accepted, with a separate sample-visit
budget. Work preflight counts both dab supports and scans over their union, including
local stencil reads. Rotated square/alpha/ridge bounds follow the rotated support.
Slope masks share the renderer's one-sided and normal-halo derivatives. Brush updates
plan and load their complete declared footprint into a private editing view before
application, including normal-only and unloaded neighboring regions. The original
visible tile set is restored before publication. Missing payloads or insufficient
residency reject the whole gesture without changing visible geometry.

Shapes include soft/hard round, square, ridge, a signed crater mask, ridged noise and
a bounded grayscale alpha. `TerrainBrushAlpha` accepts up to 1024 Ã— 1024 bytes and
validates dimensions/counts before decoding pixels. Rotation/jitter and height/slope
ranges belong to settings. Studio brush controls, named presets and imported-image
handling are not connected to this resource path yet.

## Runtime surface brushes

`TerrainSurfaceBrushSettings` selects `paintLayer`, `eraseLayer`, `paintMask`,
`paintTint`, `eraseTint`, `paintRoughness` or `eraseRoughness`. Submit its stroke to
the loaded source owner, using the source's `Terrain3DSourceSurface.storage` and
terrain-local input points. The target layer must exist in its material palette.

```swift
func paintTerrainPath(owner: Entity, storage: TerrainHeightStorage, points: [TerrainBrushPoint]) {
    var settings = TerrainSurfaceBrushSettings(operation: .paintLayer, radius: 4, strength: 0.3)
    settings.layerID = 12 // A stable layer ID declared in this source's palette.
    settings.shape = .softRound
    settings.spacing = 0.25
    owner.components[Terrain3DEdit.self] = .init(
        storage: storage,
        brush: TerrainSurfaceBrushStroke(settings: settings, points: points)
    )
}
```

Strength is coverage per distance-spaced dab, between zero and one. Rotation,
seeded jitter, pressure, procedural shapes, grayscale alpha, height and slope masks
use the sculpt brush conventions. Event duration does not multiply surface opacity.
Overlapping dabs accumulate coverage; layer painting retains the strongest four
stable IDs and normalizes their weights. Erasing the layer override reveals the
automatic rules while retaining separately painted tint and roughness.

For `paintMask`, set `maskID` and `maskValue`; a target value of zero erases that
automatic-rule mask. Tint and roughness brushes affect only their own channels.
The original surface supplies height/slope filters throughout the gesture.
Planning bounds dabs, canonical samples and work before hydration, and the complete
result must fit resident storage and native region limits before publication.

One gesture publishes one revision and compact `TerrainEditDelta` changes. Read
`Terrain3DEditStatus` and create `Terrain3DEdit(storage:undoing:)` from an applied
delta for exact Undo. Removing the request before publication cancels it. Direct
`TerrainSurfaceUpdate` and `TerrainRuleMaskUpdate` arrays can also accompany height
updates in one `Terrain3DEdit`. Material-only changes retain unchanged mesh buffers
and collision; sculpted geometry and LOD transitions continue to rebuild as needed.
Use `Terrain3DSave` to persist the committed channels with heights and placements.

## Saving runtime edits

After a height edit has published, attach `Terrain3DSave(storage:)` to its source
owner. `Terrain3DSaveStatus` reports `pending`, `saved`, `failed` or `cancelled`, plus
the saved revision or error. The default 128 MiB encoded staging budget can be
reduced. An optional asynchronous `onProgress` callback receives completed and
total region writes. Native writable projects support this operation; browser
saving remains unavailable.

The operation captures changed resident data and hidden dirty regions, restoring
each hidden region's authored tile layout. It uses incremental persistence, so
unloaded references survive without loading their payloads. Successful publication
adopts a new immutable reader and releases only data matching the committed
snapshot from dirty residency. Later edits remain unsaved. Saving itself preserves
the surface object and visible mesh buffers; normal edits and streaming can continue
publishing their own changes while the immutable snapshot writes.

At most two filesystem snapshots run per source system, including cancelled tasks
waiting for their final result. Additional requests wait in FIFO order. If an
uncaptured queued request must yield to residency or geometry work, it fails busy;
retry after publication. A request captured before its current heights are published
also fails busy. Changing the source URI/reload generation or removing the request
cancels an unpublished save. Pose, camera, physics and newer height changes allow
the existing snapshot to finish. A commit that already succeeded reports `saved`;
its status includes the captured revision, which may precede later edits.

A stale disk manifest fails explicitly while retaining local data and geometry.
Saving a scene persists its terrain URI; save terrain edits separately before
closing or exporting that scene.

An in-flight transaction pins its canonical regions through normal residency
admission. Camera or physics requests that cannot fit those pages plus their new
regions fail without evicting the transaction's data. Saving the captured snapshot
releases its transaction pins, while newer unsaved data remain dirty. A one-page
working set can therefore refuse a second nonzero region until the newer Undo is
also saved or its data are otherwise released.

## Shared mesh placements

`Mesh3DInstancesComponent` is the initial shared-mesh runtime path for spatial cells.
It takes one mesh/material table and an array of `Mesh3DInstance` records with stable
IDs, local transforms and tint. The owner/parent transform applies to every record.
Extraction keeps one render source per component and compatible materials share
instanced draws. It does not create an authored scene entity for each placement.

`TerrainMeshPrototype` prepares a selected scene from a `ModelAsset3D`. It retains
all active mesh nodes, every primitive and the shared material table. Imported
parent/rest-pose transforms are composed after each placement, beneath the terrain
owner. Mesh buffers and materials are reused.

```swift
let prototype = try TerrainMeshPrototype(model: importedModel)
let batches = try prototype.makeBatches(instances: placements)
for batch in batches {
    let child = world.spawn("Terrain model batch") {
        Transform()
        batch
    }
    terrain.addChild(child)
}
```

Run this setup after the renderer is ready, in the scene's normal world-mutation
context. Keep placement IDs stable when moving or reordering records. Update the
existing batch components when placements change; preparing them is not a per-frame
operation. This runtime example does not save placement records into a terrain asset.

Preparation accepts static indexed triangle geometry with standard position,
normal, UV, tangent and color streams. Animation, skinning/joint streams and morph
targets require ordinary model entities. Invalid hierarchies, missing materials,
nonfinite/noninvertible transforms, invalid vertex/index data and transformed-bound
overflow throw `TerrainMeshPrototypeError`. The glTF import path also validates
attribute cardinality and indexed vertex references before GPU upload.

A model is limited to 4096 nodes, 64 draw parts and 256 materials. Geometry
preflight allows 1048576 vertices and 6291456 indices across its unique active
meshes. A cell allows at most 65536 placements and 262144 placement/part pairs.
`maximumExpandedBytes` covers expanded CPU placement records, with a 64 MiB
default and 128 MiB hard cap; shared source assets and renderer pass buffers have
additional costs. Tints use normalized RGBA values. Negative scales are supported
when the resulting transform and mesh bounds remain finite and invertible.

The forward/shadow lists consume placement transforms. Portable tracing has a
131072-placement/input-triangle work budget and a 262144-material-packet cap;
line, point, empty and cosmetic-only parts do not expand. It transforms referenced
vertices only. These limits do not establish the decorative-instance benchmark.
Region assets now preserve stable placement records in a versioned binary section.
Records retain compact rotation, tint and attachment-normal channels without repeated
quantization on save. Height-only files retain their original encoding. Residency
and saves preserve records in hidden dirty regions, including placement-only resource
removal. Decoded placement rows have an independent 16 MiB default storage/cache
budget; expanded draw records and renderer buffers have separate costs. A manifest's `meshPrototypes` table assigns stable `UInt16` IDs to static model
paths relative to the manifest directory. It also selects an optional imported
scene and world-space draw distance. Nonempty palettes use manifest version two;
empty palettes keep version one. Both save modes preserve model references.

Source loading creates one shared batch per imported mesh node, prototype and
64-cell placement group. Region streaming removes inactive draw cells. Existing
cells retain their entities and shared buffers through unrelated height edits.
A failed source replacement preserves the previous valid generation.

For example, save an unanchored decorative placement in a native writable project:

```swift
let layout = TerrainManifestAsset(meshPrototypes: [
    .init(id: 17, assetPath: "Models/rock.glb", maximumDistance: 500),
])
let rock = try TerrainRegionInstance(
    id: 1, prototypeID: 17, localPosition: [10, 0, 10], flags: []
)
let region = TerrainRegionAsset(
    x: 0, z: 0, tiles: [], pages: [], instances: [rock]
)
try await AssetsManager.saveTerrainRegions(
    [region], manifest: layout, at: terrainURL.path
)
```

The model must exist at `Models/rock.glb` relative to `terrainURL`. Attach
`Terrain3DSource(source: terrainURL.path)` to the terrain owner after saving.
Placement position and vertical offset use base-cell units; X/Z include the
region's 256-cell offset and terrain origin, while model scale remains a model
transform. Sculpt commands now move nearby anchored placements with the edited surface and
align their orientation when requested. Unanchored/distant rows remain unchanged.
Attachment queries include canonical halo coverage without exposing hidden draw
tiles. Local yaw is recovered against a canonical normal frame, so many small
slope edits do not lose tilt through repeated quaternion quantization. A gesture
visits at most 262144 nearby records. Its delta retains previous/current placement
rows for exact combined Undo/Redo, preserving quantized channels across repeated
history steps. `Terrain3DEdit`, `Terrain3DEditStatus` and `TerrainEditDelta` are general
aliases for the original height-edit spellings.

Explicit placement gestures use `Terrain3DEdit(storage:instances:)` with
`TerrainInstanceCellChange` entries. Each entry addresses one 64-cell spatial group
and includes its expected previous rows and desired rows. The worker validates
unique cells, record membership, stable IDs, stale input, decoded budgets and the
65536-record limit per region before publication. A gesture permits at most 65536
cells and 262144 previous/desired row visits. Saving includes these placement edits.
Declared regions must have a complete loaded baseline before explicit cell replacement;
an unloaded declaration is not interpreted as an empty cell. Newly addressed regions,
including canonical height pages across an outer edge/corner, pass region admission
before publication. Loaded baselines survive adoption of a new save reader.

Native Studio's separate Mesh Instancing toolbar button opens its terrain dock. Import a self-contained GLB or VOX, select its palette entry, then paint or erase shared instances. The runtime paint/erase request path below authors the same saved placements. Actual backend pixels and the 100k-instance benchmark remain required
before the feature is complete.

## Runtime mesh brushes

`TerrainInstanceBrushSettings` selects paint or erase and a stable mesh palette ID.
Submit a `TerrainInstanceBrushStroke` through `Terrain3DEdit(storage:brush:)` on the
terrain source owner. The general edit/status/delta names alias the existing height
request types; saves and exact inverse Undo share the same atomic publication path.

```swift
var settings = TerrainInstanceBrushSettings(prototypeID: 17, radius: 8, density: 2)
settings.minimumDistance = 1.5
settings.scaleRange = 0.8...1.2
settings.heightRange = 0...100
settings.slopeRange = 0...35
settings.seed = 42
terrain.components[Terrain3DEdit.self] = .init(
    storage: surface.storage,
    brush: TerrainInstanceBrushStroke(settings: settings, points: gesturePoints)
)
```

Density is the requested placements per square terrain-local unit before spacing and
surface masks. Minimum distance applies to placements of the selected prototype,
including existing nearby rows. A jittered deterministic lattice provides stable
candidate IDs and random scale/yaw; changing its physical scale selects a distinct
candidate lattice. Repeating the same paint request leaves accepted records
unchanged, and subdividing a straight input segment preserves its result. Terrain
owner transforms apply after local authoring, as for sculpt brushes.

The brush supports the existing soft/hard round, square, ridge, crater, noise and
alpha masks, rotation/jitter, pressure, tint, height offset and height/slope filters.
Painted records anchor to the sampled surface and can align their up axis with the
surface normal. Sculpt edits reproject those anchors. Erase removes covered records
from the selected prototype, or every prototype with `eraseAllPrototypes`; inverse
history restores exact row order, IDs and compact transforms.

Set `materialLayerID` to a registered stable layer ID and `minimumMaterialWeight`
to a value in 0...1 to restrict paint or erase to that layer's contribution. The
default threshold is .5; zero accepts any positive contribution. Leave the ID
unset to disable this filter. The brush resolves automatic height/slope/curvature,
noise, rule masks and painted overrides at canonical samples, then interpolates
the selected layer's weights. Missing layer IDs reject the gesture without
changing placements or geometry. This uses layer weights, not texture color.
Each gesture caches at most 65536 canonical filter samples and charges sample
and rule evaluations to its existing work budget. Unfiltered brushes do not
allocate this material cache.

Planning loads the complete declared gesture footprint into a private editing
view, including unloaded height/placement regions and a normal halo. Extra query
tiles do not become visible render tiles. Unknown declared payloads, missing models,
invalid settings, cancellation or exceeded budgets retain the published generation.
There are at most 262144 candidate lattice cells and 1048576 counted work visits
per planning/evaluation stage;
bounds searches, mask evaluations and spacing comparisons all count. Placement and
resident resource limits also apply. Native Studio brush controls remain pending.

## Nearby placement collision

Decorative placements have no collision. Set `TerrainInstanceFlags.collision` on
explicit records, or `settings.requestsCollision = true` before painting, to request
static triangle collision near active cameras and physical bodies. The flag is saved
with each placement and follows exact placement Undo/Redo.

`Terrain3DSource.instanceCollision` controls this mode. Its defaults are a horizontal
distance of 64 terrain-local units, at most 128 colliders, a conservative 32 MiB
geometry/native-tree allowance, and four native preparations per update. Count is
limited to 1024 and per-update preparations to 64. Selection uses transformed model
bounds and stable placement IDs to break equal-distance ties. Count limits can omit
nearby placements; use suitable limits for gameplay obstacles. Setting the count to
zero disables placement collision. `generatesCollision = false` disables both the
base surface and placement collision.

The placement preparation budget is separate from the height tile update budget.
All selected shapes are prepared before their generation publishes. Cancelled or
rejected preparations retain the last published collision; unchanged selections
reuse their entities and native trees. Camera/body movement releases distant props
and prepares newly selected ones. Full parent transforms, including reflections,
apply to collision as well as rendering. The physics readiness gate waits when
movement requests selected prop collision that has not published yet.

`Terrain3DSourceStatus.instanceColliderCount` reports the published count, including
while a replacement is pending. Use the physics world's existing preparation metrics
to measure actual native BVH work. Selection visits at most 262144 flagged candidates;
decorative-only cells retain no collision candidate rows. Exceeding candidate or
geometry budgets reports an error rather than partially publishing collision.
If more than 16 active cameras exceed the bounded camera collector, collision
selection conservatively considers all loaded flagged props, within the same
count, memory and work limits.

## Measuring large placement scenes

`Render3DGPUTests.Benchmarks.terrainHundredThousandInstances` loads two native
regions containing 100000 decorative placements, renders spatial batches and
then compares one entity per placement using the same shared assets. It verifies
identical pixels and records actual camera draw counts, runtime entity count,
placement storage and frame wall time. Windows also records process CPU time, working set
and committed bytes. Process CPU includes worker threads. These figures include the renderer, caches and test
harness; they are not exclusive placement allocations.

Run an optimized build with `ADAENGINE_PERF=1`, the applicable golden backend
enabled, and `swift test -c release -Xswiftc -enable-testing --filter
terrainHundredThousandInstances`. Use `ADAENGINE_PERF_FRAMES` to select the measured
frame count and `ADAENGINE_TERRAIN_PERF_OUTPUT` for a JSON result file. Run on a
quiet machine and compare results on the same hardware. Timing includes a final
readback to wait for submitted GPU work; it is not a per-pass GPU timestamp or
a universal frame-rate promise. This fixture uses warmed albedo view rather than
full shaded gameplay; keep that distinction when reporting its results.

## Solid geometry preparation

The renderer-neutral Math module provides bounded scalar geometry for tools that prepare
solid operations. `ScalarSolid` evaluates spheres, boxes and capsules under a finite,
invertible affine transform, including reflection, nonuniform scale and shear.
`ScalarMeshSolid` validates a closed static triangle mesh, welds exact duplicate positions
at attribute seams and evaluates concave membership with nearest-surface distance.
Open or nonmanifold edges/vertices, inconsistent winding, degenerate faces and intersecting
faces are errors. Mesh preparation accepts at most 65,536 triangles and 196,608 source
vertices, with explicit validation and query work budgets. Cancellation and exhausted
budgets throw; callers must retain their previous valid terrain result.

Both fields are negative inside. `ScalarBooleanOperation.union` takes the minimum;
`subtract` takes the maximum of the base and negated operand. Transformed analytic values
preserve their surface but need not be exact distances after nonuniform scale/shear.
`ScalarFieldGrid` holds at most 32 cells per axis, with signed integer lattice offsets for
shared boundaries. `ScalarFieldSurface.extract` returns indexed smooth triangles and
area-weighted normals, with explicit triangle and contact-processing bounds. Neighboring
grids must select the same tetrahedral diagonal orientation. Precision
is sampled: features not captured by the chosen grid can disappear. Representable sampled
thin faces are retained, rather than removed by a fixed endpoint-snapping tolerance.

For standalone picking and proximity tools, `TriangleSurfaceIndex` builds an immutable
BVH over open or closed indexed triangles. `raycast` returns the nearest two-sided hit;
its distance uses the normalized ray direction, and its normal retains geometric winding.
`closest(to:)` returns the nearest point within the supplied distance. Hits retain the
original triangle-list index through BVH sorting. Exact shared edges remain hittable;
representable points outside an edge stay outside. Empty indices return no hit.

Construction validates referenced finite vertices, nondegenerate triangles and index
representability, with explicit triangle, conservative byte and work allowances. Unused
position-accessor rows are not copied into Double geometry. Query overloads accept a
shared `TriangleSurfaceQueryBudget` across chunks; exceeding the allowance throws rather
than returning a partially searched answer. Cancellation also throws. This Math API does
not itself attach acceleration to a scene or transform local hits into world space.

Enable `Terrain3DSource(queries: .init())` to prepare acceleration for published source
tiles. `Terrain3DSourceSurface.queries` then exposes immutable `TerrainSurfaceQueries`
with `raycast`, `closest(to:)`, revision, byte charge and per-tile generation diagnostics.
The default `queries: nil` avoids this construction and memory cost. Settings independently
bound the conservative current-generation index/staging bytes and shared construction work.
Indices build in workers, reuse geometry-equal tiles and publish with the same canonical
mesh and collision revision. Budget failure keeps the previous valid snapshot; disabling
queries drops the current acceleration while retaining render buffers.

The query snapshot follows published geometry, including cave floors, ceilings and stacked
ledges. Holding a snapshot retains its surface while the editable base changes; a completed
staged edit or Undo publishes a replacement. Unchanged save acknowledgment retains the
indices. Positions, normals and distances use terrain-local space. Transform world rays
into that space and returned positions back through the terrain hierarchy; transform
normals with the inverse transpose. Closest-point distance uses the local metric under
nonuniform scale. When comparing ray hits from different transformed entities, reconstruct
the world ray parameter from each returned world position.

`TriangleSurfaceHit.preciseDistance` retains the Double metric for ordering across tile
indices. `distance` provides the Float value for normal application use. The scene layer
compares the precise metric so distinguishable close surfaces cannot be reordered by Float
rounding. One query work allowance covers tile bounds and all visited BVH nodes/triangles.
These native CPU checks do not establish backend pixels or browser interaction behavior.

`TerrainVolumeBrickAsset` stores canonical 33-cubed density samples and stable optional
material IDs in an independently loadable `.atvolbrick` resource. Its versioned little-endian
encoding preserves Float bits and rejects malformed sizes, counts, coordinates and samples.
`TerrainVolumeDocumentAsset` stores the explicit lattice origin/cell size, ordered solid
operations and cached-brick references in `.atvolume` metadata. Operations retain UUIDs,
enabled state, full affine placement, a primitive or portable static-model source, and an
optional material layer. Validation rejects unsafe paths, duplicate identities/cache
addresses/names, invalid operands and oversized tables before resource staging. Metadata
alone does not publish a cache or commit a multi-resource save.

Native multi-resource saves use `AssetsManager.saveTerrainRegions(..., volume:)` with
`TerrainVolumeSave(document:bricks:mode:)`. The manifest uses version 4 when it references
a volume document; height-only manifests retain their previous encoding. The default
`.replaceAll` writes a complete cache; `.update(removing:)` replaces supplied addresses
and explicitly removes referenced bricks while retaining the others. Pass the current
published document and manifest as the update baseline. Unchanged payloads and canonical
cache tables retain their filenames, regardless of supplied brick order.

Height resources, changed bricks and document metadata stage before the manifest is
atomically replaced. The combined encoded-byte budget covers both height and volume data.
Cancellation or failure removes newly staged files and keeps the previous manifest and
its resources readable. Old committed generations remain on disk; this API does not
perform resource garbage collection. Saving heights without a `volume` argument preserves
and checks the referenced volume resources. These native writes require a writable local
asset directory; browser asset loading uses the separate typed asynchronous read path.

`TerrainRegionCache.loadVolumeResources()` opens the manifest's operation metadata in
the project context that opened the cache. A height-only manifest returns `nil`. The
returned `TerrainVolumeResources` keeps that context when another project requests
`loadBricks(at:maximumBytes:maximumBricks:)`. Supply signed brick coordinates from its
document; duplicate or undeclared requests and count/byte overruns fail before payload
reads. Unrequested bricks stay unloaded, including unavailable distant files. Requested
payload addresses and material tags must match the document and manifest palette.
Loading returns the complete requested array or throws; it does not install scene geometry.

Use `TerrainVolumeResources.loadPreparedMesh(operationID:maximumBytes:maximumValidationWork:)`
for an enabled static-model operation. It retains the cache's model import limits and project
context. Its per-load encoded/decoded import caps also respect `maximumBytes`. The model
bridge selects the operation's scene (or the model default), visits all active nodes and
primitives, honors rest poses and inherited affine transforms, and corrects reflected-node
winding before applying the complete operation placement. Open, deformed or otherwise
invalid solids throw. Programmatic models use `TerrainVolumePreparedMesh(operation:model:)`.

Preparation reserves retained source geometry, conservative per-index validation storage
and complete position-accessor copies, including unused imported rows and repeated scene
references. An otherwise valid operand can exceed the explicit byte or validation-work
allowance. Keep its last committed terrain generation when preparation fails; these loading
APIs do not publish replacement geometry on their own.

`TerrainVolumeField` captures an immutable COW heightfield base and applies enabled
operations in document order. Prepare static mesh operands with `TerrainVolumePreparedMesh`
so their source identity and complete placement can be checked. The field builds canonical
32-cell bricks with explicit allocation/work budgets and cancellation, and can extract their
standalone surfaces. Base density retains the heightfield's `y - height` distances;
operand contributions use a two-cell narrow band and deterministic expanded support.
Terrain extraction selects the heightfield's falling X/Z cell diagonal. Exact unchanged-base
matching requires the same sample grid or an exact aligned refinement; coarser or unaligned
grids still resample detail. Brick addresses do not change shared sample values. Mesh sampling charges a
conservative configurable query allowance. A failed build returns no partial brick.

`TerrainVolumeCache.preparing` returns a complete immutable sparse generation for requested
and pinned bricks. Unchanged local base pages and relevant operations retain their runtime
brick generation IDs; a local sculpt or source reload rebuilds affected bricks. Hidden
authored regions keep their canonical page dependencies when draw residency changes.
Count, conservative byte and shared evaluation-work limits apply before the replacement
is returned. A failed preparation leaves the previous cache available. Its byte statistics
cover one generation, including bounded sample/dependency staging; retained older generations
and render/physics resources need their own admission budgets.

`Terrain3DSource` consumes enabled operations for full 64-cell height tiles. Its initial
hybrid path requires a brick-aligned lattice origin and the same height sample spacing or
an exact aligned refinement, within the existing density/geometry work and memory bounds.
Affected tiles retain full visual detail, while the existing LOD balancer refines their
neighbors. A halo keeps edits away from ownership boundaries. Explicit one-cell transition
strips preserve the adjacent heightfield edges and conform their inner edges to the density
tessellation. Transition interpolation brackets actual canonical coordinates, which can
have uneven Float increments far from the origin. The same committed mesh descriptor supplies rendering and triangle collision;
the old heightfield mesh is replaced in owned tiles. Source preparation retains prior valid
geometry until the existing paced publication transaction is complete.
Volume source tiles interpolate central lattice gradients for consistent normals at shared
brick positions. Pure-heightfield transition edges keep their original normals. Derivative
sampling shares a per-tile work budget and its one-sample halo participates in cache dependencies.

Open `Editor/Samples/MeshTerrainWorkshop` in Ada Studio to explore the joined rock,
painted cave and procedural grass and stones. Use Play to inspect collision on the joined rock.

Native Studio's mesh tab exposes primitive or registered closed-mesh union/subtraction. Volume materials evaluate actual vertex height and normal; three-corner material fields use a separate triangle atlas while textures retain terrain-local coordinates for triplanar projection and detiling. Native collision cooking has its
own small-area precision limit; render geometry below that limit may not become collision faces.

This initial source integration is still in development: partial height tiles, volume-only
coverage outside the heightfield and cached-only/baked fallback remain incomplete. Three-dimensional manual paint storage and volumetric curvature rules are not yet equivalent to heightfield paint. Palette-bearing volume sources use an independent three-corner material field per triangle; no single X/Z field is reused for separate strata. `Terrain3DSourceSurface.storage`
continues to represent the editable heightfield base; its height query does not describe
multiple surfaces in a volume column; enable the source queries above for committed surface
picking and proximity. Complete portable export and platform acceptance remain open.

## Current limits

A heightfield has one height per X/Z position, so it cannot represent caves or
overhangs. The legacy `Terrain3D` patch supports at most 257 Ã— 257 samples.
`Terrain3DSource` supports sparse resource tiles within its configured residency
and mesh budgets, with camera-driven residency. Source palettes render rule-selected
tints and albedo maps; the legacy patch keeps its single ground color. Material
painting controls in native Studio, instance controls and volume editing remain
in development.

The tile data and headless runtime tests exercise CPU geometry and real physics
queries. They do not establish Metal/WebGPU pixel agreement or native mobile,
browser-shell and VR authoring parity; those need separate backend/runtime checks.
