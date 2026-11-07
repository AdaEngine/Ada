# Mesh Terrain Composition Implementation

Status: In progress. Design approved in the Codex conversation on 2026-11-06.
Design: [Terrain composition](../Designs/terrain-mesh-composition.md).
Implementation branch: `codex/mesh-terrain-composition`.
Workspace: `D:/Development/AdaEngine-mesh-terrain`.

## Baseline and execution rules

The implementation workspace contains an isolated copy of the original dirty
worktree at HEAD `fc3aabbfd51679884836da1c71343675f9c8624e`. Initial tracked patch,
untracked paths and file hashes are retained under `.build-tools/mesh-terrain`.
Preserve all initial changes. The separate terrain task's native brush optimizations
must be integrated deliberately; the copied baseline does not certify them.

Use the approved visual direction for the render selector and present concrete
native-control proposals for newly introduced interaction panels. Use focused
Swift Testing Red/Green cycles and production-path fixtures. Record task-owned
paths in the contribution runner as they are introduced. Reuse one task scratch
per validation package; never delete the user's shared `.build`.

The contributor explicitly requires the independent reviewer only after all
functionality is implemented. Do not launch implementation-slice reviewers.
Run independent review at the integrated-delivery boundary, fix findings, and
repeat affected checks/review. No partial slice closes the feature.

## Deliverables and acceptance boundaries

| Stage | Deliverable | Acceptance and checks | State |
| --- | --- | --- | --- |
| 1 | Geometry-kernel feasibility, adversarial fixtures, kernel ADR | True triangle union/subtraction, shared seam, transformed/concave operands, attributes, valid open-patch closure and no leaked caps; measured resource/work limits | In progress |
| 2 | Versioned mesh bases, retained modifier graph, source bindings and compiled products | Old/new and transitive bounds; stale-worker rejection; atomic transform/draw-mask/surface publication; persistence and Undo/cancel | In progress |
| 3 | Surface channels, contact materials, local detail and paint attachment | Normal/UV/provenance transfer, floor/ceiling separation, manual precedence, remesh/LOD seams and error behavior | In progress |
| 4 | Actual-surface population with manual ownership | Stable candidates, per-sheet spacing, old-footprint refill, pinned/suppressed/manual preservation, bounded local regeneration | In progress |
| 5 | Portable Wireframe and native tools | Real current triangles/meshlet selections, deformation/instances, depth occlusion, Shaded restoration, English/Russian controls and mounted UI evidence | In progress |
| 6 | Packaged example, guides, export, performance and final independent review | Every design goal G1-G10, all applicable validation, final source/asset/runtime evidence; unresolved platform checks remain blocked | In progress |

## Documentation and example delivery

Update `Editor/Documentation/Terrain.md`, navigation in
`Editor/Documentation/EditorGuide.md` and `Editor/README.md`. Extend
`Sources/AdaEngine/AdaEngine.docc/Articles/3D/Terrain.md` with runtime backends,
queries, compiled products and limitations; maintain DocC Topics navigation.
Regenerate the offline documentation catalog and run its `--check`.

Provide a reproducible native project/scene and source join assets containing a
tree/root operand, rock union, conform-only example, painted cave floor/ceiling,
generated instances, pins, suppressions and manual placements. Exercise movement,
Undo/Redo, cancellation, save/reopen, relocation, Play collision and actual exported
runtime consumption. Do not substitute source-text assertions for these paths.

## Validation

Record exact commands and Red/Green outcomes per slice in the contribution task.
Start with the narrow geometry/asset/surface/population suites, then owning and
downstream targets. Native editor tests run in the Editor package using its real
dependencies. Rendering acceptance uses real WebGPU pixels on Windows and Metal
on macOS, plus shader/Tint validation. Missing host/device/toolchain evidence is
blocked, not passed. Run applicable Linux/mobile/WASM compatibility paths and
served exported content. Profile the declared reference fixture, including p95
input/preview latency, main-thread stalls, peak bytes, changed patches/cells,
cache reuse, uploads and draw/GPU costs.

Run `check_contribution.py` at stage transitions. Final review receives the exact
task-owned diff, approved design, this plan, runtime screenshots/fixtures,
performance results and current validation reports. The original workspace is
updated only with task-owned deltas after overlap checks.

## Implementation checkpoint (2026-11-06, Windows)

The native feasibility module and retained evaluator now have 16 passing focused
geometry/index/key tests. Manifold is conditionally linked only on desktop
platforms; other players retain compiled-data types and reject unsupported authoring.
Strict-memory-safety geometry validation passes without new unsafe-use warnings.
Unused temporary closure vertices are compacted along with their faces.

The version-five manifest and bounded `.atmesh` format round-trip through a real
asset file. Compiled products carry canonical SHA-256 input keys and stale products
are rejected. A bounded authoring-session actor groups multiple drag previews into
one Undo step and restores committed geometry on cancel; its focused test passes.
The existing terrain job/publication path loads compiled mesh sections. Its runtime
fixture verifies real mesh buffers, retention after a failed reload and cleanup.
A second runtime fixture verifies a moved join, immutable old queries, restored old
ground, new surface queries and source-pose publication together.

Portable indexed-line drawing is connected to PBR vertex processing, including CPU
meshlet-cut indices. Windows/WebGPU's `portableWireframePixels` test passes for
Wireframe, Shaded + Wireframe, bounded edge-cache allocation and Shaded restoration.
Rendered images under `.build-tools/mesh-terrain/gpu-images` were inspected. These
sphere/ground frames do not establish deformation, selected-cut, terrain interaction,
Metal, packaged Studio UI or complete feature acceptance. The viewport selector is
implemented using the existing native enum field and both localization catalogs;
its mounted interface is not yet verified.

Retained evidence is under contribution task `mesh-terrain-composition` and
`.build-tools/mesh-terrain`. All six deliverables above remain open: source binding
and draw masks, full editor interaction/persistence, channels and materials,
retained surface-cell population, detail/seam constraints, package/export/performance,
platform validation and final independent review still require integration.

### Retained bindings checkpoint (2026-11-07)

The combined asset/runtime validation package passed its six original focused
checks after the optional authoring trait and draw-mask refactor. Geometry now has
18 passing tests. A reflected source pose retains signed scale; matrix poses that
cannot be represented as TRS are rejected before publication. A regression fixture
exposed Float-collapsed Boolean faces. The C ABI now reimports such closed results
through Manifold's Float-tolerance topology cleanup, retaining provenance rather
than dropping individual faces. The new regression and existing seam tests pass.

Serialized source identities, bindings and static part selections are connected to
a world-boundary binding system. A real hierarchy fixture captures only the trunk
part, keeps other parts rendered, moves a reflected root without destructive
accumulation, and restores the ground when disabled. Static source collision now
transfers with the accepted terrain generation. The same fixture uses native
physics to verify old-ground contact after moving, fresh authored-body restoration
on detach, and restoration when the terrain owner is removed. Native body handles
are never retained in the runtime backup.

These tests cover runtime bindings, not Studio controls or complete feature
acceptance. Source/binding deletion, retargeting and other lifecycle interactions,
editor transactions, channels/materials, retained population cells and all other
open stage requirements remain to be completed. No independent reviewer has been
invoked.

### Mesh coverage and palette checkpoint (2026-11-07)

An operand that extends outside the union of ground section clipping domains
is rejected before evaluation. The last accepted patch and its queries stay
resident. Existing joins across adjoining sections still pass. Heightfield
and volume saves now reject a Mesh Terrain manifest, including when the caller
supplies an outdated Heightfield baseline for the same destination.

Mesh Terrain now publishes palette layers through the renderer's PBR material
arrays. The joined source can specify a layer, subtractive faces use the
interior layer by default, and an ordered, bounded transition follows connected
ground edges. Independent triangle fields keep material lookups separate from
query geometry. A Windows runtime fixture checks the actual uploaded layer
and weight data. This does not yet cover imported material transfer, durable
paint, mip generation, native controls, or rendered GPU evidence for this path.

### Native tree and retained population checkpoint (2026-11-07)

The Windows viewport joined the opaque trunk of an imported tree and kept the
cutout canopy on the original object. A Move gesture opened the new footprint
and regenerated grass and stones at the old footprint. One Undo restored the
pose, joined geometry and both prototype populations. Of the original
placements, 40 grass and 30 stone identities survived the move.

CPU population now owns half-open three-dimensional cells. Retained cells
compare the local geometry, clearance dependencies and resolved coverage in a
spacing halo. The test moves a root inside one rebuilt section and compares the
accepted incremental population with a cold evaluation, including unchanged far
placements. The native example and complete packaging checks remain open.

Original opaque part draws now use retained source-face provenance. Tests
exercise source PBR factors and a real self-contained GLB with three embedded
maps, UV1 selectors and vertex color through live join and compiled reopen.
The canonical joined surface remains authoritative for collision and queries.
This checkpoint does not establish a continuous blend from imported materials
under partially painted source faces, cross-platform rendering or export.

### Workshop and interaction checkpoint (2026-11-07)

The [Mesh Terrain Workshop](../../Editor/Samples/MeshTerrainWorkshop/README.md) exercises
joined rock collision, a cave with distinct floor and ceiling paint, source
materials, and grass and stone populations. Studio Play on Windows displayed
the ball landing on the joined rock. The fixed-step integration test verifies
that simulation waits for the triangle collider before the ball starts falling.

Studio exposes Join, Subtract, Conform, and Detach. Detach restores independent
source drawing and recompiles the ground as one Undo/Redo entry. A spatial
transform submitted to the viewport uses the same transaction as a mouse drag.
Inspector coordinates commit on Enter. The Windows Workshop copy saved the new
coordinate and terrain manifest together, and Edit > Undo restored both. The
focused tests cover accepted and out-of-bounds coordinates. Native Dawn passed
the Wireframe, occlusion, and 32-slice texture array pixel checks. Compact labels
and the remaining platform states still require visual verification.

The standalone Windows SDK produced a debug WebAssembly player. With the Swift
6.3.2 workaround scoped to AdaScene debug WASI builds, the browser rendered
Workshop terrain, tree, grass and stones. The ball stopped on the joined rock.
The same export rendered both Wireframe and Shaded + Wireframe after setting
the camera's diagnostic mode in private copies of the packaged scene. The
exporter now generates the three shader variants with pinned Tint, and a focused
reflection test verifies the texture dimensions consumed by the WebGPU layout.
The optimized export also rendered the Workshop and its overlay with the
standard compiler pipeline. Remaining platform checks are open.

A group transform now stages one candidate for joined descendants sharing a
terrain target. The group transform, terrain, and retained source ownership
publish at one world boundary. The focused fixture covers accepted and rejected
moves. The editor regression covers two sources and retained Undo/Redo. The
Windows Inspector also saved a group move and restored its prior manifest via
Undo. A group spanning multiple terrain targets remains outside this slice.

### Meshlet terrain LOD MVP

Prepare one coarser hierarchy level from the accepted render sections in the
terrain worker. Reuse AdaEngine's screen-error cut and index ranges in shaded
and edge rendering. Preserve section and material boundaries by simplifying
complete interior triangle fans only. Keep canonical queries and collision
at full resolution. The focused runtime fixture exercises neighboring sections
with palette materials and compares every shared edge at mixed levels.
The Windows WebGPU suite compares the adaptive terrain's shaded and wireframe
pixels with meshes built from the selected coarse indices. The mixed-section
runtime test, the existing meshlet LOD regression, and the wireframe occlusion
check passed. The MVP uses one coarser level and preserves original triangles
where the surface or material field cannot be simplified safely.
