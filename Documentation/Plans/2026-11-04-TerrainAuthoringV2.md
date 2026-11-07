# Terrain Authoring V2 Implementation

Date: 2026-11-04.
Design: [Terrain Authoring V2](../Designs/terrain-authoring-v2.md), approved in the
project conversation after the reference-removal edit.
Status: **In progress**. No milestone below is complete until its production path
and applicable validation have been exercised.

## Current stage contract (2026-11-05)

The approved design remains unchanged. The following boundaries consolidate the remaining
work; intermediate fixes do not introduce additional feature requirements. Exact owned files
are registered with the runner before each addition. Stage completion requires its listed
production behavior and checks; the overall task stays open through stage 7.

| Stage | Concrete deliverable and acceptance | Owned scope | Required checks and current state |
| --- | --- | --- | --- |
| 1. Chunk foundation | Signed sparse storage, canonical shared samples, local mesh/collision updates and legacy compatibility. | AdaScene terrain; its AdaScene/AdaEngine tests; existing physics integration. | Focused storage/geometry/physics regressions and owning suites. Runtime implemented; final cross-platform evidence remains in stage 7. |
| 2. Assets, residency, LOD | Atomic portable region persistence, bounded loading, dirty/history pins, stitched visual LOD and canonical collision/query detail; exported resources reopen after relocation. | AdaAssets terrain/loading; AdaScene residency/save/LOD; native scene/export adapters and tests. | Real-file save/stream/cancel and LOD/physics tests pass locally. Resource collection/scene-reference/export acceptance remains open. |
| 3. Layers and authoring | Stable layer rules, detiling/triplanar PBR, native manual channels, layer/mask/tint/roughness brushes with compact atomic Undo, bounded uploads and retained unchanged geometry. | Terrain material assets/runtime; AdaRender bindings; AdaCorePipelines shader; corresponding CPU/GPU tests. | Implemented locally: owning CPU 469/77, material/texture GPU 22/4, lint 216/0, docs/catalog/example and focused independent review pass. Full platform/runner acceptance remains in stage 7; see boundary evidence below. |
| 4. Instances | Persistent shared-asset scatter/erase, deterministic filters, anchor reprojection, spatial batching; opt-in nearby static collisions and measured 100k-instance behavior. | Terrain instance/model paths; render extraction; physics integration; benchmark/tests. | Implemented locally: owning CPU 481/78, optimized native 100k pixel/performance comparison, lint 227/0, docs and focused independent review pass. Full platform/runner acceptance remains in stage 7. |
| 5. Smooth volumes | Sparse 32-cell density bricks, validated closed mesh/primitive CSG, ordered persistent edits, continuous ownership seams, nearest-surface queries and matching collision for caves/overhangs. | Renderer-neutral geometry; terrain volume assets/runtime/queries; CPU/GPU/physics tests. | In progress: bounded field/mesh solids, native persistence, scoped resources/cache and initial live ownership/collision with explicit seam strips and opt-in committed surface queries are implemented locally. Require concave subtraction and added ledge crossing chunk boundaries, sculpt reevaluation, save/reopen, Undo/reordering and invalid/canceled/budget rejection. |
| 6. Studio tools | Localized viewport tools/palettes, 300px Inspector, 24 meaningful presets, alpha import, mesh drop preview, source migration, history/cancel/Play behavior. | Existing terrain/editor controls, localization, history, project assets; mounted UI and interaction tests. | Not implemented beyond legacy controls. Require rendered native Studio interaction, English/Russian and narrow-layout checks. |
| 7. Delivery and acceptance | Discoverable guides, hybrid-terrain ADR, runnable example, portable export, final required validation and consolidated independent review. | Declared articles/navigation/offline catalog; example and ADR; validation evidence. | Guides currently describe shipped slices only. Full example, final docs/export/platform/GPU/Studio checks and `verify --stage done` remain open. |

The implementation order from this point is stages 3, 4, 5, 6, then remaining stage 2
export acceptance and stage 7. Apply focused Red/Green cycles, refactoring only when useful;
run owning/downstream checks at these boundaries and review completed behavior with its
affected interactions. Do not restart the whole audit after every local correction.

Classify new defects in changed behavior as regressions and missing design behavior as
unmet approved requirements. Both remain in scope. The previously reproduced three scripting
test failures are adjacent baseline issues, recorded separately in local logs; they do not
authorize scripting feature work or a claim that the full package passed. Browser authoring
parity, adaptive volume LOD, hydraulic erosion and exact CAD CSG remain excluded by design.
Missing mandatory platform evidence is a completion blocker, never a passing stage.

Latest focused evidence: public native-size preflight Red reproduced 6 issues in two cases;
unchanged Green/Refactor pass (1.688s/1.657s). Combined command size refusal passes three
cases (14.012s); the initial final-array assertion compared import order with canonical cell
export order and was corrected to a captured pre-edit payload, with an explicit TDD exception.
Surface-only geometry reuse Red reproduced four GPU-buffer/collider replacements; Green
and Refactor pass while the sculpt replacement control remains active. Scoped SwiftLint
reports zero violations in 201 Swift files. These are local slice results, not stage 7 acceptance.

Surface brush stage update: all seven operations now execute through the existing atomic
pipeline. Related runtime Red reproduced 21 issues; unchanged Green passes seven cases.
Supplementary production-path checks cover spacing, alpha, original surface filters, layer
pruning and work limits. The owning terrain CPU run passes 245 tests in 36 suites (103.345s),
and the material/texture GPU run passes 19 tests in four suites (91.056s). Independent review
found one mixed-pressure work-budget regression: 13,118,065 mask visits for 3,205 useful
samples. Filtering inactive dabs once before sample evaluation fixes it; fresh unchanged
Green passes both mixed/all-zero cases (.013s), and re-review closes that finding.

The new live-GPU fixture initially used radius 8 on a four-unit, 129-sample landscape and
correctly exceeded the sample budget. Its corrected radius .25 passes actual paint, Undo
and prepared-work cancellation while retaining mesh buffers. The interrupted fixture cycle
is explained explicitly; it is not claimed as a production fix. A fresh combined GPU Red
then measures 1,747,660 shared image bytes in one update. A private slice/mip upload cursor
now caps transfers at 1 MiB per update, retains the old generation until completion and
reuses completed arrays. Texture2D validates RGBA8 subresources before backend writes;
Metal, WebGPU and headless implementations preserve the existing initial-upload API.
Unchanged combined Green passes both real GPU tests (6.372s). One compile-only Green attempt
placed the cursor field on the wrong state type; correcting that field precedes the passing
run and does not count as behavioral evidence. Broader stage checks and review follow.

Pacing interaction review identified valid proxy uploads being rejected by inherited
placeholder allocation metadata. A fresh proxy regression reproduces two errors; capturing
the concrete backing once for validation, upload and alpha invalidation passes unchanged
Green. Allocation metadata is now immutable; the actual refactor passes the same test (.003s).
The earlier tracing-height failure disappears after recompiling its unchanged test client
(content SHA256 retained with the compiler log). No production fix is claimed for that
cache/client-rebuild result; its exact test remains in the owning acceptance run.

Portable tracing previously accepted layered terrain as ordinary PBR and discarded its
layer colors. Real GPU Red reproduces three failures, including incorrect pixels. The
existing unsupported-material/raster fallback now handles terrain bindings explicitly;
unchanged Green preserves the colors and publishes the diagnostic (5.093s). This does not
add terrain shading to the experimental tracer. GPU harness helpers now live in the
curated GPU fixture, so standalone WebGPU validation does not depend on headless test suites.

Stage 3 local boundary evidence: the final owning terrain plus AdaRender run passes 469 tests
in 77 suites (102.779s); the final real WebGPU material/texture run passes 22 tests in four
suites (114.987s). Pinned SwiftLint reports zero violations in 216 files. Offline regeneration,
27-guide verification and both documentation checks pass. The article's extracted surface-brush
example compiles and constructs its actual request; existing decoder/palette examples execute.
Focused independent review closes the proxy and tracing findings with no remaining blocking
finding in those interactions. These checks establish the Windows implementation boundary,
not Metal, other platforms or whole-feature completion.

The shared quick runner passes diff/content/secrets/Python lint/security analysis on Windows;
its native SwiftLint adapter is blocked because this host uses the pinned WSL binary. That
binary's actual scoped lint passes independently. An additional pinned Linux tool environment
was installed, but the cross-filesystem Git scan times out before that complete quick run.
Retain both blocked reports honestly. Quick-mode skipped categories do not establish tests,
runtime or platform acceptance. The complete applicable runner/platform profile remains a
stage 7 requirement; it is not waived by advancing implementation to instance collision.

## Stage 4 local boundary evidence

Opt-in nearby prop collision now has independent distance/count/geometry/native-preparation
limits, cached flagged candidates, deterministic selection, paced BVH preparation and atomic
publication. Brush painting persists its opt-in flag through native save and exact Undo.
Fixed-step readiness waits for newly required props, including in-region body teleports.
Frozen native physics cycles pass: nearby/reflected-parent selection (two cases, 1.097s),
brush/history/pacing/rejection/readiness (three tests, 1.819s), and review-driven recovery
(three tests, .640s). The latter reproduces and fixes disabled collision during an invalid
configuration, placement-only pose recovery and conservative camera-collector overflow.
Independent review closes all three findings; it does not approve the entire feature.

Material-layer brush filtering resolves the renderer's canonical automatic rules, masks,
curvature and painted overrides, then interpolates stable-ID weights with a bounded
gesture-local cache. A frozen six-case cycle reproduces nine failures and passes unchanged
Green (3.844s), covering missing-layer atomic rejection as well as automatic/manual fields.
Retained native mask erase/Undo and expensive-rule rejection versus a successful unfiltered
control pass (two tests, 3.294s). Independent review finds one exact-threshold rounding bug;
its actual native erase Red fails one assertion (.441s). Constant-preserving bilinear lerps
pass unchanged Green (.220s), and focused re-review closes that finding.

The final owning terrain/AdaRender run passes 481 tests in 78 suites (122.674s), after all
filter/recovery fixes. Scoped lint passes 227 Swift files; both documentation checks and
diff checks pass. The shared code-stage content check passes. Its quick review profile
passes diff/content/secrets/Python lint/security analysis but remains blocked on the native
Windows SwiftLint adapter; the pinned WSL lint run passes independently. Quick-mode skipped
test/runtime/platform categories do not establish full acceptance. Final required runner,
analysis and platform checks remain in stage 7, as at the stage 3 boundary.

The optimized native WebGPU benchmark passes on Windows Swift 6.3.1, NVIDIA RTX 4070,
D3D12 driver 32.0.16.1088. It loads 100000 saved decorative placements from two regions,
requires all placements to pass visibility and produce actual material pixels, and compares
exactly equal images with identical submitted matrices/assets/flags. Thirty warmed frames
are measured at 640 by 480 in albedo view:

| Path | Runtime entities | Camera draws | CPU ms/frame, process-wide | Completed wall ms/frame | Process working set bytes | Process committed bytes |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Terrain spatial batches | 35 | 1 | 34.375 | 33.00613 | 399245312 | 510283776 |
| One entity per prop, shared assets | 100035 | 1 | 125 | 126.0179567 | 512659456 | 621301760 |

Both retain 6400000 authored placement bytes. Process CPU includes worker threads; memory
includes the renderer, retained terrain/caches and harness. This is a simple warmed albedo
comparison, not shaded gameplay performance or exclusive placement-allocation accounting.
The measured test passes in 15.089s after the first complete release build (1571.13s).
Raw results and PNGs are retained in task-owned ignored evidence. Independent fixture/article
review reports no blocking finding; execution and full-feature acceptance remain distinct.

Earlier fixture attempts are excluded: missing normals and an inverted orthographic zoom
did not establish meaningful pixels. A subsequent valid 100k debug comparison exposed an
unequal baseline caused by legacy `Transform(matrix:)` decomposition of scaled bases.
The benchmark now supplies exact authored TRS and asserts matrix equality before submission.
No general Math fix or performance success is claimed for those interrupted/failed attempts.

## Stage 5 first slice

Start general scalar-field extraction in renderer-neutral `Math/Geometry`: immutable
finite grids of at most 32 cells per axis, smooth indexed triangles with outward normals,
explicit output limits and canonical shared brick-boundary positions. Own the new grid and
extractor files plus `Tests/MathTests/ScalarFieldSurfaceTests.swift`. Use the exact test file
against the real public Math product for focused Red/Green, then its owning tests. A closed
sphere, exact shared boundaries and malformed/budget failures establish this slice; they
do not establish caves, mesh-solid validation, terrain ownership seams, surface queries,
persistence or collision. Those remain required for stage 5 completion.

Extraction slice evidence: frozen Red reproduces three missing behaviors; Green passes
three tests (.050s). Removing temporary per-triangle arrays is an actual refactor and
passes unchanged tests (.048s). A second frozen cycle adds signed integer lattice addresses:
Red reproduces five failures, Green passes fractional-scale shared boundaries on all three
axes and addressed-coordinate precision (.047s). The real root Math-filtered owning run
passes 33 tests in 11 suites (.159s). Retained cancellation, extreme-scale normals and exact
solid-contact checks pass with the original extraction/lattice tests (eight tests, .093s).
Independent scoped review finds no blocking source defect. This establishes the standalone
extractor, including per-grid area-weighted normals, rather than terrain volume integration.

The next geometry slice adds validated sphere/box/capsule scalar operands, full affine
placement and hard union/subtraction. Density is negative inside; transformed values need
not be exact distances under nonuniform scale or shear, while their zero set follows the
full affine transform. Require analytic samples, reflected/nonuniform/sheared placement,
finite/invertible input validation and an extracted primitive tunnel/ledge fixture. Own the
new scalar-solid/operation files and their Math tests; imported concave triangle-solid
validation and persistent terrain operations follow within the same approved stage.

Primitive geometry evidence: frozen analytic/affine/Boolean tests first record 47 behavioral
issues; the tunnel/ledge fixture additionally exposes rounded contact topology. Canonical
position welding, coincident-face cancellation, coherent sheet winding and independent
contact fans retain a closed indexed mesh. An intermediate fixed-fraction endpoint snap
passes that fixture but independent review identifies erased representable small spheres.
The actual regression records two failed cases before correction. Remove that snap and
interpolate from the closer endpoint using its own density ratio. Cyclic shortest-edge
triangle-area arithmetic preserves narrow representable faces that long-edge subtraction
lost even in Double. Exact collinear subdivisions are conformed without moving coordinates;
contact processing has explicit work/output budgets and cancellation. Unchanged primitive
and small-feature cases plus retained independently thin plate, lattice, normal and cancel
controls pass together: 14 tests in six suites (.333s), log
`.build-tools/contribution/terrain-scalar-final-robust.log`. Earlier failed attempts remain
retained; their intermediate successes do not establish the final precision behavior.

Next slice: validated closed concave triangle operands with bounded immutable acceleration,
negative-inside nearest-surface sampling, full affine placement, finite/index/degenerate/
closure/winding/self-intersection rejection and cancellation/work budgets. Own new
`Math/Geometry/ScalarMeshSolid*` files and corresponding Math tests. This is imported-solid
geometry preparation, not yet terrain asset import, persistence or editor drop integration.

Imported-solid geometry: the first fixture attempt had a missing Transform3D rotation
argument and is a compile prerequisite, not behavioral Red. The corrected frozen tests
record 10 missing-behavior issues. Immutable bounded geometry now validates welded edges
and vertex fans, consistent winding and face intersections with a flat BVH; queries use
nearest-triangle distance and retry ambiguous parity rays instead of guessing. The same
closed concave L prism is checked under reflection/nonuniform scale/shear and duplicate
attribute seams. Unchanged Green passes five tests (.003s); Refactor passes. Retained actual
mesh subtraction extracts a closed L-shaped shaft, and pre-cancelled validation/sampling
throw: seven tests in two suites (.091s), log
`.build-tools/contribution/terrain-mesh-extraction.log`. Independent review finds a 32-bit WASM UInt32-to-Int index trap; use Int(exactly:) before
indexing and retain a full-width malformed-index control. Targeted re-review clears the
fix and article; WASM execution remains outstanding. Full current scalar tests pass 22 tests
in eight suites (.285s); actual root Math-filtered owning validation passes 50 tests in
17 suites (.288s), log `.build-tools/contribution/terrain-scalar-mesh-math-owning.log`.
Scoped WSL lint passes 248 files, and article checks pass two tests.
The terrain article documents these standalone preparation APIs and their integration limits.

Next persistence slice: a versioned independently loadable 32-cell volume-brick asset
contains 33-cubed finite Float samples and stable optional material tags. Preserve Float
bits, signed brick addresses and sliced-Data decoding; reject malformed versions, counts,
coordinates, tags, nonfinite data and trailing/truncated bytes before allocating arrays.
Own `Sources/AdaAssets/Terrain/TerrainVolumeBrickAsset.swift` and its asset tests. Follow
with bounded ordered operation/source/transform/precision metadata and atomic save/stream
integration. A standalone codec does not establish editable runtime volumes or seams.

Volume-brick codec evidence: the first thrown-error-only run exposes missing encoding but
does not satisfy the runner assertion requirement. Explicit valid-encoding requirements then
record two behavioral Red issues; unchanged Green passes three tests (.148s). One Green
attempt is blocked by a SwiftPM artifact-index network timeout and is not a source failure.
Retained real AssetsManager loading, signed address limits, header admission and pre-cancelled
encode/decode pass with the frozen codec tests: six tests in two suites (.193s), log
`.build-tools/contribution/terrain-volume-brick-loading.log`.

Next metadata slice: a bounded versioned volume document stores lattice origin/precision,
ordered unique operation identities, enabled state, primitive/static-model source, complete
affine placement, optional stable material assignment and independently named cached-brick
references. Reject unsafe paths, duplicate identities/addresses/names, unsupported versions,
invalid placement/dimensions and count/byte overflow. Own the new operation/document asset
files, their asset tests and a small Math affine-validation entry point reusing the existing
validated inverse. Atomic publication, cache regeneration and live terrain integration follow;
metadata round trips alone do not establish those behaviors.

Volume operation metadata: frozen Red records two required-encoding issues; unchanged
Green passes three tests (.056s), preserving identity/order/full affine placement and
checking table counts before malformed children. Record validation delegates primitive
geometry and a shared Math affine-validation entry point, and bounds cached resource names
and signed addresses. Post-Green test layout changes only satisfy SwiftLint; retained logs
preserve the original frozen cycle. Final combined volume-asset checks/review follow.

Combined volume data validation passes nine tests in three suites (.150s), scoped WSL
SwiftLint passes 254 files and the shared Code quick content check passes. Quick content
is not the complete final platform/runtime profile. Independent read-only persistence review
finds no blocking codec/metadata defect and confirms the article's integration boundaries.

Next runtime-kernel slice: capture an immutable COW base-height view, prepare validated
primitive/mesh operands in document order, evaluate a bounded negative-inside field with
material provenance, and build canonical signed-address 32-cell density bricks. Truncate
density to a narrow band for sampled extraction and cull operands only by a deterministic
expanded support bound; shared points must evaluate identically across bricks. Enforce
allocation/work/cancellation limits before returning data. Require cave/added-ledge signs,
ordered overlap behavior, base snapshot/re-evaluation, exact shared samples/tags, real mesh
placement and rejection of stale/missing prepared operands. Own TerrainVolume field/kernel
files and nearest AdaScene tests. Sparse retained cache invalidation, resource loading,
publication/seams/query/physics are subsequent mandatory integration, not implied by this kernel.

Field kernel evidence: frozen Red records five missing-behavior assertions; unchanged
Green passes five tests (.161s), including real immutable heightfield sculpt/re-evaluation,
ordered overlapping edits, placed validated mesh and exact shared brick values/tags with
actual surface extraction. Independent read-only kernel review finds no blocking defect
within this boundary; final Green was not yet available during that review. Supplementary
mesh-brick budget failure/recovery, fractional all-axis seams, disabled references and
pre-cancelled work follow. Post-Green frozen-test formatting changes no expectations.

Combined current volume data/kernel tests pass 17 tests in five suites (.239s), including
real mesh-brick budget exhaustion/recovery, fractional negative all-axis boundaries and
pre-cancelled work. This is CPU field preparation, not published hybrid terrain.

Next sparse-cache slice: immutable generations retain only requested/pinned density bricks
within count/byte/work budgets. Reuse unchanged brick identities and regenerate only local
base or relevant ordered-operand/source changes. Base lineage must survive COW/residency
forks; dependencies include authored hidden height coverage and mesh preparation generations.
Failed/cancelled preparation retains the old complete cache. Own the new cache and AdaScene
tests plus narrow field dependency/shared-budget helpers and base lineage/revision access.
Require unchanged reuse, remote-brick stability after local sculpt/op edits, source reload,
eviction/pins and partial-work failure. Resource import, disk publication and ownership seams
remain subsequent requirements; a cache generation is not a live render/physics commit.

Sparse-cache evidence: initial four-case missing-cache Red is expanded before production
with authored hidden residency, recording five assertions (.002s). Unchanged Green passes
five tests (.257s). Canonical page identities, rather than draw-tile revisions, preserve
unchanged values across COW/residency forks while actual writes/pruning invalidate affected
bricks. Relevant operation order and mesh preparation generations join that key. The byte
charge includes conservative sample and maximum bounded dependency-array staging. Actual
layout/Self-reference cleanup passes frozen Refactor (.311s); scoped WSL lint passes 260
files. Independent consolidated cache/base-helper review finds no blocking source defect;
its review preceded the final focused Green result. Broader terrain/render/Math owning
validation follows before integrating resource publication and the live hybrid surface.

Sparse-cache boundary owning validation passes 553 tests in 101 suites (115.584s), filter
`Terrain|AdaRenderTests|MathTests`, log `.build-tools/contribution/terrain-volume-cache-owning.log`.
This includes current legacy/source terrain, rendering ownership, Math, data and cache paths;
GPU golden suites are gated and this is not backend pixel/Metal/WASM acceptance.

Before hybrid publication, require untouched heightfield base geometry to retain its true
triangular surface, including steep shared boundaries and nonplanar cell diagonals. Add
production field/extractor geometry regressions, then correct base-distance preparation and
consistent tetrahedral X/Z diagonal selection as needed. Own the new AdaScene geometry test,
field implementation and renderer-neutral extractor/grid API files. This is part of the
approved ownership-seam requirement; actual seam meshes/render/collision remain mandatory.

Base-preservation regressions record two real geometric failures: steep boundary height
error 2, and nonplanar-cell center error 8. Preserve the base's unclipped y-minus-height
field (saturating only at finite Float range); select the heightfield's falling X/Z
tetrahedral orientation. Generic Math extraction keeps its original rising orientation by
default, with a fixed mirrored alternative. Unchanged Green passes both tests (.128s).
Independent read-only correction review finds no blocking defect and identifies the precise
matching condition: same sample grid or exact aligned refinement, not arbitrary coarsening.
The article now states that condition. Retained both-diagonal closure/seam checks and the
combined current volume tests follow; actual ownership seam geometry is still pending.

Current geometry follow-up passes 24 scalar tests in nine suites (.281s), including
both orientations' closure/normals/shared fractional boundaries; current combined volume
checks pass 24 tests in seven suites (.359s). Scoped WSL lint passes 262 files.

Next atomic resource slice: manifest version 4 optionally references one immutable volume
document in its asset directory; nil preserves legacy encodings. Save height replacements,
changed independently named bricks and operation metadata before atomically replacing the
manifest. Reuse unchanged generations, support explicit incremental brick removals, enforce
combined encoded staging budgets and stale-baseline checks, retain old referenced resources,
and remove only newly staged files on cancellation/failure. Height-only updates must retain
existing volume references. Own manifest/writer/AssetsManager terrain extensions, new volume
save-plan files, native persistence tests and the existing unknown-version fixture (advance
its future version from 4 to 5). Real temporary-project loading, budget rollback and cancellation
after an actual unpublished brick write establish this slice; live source hydration/render/
collision/history/export are still subsequent mandatory integration.

Atomic native save slice implemented: six production filesystem tests reproduce 12
behavioral Red issues and pass unchanged Green (.321s), including cancellation after
an actual unpublished brick write. A separate unchanged-generation regression reproduces
8 issues across full/incremental saves; canonical signed (z,y,x) cache order passes
unchanged Green and the actual writer-formatting Refactor. Affected volume/manifest/
height-save/platform suites pass 52 tests in 13 suites (.753s); scoped WSL lint passes
266 files with no violations. Independent slice review is pending; live publication,
scene history, export and Studio acceptance remain mandatory.

Network failure during validation was infrastructure, not Red. Official Swan
`SWAN_LOCAL_DAWN` resolves the same pinned Dawn 148.0.7778.97 SDK from the previously
SwiftPM-verified cache, without changing the backend or dependency pins. The cached
archive SHA256 is 0257e10caa98696d66e06abd004b98fe48f7cfb1e254c6e78c7f47f1d62150a2;
all 31 native SDK/info members were compared with the archive. Task-local receipts
`terrain-offline-dawn.json` and `terrain-offline-dawn-stable.json` retain provenance.

Next resource integration slice: load referenced volume documents and independently
requested cached bricks through the originating scoped AssetsManager path, with
preflight memory/count bounds, exact address and palette validation. Prepare closed
static model operands from every selected scene node/primitive and its full inherited
transform; reject deformed/open/invalid geometry and respect import/validation budgets.
Own TerrainRegionCache volume extension, prepared-mesh model bridge and real resource/
model tests. Keep bulk preload lazy. This slice precedes live ownership seam geometry,
render/collision publication and authoring history; it does not close stage 5.

Atomic-save review corrections: all three findings (volume-only stale roots, retained
file integrity and retained material references) reproduce together: 3 tests / 7 cases,
19 Red issues (.561s), unchanged Green (.463s). Validate either incremental half against
the root before staging and commit; bounded-read/decode retained bricks individually,
checking addresses and material tags. Independent targeted re-review clears all three.
The final affected profile passes 55 tests in 14 suites (.904s), WSL lint 267/0.
Whole-feature and platform acceptance remain open.

Scoped lazy volume loading: three filesystem/scoped-project tests (four cases)
reproduce four Red assertions (.167s), then pass unchanged Green (.175s). Metadata
opening does not read bricks; signed subsets validate budgets, uniqueness/declaration,
exact payload addresses and palette tags before returning a complete private array.
The context that opened the cache owns all later loads. Test formatting follows Green;
final affected verification remains pending with the model bridge below.

Prepared model bridge: frozen two-test Red4 issues (.846s) -> unchanged Green (.151s),
covering split primitives, inherited reflection/rest poses, selected scenes, exact operand
placement, open/deformed rejection and budget admission. Scoped real-OBJ loading has one
actual missing-preparation Red -> unchanged Green (.153s); preceding test-only SPI and
Sendable closure compile failures are prerequisites, not Red. Inherit the original import
limits and scope, narrow import byte caps to the requested preparation allowance, and run
closed-solid validation on the worker.

Independent review finds full POSITION accessor copies outside per-index staging. The
large-unused-accessor/closed-cube regression reproduces Red1 (.136s), then passes unchanged
Green (.095s) after reserving the entire accessor before flattening, including repeated
scene references. Targeted re-review clears the staging correction and scoped model loading. The current
combined owning/downstream profile passes 574 tests in 107 suites (112.926s), WSL lint
273 files without violations, docs two tests and diff whitespace checks pass.

Next live volume publication contract: a source-backed terrain with an ordered capsule
cut and elevated box union replaces affected heightfield tile geometry with smooth density
surfaces. Render geometry and real native triangle colliders publish together through the
existing paced source transaction; no duplicate old heightfield plane remains in an owned
tile. First regression uses real saved height/document assets, runtime child mesh buffers,
and native sphere casts onto a tunnel floor and added ledge. Next dedicated checks cover
base re-evaluation, geometry/collision seams, stale/cancel/budget rollback, saved-cache
fallback, nearest queries and source transforms. Own source residency/build/publication,
new hybrid geometry helpers and runtime/geometry tests as introduced. Full 3D materials,
history/density editing/export and Studio acceptance stay mandatory subsequent work.

First live source publication: frozen real-asset/render-buffer/native-collision regression
reproduces four Red issues (.191s), then passes unchanged Green (1.919s) and a useful
32-bit-safe index/Sendable/formatting Refactor. Earlier axis-name compile failure is not
Red. Retain bounded immutable density caches and tile products in source residency, force
owned tiles to level zero through the existing LOD balancer, replace canonical/display
meshes and use the existing atomic paced render/collision publication.

Ownership boundary regression on a nonplanar 129-sample terrain reproduces differing
X/Z boundary segments, then passes unchanged Green (1.762s). Extend footprint padding by
at least two height cells; replace pure-base outer density strips with original heightfield
triangles, subdividing their inner edges to match the extracted surface. Original outer
edges/normals remain unchanged. One shared descriptor supplies both render and collision.
Triangle staging and seam point visits have explicit bounds and cancellation. Helper
allocation/format cleanup follows Green; final affected checks and independent review
remain pending. This first live path requires full64cell tiles, brick-aligned exact grid/
refinement, and has not yet integrated cached-only fallback, volume3D materials, partial/
outside-base coverage, canonical crossbrick shading, surface queries or volume history.
Those remain mandatory stage5 work, not exclusions or feature completion.

Consolidated first live review corrections reproduce 5 issues across three frozen tests
(6.504s), then pass unchanged Green (1.587s): canonical inner transition endpoints at
spacing .1/origin100000, terminal unsupported-volume-material diagnostics preserving the
last valid surface, and unchanged native save retaining density/tile generation UUIDs.
Bracket actual canonical axis positions rather than inferring a uniform world increment;
use the failed-generation retention path for the temporary unsupported material case;
carry volume through save acknowledgment. The material guard must disappear when required
3D volume fields are connected; its regression already permits coherent future success.

Affected centroid re-review finds the split fan still sums Float world positions. A real
finite snapshot near1.2e38 with a midpoint-induced fan reproduces Red1 (.013s), then passes
unchanged Green (.011s) after sharing componentwise Double centroid arithmetic and checking
appended vertices/normals for finiteness. Scoped lint passes281 files with no violations.
Final affected refresh passes580 tests/108 suites (120.716s), with lint281/0, docs2,
shared quick content and diff whitespace checks passing. Independent targeted re-review
clears the fixes and article; this approves the slice, not remaining stages5–7.

Next surface-query contract: renderer-neutral open-triangle BVH supports two-sided nearest
ray hits and closest points with finite input/index validation, explicit construction byte/
work bounds, shared query work budgets and cancellation. Source workers prepare/reuse
per-tile indices for explicitly enabled query settings and publish them with the matching
canonical render/collision revision. Ray queries distinguish stacked ledges and cave floors;
editor consumers use terrain-local results under the source transform. Chunk bounds/BVH
visits replace triangle-wide hover scans. Own Math query primitives/tests and source
query settings/preparation/publication/scene tests as introduced. Verify real committed
scene queries, unchanged tile reuse, transforms and rollback, then integrate editor usage
in stage6. Optional query preparation preserves existing runtime memory/performance when
queries are unused. Full platform/CPU/GPU/Studio acceptance remains mandatory.

Renderer-neutral query index: five frozen production Math tests reproduce five Red
assertions (.008s), then pass unchanged Green (.168s), covering stacked open surfaces,
two-sided rays/shared edges, closest points, empty/invalid input, byte/work limits,
20k-triangle actual BVH traversal under256 visits, shared budgets and cancellation.
A representable outside-edge regression exposes containment expansion (Red2); common
ray-space signed edge tests plus strict closest-point containment pass all six tests
unchanged (.167s), followed by an actual early-return formatting Refactor. Source triangle
IDs survive BVH sorting without copying unused position rows. Existing solid geometry
shares only the triangle record/hierarchy, retaining its original validation/parity paths.

Fast query cycles use a separate ignored `terrain-query-math-tests` SwiftPM fixture,
unchanged test-byte SHA receipts and the actual public Math product. Its official local
Dawn fallback points to the separately verified stable SDK copy; it does not mutate the
older fast-Math SDK used by native root tests. Root Package.resolved remains unchanged.
Scene publication/query integration is implemented below; complete cross-platform evidence remains pending.

Scene query integration: two frozen real-source tests reproduce Red2 (2.663s), then pass
unchanged Green (2.827s) and an actual guard/optional-format Refactor. Query settings are
optional/nil by default. Workers capture/reuse per-tile indices; shared construction work
and entry/full-accessor-copy/index staging guards apply before query allocations. Immutable
terrain-local snapshots publish with canonical render/collision, remain usable when held,
retain prior valid output on admission failure and release current acceleration on disable.

Consolidated independent review confirms BVH recursive sorted/COW buffers exceed512 bytes
per triangle. A separate bug-cycle ledger (`terrain-query-allocation-regression`) retains
actual Red1 (.002s) -> unchanged Green (.001s), without replacing the parent's pending
source-cycle evidence. Derive the charge from four triangle arrays, two node arrays and
allocator/metadata allowance. The parent owns the regression and final review covers it.

The same review finds Float-rounded cross-tile distances select farther surfaces. Frozen
two-plane ray/closest regression reproduces Red2 (.001s) -> unchanged Green (.002s), carrying
Double preciseDistance through selection while Float.nextUp remains only a conservative
traversal bound. Targeted re-review clears that correction.

Supplemental post-implementation production coverage (no fabricated Red) passes three
scene tests (10.531s): original runtime checks plus staged sculpt/Undo, old immutable
snapshot retention, distant query UUID reuse, reflected/nonuniform terrain beneath a parent
matching actual native spherecasts, and unchanged save UUID reuse. One test-only throwing
RHS expression was split before execution; that compile failure is not behavioral evidence.
The original fixture was formatted/shared after its completed frozen Refactor. The refreshed
owning Terrain/AdaRender/Math selection passes591 tests in112 suites (100.606s); pinned
WSL SwiftLint passes291 owned Swift files with zero findings. Documentation tests2,
quick content checks and diff checks pass. Targeted independent query review has no
blocking finding. The full feature remains open.

Next volume shading slice: publish canonical lattice-gradient normals independent of
brick ownership, retain the original pure-heightfield seam normals, and include the
one-sample derivative halo in cache dependencies. Own the volume field/normal/geometry
helpers and focused Scene normal tests. Frozen adjacent-curved-brick coverage must fail
before implementation, then pass unchanged; affected volume cache/runtime suites and
scoped lint follow. Full 3D material atlases remain the next required slice.

User-directed preview checkpoint (2026-11-06): prioritize a visible example before further
backend expansion. `TerrainPlayground` is a separate production-pipeline executable with a
saved 65-sample hill, subtractive tunnel, additive ledge, four viewpoints and free-flight
controls. It is not the complete Studio authoring UI. Initial native D3D12 launch found
Swift collision validation rejecting thin triangles. The prototype frozen thin test gives
Red1/.002; its first Green still fails native cooking because that initial fixture's area
is below Box3D's existing cooking tolerance. Do not claim unchanged Green for that cycle.
Correct the fixture to a triangle above the native limit but below the old Swift cutoff,
retain that as post-implementation coverage, and disclose the calibration correction in review.
The Swift gate now matches the native normalizer's finite range; native cooking may still
omit sub-tolerance faces, so full exact collision acceptance remains open. The second visible
launch reports ready and displays the actual cave and ledge; the cave-interior and under-ledge
view buttons were exercised through Windows UI automation. Full feature completion and
physics precision acceptance are not established by this preview.

Preview validation: corrected thin/native physics plus canonical normals pass8 tests in3
suites (.290s); source documentation tests2 pass. Final example target compilation passes
(134.17s), pinned WSL lint298 files/0 findings, and independent scoped review reports no
remaining preview blocker. Visible shading still has shadow striping under the ledge/in
cave views; this remains an observed rendering issue, not a visually finished result.
The complete quick runner still reports the Windows SwiftLint adapter unavailable and a
heuristic secret finding for the pre-existing public Swan revision in Package.swift. No
suppression, dependency change or complete-profile success is claimed. Initial content
trailing whitespace in that newly owned manifest is corrected separately. Full acceptance
and final task verification remain open.

Editor-first continuation requested by the user: stage6 begins with a runnable existing
Studio scene and Terrain Source Inspector rather than more standalone-demo controls.
This first slice owns the additive source descriptor/registration, scoped .aterrain path
resolution, edit-world collision suppression and query admission, EN/RU labels, save/reopen
tests and a real project fixture for packaged native Studio. The300px Inspector proposal
uses the existing theme/font and generic controls (filled/empty source states); it was
shown before production UI edits. Acceptance: frozen real-file save/reopen and scope tests,
localized Inspector registration, native packaged scene visible/selectable after reopening.
New sculpt/volume/material controls remain subsequent visible iterations; no stage5/6 or
whole-feature completion is implied. Every iteration is exercised in the running editor.

Editor source/picking checkpoint: the first Source tests reproduce9 real missing-feature
assertions (.162s). After implementation, two assertions exposed a test-only Windows8.3
versus canonical temporary-directory alias; canonicalize the fixture root, retaining later
runs as corrected post-implementation coverage, not unchanged Green for that first file.
The initial dependency identity failure and a localized resolver's actor annotation compile
failure are prerequisites, not Red. Private MCP staging adds an explicit AdaEngine package
name so a worktree named terrain-v2 resolves; all runtime dependency source bytes are unchanged.

Frozen actual-source picking coverage reproduces Red2/.772s and passes unchanged
Green1test/2cases/.219s. Picking uses committed query snapshots on authored owners;
normalized local distances are converted back to the world-ray parameter before comparing
other meshes. Existing picking tests were formatted after their completed Green; no fake
Refactor claim is made. Independent review found an omitted-nil-radius compatibility issue;
a new frozen codec/scene test reproduces Red4/.116s then passes unchanged Green1test/2cases
in.103s. Decode defaults fill required fields while preserving ordinary optional semantics.

The complete native Windows distribution (terrain-editor-preview-1) passed the packager's
bundled-tool smoke and launched the real copied TerrainStudio project. The terrain resource,
3D cave/ledge and300px Inspector were observed; the user began interacting, so leave that
process/project open and avoid further automated input there. That first staged binary
predates the picking and nil fix; a subsequent distribution must include both before
claiming those interactions in packaged Studio. Editor terrain article now documents source
loading, selection, preview/Play separation and the explicit current authoring limits.
Owning/editor localization/lint/docs checks and targeted re-review follow this checkpoint.

Next editor authoring slice: use the existing height-edit/save worker transactions on a
private same-directory manifest fork, then publish one portable source-reference change
through ordinary scene history. The previous manifest/resources stay unchanged for exact
Undo/reopen; cancellation/no-op restores the runtime reference and removes only its own
unpublished manifest. Keep the prior committed mesh while work is pending, bound metadata
I/O, serialize gestures and cancel on owner/document/tool lifecycle changes. Initial controls
reuse the existing four height brushes; release commits one asynchronous source gesture.
This edits the saved authoring resource in the edit world, not gameplay-only runtime state.
Own the editor transaction helper, viewport bridge/tool state and tests. Require real source
worker/save/reload coverage for success/cancel/no-op, one-history-edit/Undo/reopen checks,
plus packaged Studio pointer/Escape behavior before calling the source brushes usable.

## Boundaries and evidence

All six capabilities remain in scope. Keep legacy heightfields working while adding
new asset, geometry and editing paths. Use one testable behavior per TDD cycle;
record real assertion failures before production fixes. Compile/infrastructure
failures remain blockers. Do not manufacture Red results for APIs that cannot yet compile.

The initial design-stage task captured concurrent contributor-workflow edits.
Those edits were subsequently committed and revised by other work. Initialize the
implementation task `terrain-authoring-v2-implementation` at the current repository
baseline rather than adopting those unrelated files. Preserve the original design
task and its reports for provenance. Record approval against the accepted design;
the local approval record is an attestation to this chat, not authentication.

Implementation runs in the isolated `codex/terrain-authoring-v2` worktree at
`.build-tools/worktrees/terrain-v2` in the original checkout. Concurrent edits in
the original checkout must not invalidate this worktree's TDD snapshots.
For fast CPU cycles, a local generated SwiftPM fixture depends on the real engine
package and copies the unchanged terrain test sources, recording their hashes and
original source locations. It does not replace production modules or use mocks.
Full owning/package/backend validation remains required before review.

Register exact new/changed paths through `scope` before editing each slice. Start
with this plan and the design, then declare the user articles/navigation. Record
source, tool, TDD and runtime evidence under `.build-tools/contribution/`.
Do not modify validation profiles or suppress diagnostics to pass checks.

## Delivery milestones

Current implementation evidence (intermediate, not feature acceptance): the focused
native fixture passes 121 tests over tiled legacy rendering/collision, authored
selection, sparse storage, bounded resource loading, the binary region codec and
real-file storage restoration, portable manifest validation and staged persistence.
Persistence tests cancel after an actual region write and verify the old manifest,
cleanup, generation retention, unchanged-resource reuse, reloadable extensionless
paths, concurrent-save rejection and preflight byte limits. Incremental writes retain
unloaded references within changed-payload budgets, validate exact explicit removals
and reject a stale baseline before staging or publishing. A separate read-only
intermediate review found no concrete merge defect; its requested progress-time
replacement and incremental-cancellation regressions now pass. Runtime save requests
capture hidden dirty layouts, preserve unloaded references, adopt committed readers
and release clean dirty pins. Tests exercise revisiting and repeated saves within a
16 KiB page budget, preserving storage/buffer identity, hidden-layout persistence
and stale disk rejection. Save lifecycle tests now cover URI clearing/replacement,
actual pose/native-body movement, unpublished-edit rejection, later edits remaining
dirty, nonzero Undo across region eviction, camera/physics streaming during a save,
and a third queued source continuing residency behind two paused writes. A shared
FIFO bounds owned filesystem snapshots to two, including detached/cancelled tasks
awaiting their final receipts. Post-commit success is retained despite cancellation.
SwiftLint reported zero violations over 70 scoped Swift files before the latest
pin changes. Save snapshots now pin canonical regions through normal residency
admission; the one-page test refuses a second region while an older save and Undo
need the first, preserves the captured save, then saves the later Undo and admits
the second region after release. Independent read-only review found no additional
concrete defect in these save fixes; this is not final feature approval. Twelve existing asset
manager/directory tests also pass in a fixture using the complete engine dependency.
The region cache uses real typed asset loading, immutable resident values, aggregate
height/count limits and independent pin reasons. Its tests cover retaining a loaded
generation after file corruption, explicit eviction and admission failure without
dropping prior resident data and retaining the originating app-world asset scope.
The scope test uses two real resource roots with identical virtual filenames and
different heights, opens under one scope and requests data under the other.
`Terrain3DSource` is registered by `Model3DPlugin` and loads a manifest's declared
set within region/height/mesh budgets. Headless scene tests verify resource loading,
local revision-driven buffer replacement, shared color updates, cleanup, reflected
parent-space collision and preserving a valid generation when replacement fails.
A further real-physics regression moves the parent during a failed replacement,
checks the retained collider's new pose and recovers the source with unchanged
visible mesh buffers.
Local edits during a failed replacement continue to update the retained generation;
a repaired file is adopted only after an explicit source retry. Admission tests
check that height/mesh budget failures publish no partial children and that an empty
source removes a previously loaded generation.
Camera-driven residency now selects nearby regions, including a canonical data and
normal-coverage halo, and stages storage before publishing geometry/collision.
A real-file scene test loads one region from a larger manifest under a one-region
budget, moves to a distant region, releases its previous meshes and preserves the
storage object's identity and query footprint. Dirty region overrides retain edits
across staging. A real-file regression verifies failure under a one-region limit,
raising that limit, moving away and returning to edited data, and changing the
height budget without resetting storage identity or reloading original heights.
A rejected zero-byte limit retains the last valid budget and buffers. CPU staging
tests verify canonical normals across normal-only halo ownership, retaining an
unaffected tile revision while expanding visibility, stale-write rejection after
an intervening edit, and rejection of over-budget candidates without mutation.
Physics-interest planning now includes complete rigid-body bounds, projected swept
motion and upright character capsules outside camera coverage. Shape-local bounds
are cached; initialized rigid bodies use native world bounds. A real-file/physics
test requests a distant wide body's full footprint, replaces it with a character,
and verifies region and collision residency. Another test fails admission, verifies
both rigid and character movement wait, raises the limit and simulates their real
grounded landing, then despawns the source and verifies its hold is released.
`PhysicsSimulationGate3D` has independent owner/reason holds. A physicsSync recheck
runs after body synchronization, verifies source/data/pose and native colliders,
and prevents a character teleported later than preUpdate from moving until its
destination is resident. A second regression releases one of two reasons on the
same owner and verifies movement remains paused until both release. Sweeps include
at least the fixed tick and account for gravity/downward character motion.
Twenty-five existing character/resize/step tests in three suites passed through
the root package with `swift test --scratch-path .build --force-resolved-versions
--jobs 8 --filter CharacterController3D`; the complete package test targets compiled
for this filtered run. The log is `.build-tools/contribution/physics-root-regressions.log`.
Region reads and CPU meshing now run in cancellable owned tasks, with at most two
concurrent source preparations including staged results. Tile GPU/collision
preparation respects a per-frame budget and publishes the whole generation together.
Real-file scene tests verify pending status, incremental preparation without visible
partial children and cancellation when the source changes. A monotonic-camera regression reproduced starvation of a third source and now
verifies FIFO admission ahead of newly requested generations. Further cancellation
and platform checks remain required. Previously reads/meshing were awaited
in `preUpdate`.
The render-only heightfield LOD mesher downsamples canonical geometry and adds
explicit coarse-side vertices for finer neighbors. Tests cover nonlinear shared
positions/normals and every edge mask across six levels, including nondegenerate
upward full-area coverage, partial-tile fallback and invalid inputs. Camera-driven
selection and runtime switching now use active cameras' parent-composed positions,
terrain-local tile distances and a hysteresis band. A headless scene test switches
four tiles between levels 0 and 6, retains buffers within a distance band and checks
a narrow height spike through actual full-detail physics casts and storage queries
while rendering the coarsest visual meshes. These checks do not replace GPU pixels.
Sparse resource user authoring remains outstanding.
Additional policy tests cover hysteresis across both transitions, reflected inverse
transforms, multiple views, partial edges, inactive/no cameras and a zero level cap.
An initially missing source with an active camera retains its error until explicit
retry even after a valid file appears; failure state is keyed independently of
camera movement and retained geometry.
The LOD balancer now propagates refinement to constrain edge neighbors to one level,
preserves full-detail/partial boundaries and produces the mesher's directional masks.
Its tests cover propagation, all-sided seams, partial neighbors, disconnected extreme
coordinates, deterministic ordering and malformed inputs.
Region restoration includes partial tiles and
canonical data-only resources at the positive grid boundary. Three supplemental
Swift Testing cases compile the actual bounded browser-read helper to WASM and
execute exact-size, empty, oversized and pre-cancelled fetch behavior in Node.
Their helper/test/log hashes are retained in
`.build-tools/contribution/terrain-browser-evidence.json`. That fixture uses minimal
enclosing declarations and does not establish complete AdaAssets, browser-shell or
Studio behavior. Full package/backend/platform checks and independent review remain
outstanding. `script/validate_terrain_native_io.py` additionally compiles the actual
region/manifest codecs, bounded reads and writer in a minimal native host fixture.
Its Swift Testing case reproduced an existing-manifest replacement failure on Linux
with Swift 6.3.2 and passed after switching the writer to POSIX rename. Windows uses
MoveFileExW. The probe supplies only contextual asset-protocol/metadata declarations;
it does not replace real filesystem operations or prove the complete AdaAssets
package on Linux. The same test source runs against the complete module in normal
package tests. Sparse resource Studio authoring remains outstanding; none of the remaining feature requirements is waived.

1. **Chunk foundation and compatibility.** Add stable signed coordinates, bounded
   sparse region storage, canonical border samples, revisions and immutable tile
   snapshots. Migrate an existing patch without changing its sampled shape. Keep
   negative coordinates, corners, malformed input and unchanged writes covered.
   Integrate independently rebuildable tile meshes/collision and terrain queries.
2. **Assets, residency and LOD.** Versioned independently addressable region files,
   staged persistence, cancellation/pinning and byte budgets; native export dependency
   collection. Add stitched heightfield LOD with canonical collision/picking detail.
3. **Layers and rule evaluation.** Stable layer IDs, bounded normalized contributions,
   soft elevation/slope/curvature/noise/mask rules and manual override/erase. Implement
   bounded GPU texture arrays, coherent mirroring/rotation/gradients/normals, macro
   variation and triplanar mapping through shared PBR lighting.
4. **Instance cells.** Deterministic persistent placements and scatter filters,
   multi-primitive source transforms, shared render extraction and mesh/material
   reuse; spatial culling/LOD and explicit nearby collision budgets. Reproject edited
   anchors transactionally. Benchmark 100,000 decorative instances.
5. **Smooth volumes and CSG.** Validated primitive/closed-mesh operands, ordered
   union/subtraction, bounded scalar-density sampling and smooth extraction. Ensure
   canonical seams with heightfield tiles, surface ray queries, coherent collision,
   non-destructive edits and persistence. Cover tunnels/overhangs across borders and
   invalid/singular/canceled operations.
6. **Studio tools.** Localized categories, collapsible asset/brush palette, narrow
   Inspector, preview/drop operations and complete undo/cancel transactions. Add the
   agreed shaping/painting/scattering/volume operations and at least 24 meaningful
   editable presets. Retain current navigation, selection and Play behavior.
7. **Documentation, example and final acceptance.** Ship discoverable guides and a
   reproducible example. Run applicable package/platform/GPU/export and UI checks,
   resolve findings through independent review, and verify the final stage.

Intermediate independent review identified starvation, orphan children, raw scene
persistence, dirty history bounds and synchronous recovery cooking. Real scene and
physics tests now cover cleanup after nonrecursive owner removal, retaining ordinary
authored children, native scene save/reopen without derived geometry/collision,
and bounded recovery after a missing replacement resource and parent movement.
An integration failure exposed restored entity ID reuse; the decoder now reserves
loaded IDs before new terrain children are spawned. Non-Codable component state is
skipped without formatting large cached descriptors into encoding-error logs.
The standalone dirty queue is bounded and exposes an overflow generation requiring
consumer resynchronization. Failure recovery retains published visual LOD and uses
the same incremental collision preparation as successful replacements. An initial
collision test probe intersected its own waiting body; its corrected probe is offset
from that body. Original failing logs and the corrected Red/Green run are retained.
The re-review also reproduced a cached-URI revert retaining its FIFO position;
a runtime regression now verifies that later sources still publish. Further tests
exercise transient groups with unmarked descendants, safe IDs after reopening, and
consumer reconstruction after dirty-queue overflow.
A further native Scene round trip preserves authored parent/child relationships and
world-space collision while filtering generated child IDs. Runtime, streaming,
physics, scheduling and persistence tests are split into focused files.
This is intermediate review only; complete feature review and full validation remain
outstanding. SwiftLint 0.65.1 was downloaded using the plugin's pinned archive hash
and runs under the existing WSL Swift toolchain; its scoped report passes with zero violations over 57 Swift files after formatting
cleanup. Newly added files and the final feature still require fresh scoped checks.

The root ECS regression run passed 176 tests in 25 suites after scene serialization
changes (`swift test --scratch-path .build --force-resolved-versions --jobs 8
--filter AdaECSTests`), logged in `.build-tools/contribution/terrain-ecs-regressions.log`.
Height-edit command/status contracts now stage bounded, revision-checked candidates
and retain compact before/after sample deltas. Runtime tests cover four-tile corner
publication, inverse-delta Undo, invalid/nonfinite/stale/budget rejection and cancelling
prepared work. Further native-query tests reproduced ready status before actual bodies existed.
Terrain now initializes native bodies during serialized publication using the same
initializer as ordinary physics synchronization. Tests query initial terrain, an
edit and Undo without a later physics tick. Additional tests cover page exchange,
empty/unchanged requests, duplicate/missing/excessive/foreign inputs, supersession
and a live write invalidating prepared work.
Storage checks final page counts before allocation and preserves live data during
preparation. Intermediate review reproduced four further defects and they now have behavioral
Red/Green evidence: unbounded final-frame native cooking, cancelling a queued edit,
false collision readiness after an invalid edit/config change, and accepting a
height edit while silently ignoring new residency/memory settings. Native BVHs are
now cached in synchronized immutable Shape3DResource resources and actually cooked
within each tile-preparation frame. Per-physics-world counters are incremented at
the real C mesh factory; tests observe at most one creation per frame under a
one-tile limit, including publication, and no duplicate cooking on later syncs.
The C API borrows const mesh data, with resource/body ARC ownership retaining it
through native shape destruction. Config-conflicting edits fail explicitly while
normal admission applies or rejects the requested settings; queued cancellation
now completes its status. A teardown regression also removes a source during prepared height work, confirms
edit/status cleanup, preserves authored children and queries the absence of native
collision without a later sync. The root package physics/character regression run
passed 36 tests in five suites after the native-cache changes with
`swift test --scratch-path .build --force-resolved-versions --jobs 8 --filter
"CharacterController3D|Physics3D"`; its log is
`.build-tools/contribution/terrain-physics-regressions.log`.
Studio stroke integration and the remaining editing families are still outstanding.

## Owning paths and tests

Runtime terrain code belongs under `Sources/AdaScene/3D/Terrain/`; focused data/query
tests go in `Tests/AdaSceneTests/`. Renderer-neutral surface extraction belongs under
AdaRender's geometry boundary with `Tests/AdaRenderTests/`. Shader changes belong in
AdaCorePipelines with actual-pixel tests nested in `Render3DGPUTests`. Existing
`VoxelWorldStorageTests`, `VoxelWorldSystemTests` and instancing tests are precedents,
not substitutes for terrain-specific coverage.

Studio code belongs alongside `EditorTerrainBrush`, `EditorTerrainPanel`,
`EditorSceneViewportTerrain` and `EditorTerrainComponentDescriptor`; use existing
`EditorTerrainTests`, `EditorTerrainInspectorTests` and localization suites for
regressions. Check nearest instructions when extending other asset/export/UI paths.

Use Swift 6.2 isolation and Swift Testing. CPU data tests must cover real storage,
meshing, rule and transaction paths. UI tests mount real views; filesystem/export
tests use real temporary resources. Collision tests execute actual physics queries.

## User documentation

- Substantially update `Editor/Documentation/Terrain.md`; link it from
  `Editor/Documentation/EditorGuide.md` and `Editor/README.md`.
- Add `Sources/AdaEngine/AdaEngine.docc/Articles/3D/Terrain.md` and link it in
  `Sources/AdaEngine/AdaEngine.docc/AdaEngine.md` Topics.
- Add Terrain to `Editor/scripts/update-offline-documentation.py` inputs and
  regenerate `Editor/Sources/AdaEditor/Assets/Documentation/catalog.json`.
- Add a real example scene/project containing material rules, a painted path,
  instances, a tunnel and an overhang. Choose the existing example integration
  location after inspecting its loader/generator; record exact paths before editing.
- Record a hybrid-terrain ADR without rewriting historical ADR decisions.

The guides must distinguish completed slices from planned features while work is
in progress. Final articles explain setup, migration, coordinates, precision/cost,
formats, platform limits and a built/executed example using actual APIs.

The first CPU height-brush slice exercises all nine shaping operations through
real source commands and atomic publication. Tests cover native collision and inverse
deltas, collinear input-event subdivision, set height, ramps, terraces, reproducible
seeded noise, smoothing bounds, conservative local talus and invalid/oversized input.
A shallow immutable storage snapshot supplies each worker; only touched pages copy
on staged writes. Shapes, pressure, rotation/jitter and original height/slope masks
are present in the data contract. Rotated square/alpha support, canonical outer-edge
and normal-only halo slope masks, aggregate union-work preflight, malformed alpha
decoding and valid alpha round trips now pass real regressions. The halo fixture was
corrected from invalid zero streaming radius to a positive radius; the earlier failed
run is not counted as a completed cycle. Alpha decoding checks dimensions/counts
before its bounded pixel loop. Per-dab trigonometry is cached; talus avoids small
neighbor-array allocations. A checked bounds product also prevents 32-bit Int overflow
before work-budget rejection; full WASM engine evidence is still required. Read-only
intermediate review found no additional concrete brush regression before that final
arithmetic/decoder cleanup. Studio controls and named presets are still open.

The first shared-mesh slice adds `Mesh3DInstancesComponent` with stable placement
IDs, transforms and tints. Extraction retains a single render source per component;
compatible placements enter existing instanced draw lists without per-placement
entities. The initial real test checks uploaded GPU-buffer matrices/colors under a
reflected parent and repeat extraction. Portable tracing expands the placements,
hashes edits and derives tint material packets within its existing triangle limit.
The test fixture now reads actual uploaded GPU bytes rather than the intentionally
empty `currentBuffer.elements` wrapper; the earlier failed fixture run is not counted
as a completed cycle. Selected-LOD GPU candidate bounds and ordinary-versus-empty
shadow digest distinctions now pass dedicated regressions, followed by independent
read-only re-review with no additional concrete issue in those fixes. SwiftLint
reports zero violations over 83 scoped Swift files. Placement assets, streaming,
scatter, nearby collisions, broad lifecycle/LOD/visibility tests and the actual
100k decorative benchmark remain open; four placements do not establish performance.

## Validation and review

Run `check_contribution.py run` at Design/Plan transitions. Use the pinned Python
environment, repository toolchain policy and isolated task scratch directories.
Select focused suites first, then owning/downstream suites. Do not delete the shared
`.build`. For Windows execute Swift through the supported developer environment.

Required evidence includes signed-coordinate/border/migration/transaction tests,
real storage/export round trips, invalid-asset memory bounds, actual collision
queries through tunnels, renderer instancing counters and performance measurements,
and golden frames for layers/detiling/LOD/volume seams on Metal and WebGPU.
Run `script/validate_webgpu.sh` with compatible Swan/Dawn/Swift and fresh Tint
conversion; cached WGSL does not prove the shader. Check native Studio in a complete
staged distribution on Windows/macOS, including English/Russian switching and
300-pixel Inspector behavior. Build and serve relevant WASM exports. Obtain actual
platform evidence for supported configurations selected by the validation profile;
missing hardware/toolchains remain explicitly blocked.

Build DocC, build/execute examples, regenerate/check offline documentation and run
the localization checker when applicable. Full lint/analyzer and security checks
are selected by the shared runner over exact owned files. Record runtime/platform
recipes that exercise the affected behavior rather than echoing a passing result.

After full Code-to-Review validation, invoke `adaengine-review` in a separate
subagent context with the final diff, approved design, plan and evidence. The
reviewer checks all six requirements, correctness, performance/compatibility limits
and article/navigation accuracy. Fix findings, rerun affected checks and repeat
review. Only `verify --stage done` with complete evidence closes the feature.


The next instancing cycles release removed placement LOD selections, retain
camera-culled live IDs, and avoid full membership sweeps when ordinary sources are
re-extracted. Reordered placements preserve previous poses by ID. Independent
review found and verified fixes for compound owners leaking skin palettes into
static tracing and motion draws. Tracing now filters eligible parts once, transforms
referenced vertices only, bounds aggregate placement/triangle work and material
packets, and skips empty/line/point/cosmetic expansion. Corrected bounded Red
fixtures exposed each cost; an earlier combined stress fixture was interrupted
and is explicitly not accepted as Red evidence.

`TerrainMeshPrototype` prepares all active static model nodes and primitives,
retaining imported/rest-pose transforms, shared buffers and materials. Real
extraction/draw-list tests cover multi-node/multi-material composition and model
scene selection. Preparation bounds graph/geometry/placement work and rejects
malformed hierarchy, vertex/index storage, nonfinite data, singular transforms
and overflowing transformed placement bounds. Model data validation runs before
glTF GPU upload, including results returned by custom loaders. The general vertex
packer uses POSITION row count, safely ignores surplus attributes and zero-fills
missing entries. A real-file glTF regression and actual uploaded-buffer checks
cover the previously unsafe cardinality path; the Red fixture gates the old writer
on its erroneous allocation recipe to avoid deliberately executing an unsafe copy.
The original extraction regression fixture also needed CameraPlugin, a missing
setup dependency present at the base revision. These changes do not complete
persistent placement resources, scattering, instance collision or backend/performance
validation. The complete focused fixture passes 121 tests in 16 suites; SwiftLint reports
zero violations across 95 owned Swift files. Two documentation tests and the
27-guide offline catalog check pass. Owning model/import/render regressions are
being refreshed after the shared import changes; actual backend pixels, the 100k
benchmark and full feature validation remain open.

Placement-resource cycles add a bounded version-two region container with compact
64-byte placement rows, stable IDs and lossless reserialization of quantized channels.
Storage and cache enforce an independent decoded-record budget. Sparse residency,
hidden dirty overrides, save baselines and acknowledgements retain placements;
placement-only removal persists. Selected codec (3), storage (8), cache (2), and
source persistence/cache (4) tests pass their recorded Red/Green/Refactor cycles.
Intermediate independent review found and verified positive-boundary resource removal
and normal-only halo fixes; the persistence integration has no remaining concrete
finding. Full focused and owning regressions still need refresh after these cycles.
The earlier owning import/render run passed 129 tests across 29 suites with GPU/perf
skips; it establishes no backend pixel or benchmark evidence.

The mesh palette persists stable UInt16 IDs and validated relative model references
in version-two manifests. Both native save modes retain the table, and empty
palettes preserve version-one height-only encoding. Two focused tests pass their
recorded cycle; independent intermediate review found no concrete issue. The
unsupported-future-version fixture now uses version three, since two is supported.
SwiftLint passes all 103 scoped Swift files. Source persistence fixtures now provide
real static model assets when testing placement data, preparing the renderer hookup
without changing their preservation assertions.

The first source-rendering placement cycle passes eight selected real-resource tests.
It resolves static models in the manifest asset scope, groups placements by 64-cell
cell/prototype, shares source buffers/materials, preserves transforms and reuses
unchanged draw children across height edits. Real streaming and failed-replacement
lifecycle checks pass. A wrong cleanup patch anchor caused one compiler-blocked
Green attempt, corrected before the successful cycle; it is not Red evidence.
Intermediate review identified URI-clear cleanup, repeated camera regrouping and
unbounded inactive prototype retention. The next cycle adds explicit regressions
for these, including a 100000-record CPU/runtime fixture; it is not the required
release GPU benchmark. Per-publication grouping diagnostics count actual grouping
closure visits. Draw distance is world-space, matching existing mesh LOD semantics.

Lifecycle/bounds fixes pass their four-test Red/Green/Refactor cycle and intermediate
independent re-review. Immutable placement cell generations avoid camera-only row
grouping/comparison; active model vertex/index buffers, conservative CPU geometry and
derived clusters are charged once per prototype before draw publication. Inactive
models are released on replacement. Byte totals use checked, saturating arithmetic.
URI clearing removes draw cells. The complete focused fixture now passes 141 tests
in 20 suites (56.972 seconds). This includes the real 100000-record reuse fixture,
not release GPU timing or backend pixels.

Anchor reprojection passes its one-test initial cycle and three-test edge cycle.
Tests cover real sculpt/draw/save, free/distant preservation, a valid normal-only
neighbor at a shared edge, and 1000 small slope edits. Independent re-review found
no remaining concrete edge issue. Two compiler-blocked fixture/fix attempts are
not Red evidence. Additive general edit aliases and request DTO constructors keep
the existing inverse-height behavior; exact placement restoration/explicit edits
are not consumed by the worker yet and are the next observable Red scenarios.

The four-test placement/history cycle passes Red/Green/Refactor. Five repeated
Undo/Redo pairs restore exact region bytes. Explicit insert/save/inverse requests
and atomic invalid-cell/global-ID rejection pass, as does new hidden dirty-region
admission. Imported/edited/removed rows maintain a COW ID-to-cell index. Intermediate
review identified unknown declared baselines being mistaken for empty cells, and
full placement exports during local sculpt admission. Dedicated next regressions
exercise save/reload preservation and actual exported-row diagnostics with 100000
unchanged placements. Export diagnostics count copied rows and do not edit revisions.

The two streaming-edit fixes pass Red/Green/Refactor: declared unknown baselines
are rejected and a one-sample sculpt exports zero rows from 100000 unchanged
placements (the Red observed 200000). Independent review found save-reader adoption
needs a persistent known-region set, and canonical height-only boundary pages also
need region admission. That metadata is now retained without changing validation;
the next Red selects immediate-save placement Undo and three positive edge/corner
cases under a one-region cap. Full regression refresh follows these fixes.

Known-region admission fixes pass their recorded Red/Green/Refactor cycle: the
existing immediate-save placement Undo works, three parameterized height boundary
cases reject new canonical resources beyond a one-region limit, unloaded declared
data survive rejected edits and saves, and the 100000-placement local sculpt still
exports zero unrelated rows. A persistent complete-read set survives reader adoption.
Independent re-review found no remaining concrete issue in these fixes. SwiftLint
passes 113 scoped Swift files; documentation tests (2) and 27-guide catalog check pass.
Complete focused/owning checks are being refreshed before the next capability slice.

After the final placement admission fixes, the complete focused fixture passes
151 tests in 20 suites (70.629 seconds). The refreshed owning import/render
regression selection is running separately; backend pixels, GPU performance,
full authoring footprint promotion, scatter/prop collision, materials, volumes
and native Studio acceptance remain open.

The refreshed owning import/render selection passes 129 tests in 29 suites. The
initial complete build/test log finished successfully, while the local output helper
failed to print Unicode under Windows cp1252. After fixing that ignored helper,
the same freshly built products were rerun with --skip-build and native exit 0;
no production inputs changed between those runs. GPU/performance gates remain
skipped. Next, source brush gestures plan and hydrate their full bounded footprint
into a private editing view, preserving render visibility and atomic publication.

The complete authoring-footprint cycle passes its three logical tests (four cases).
The plan is shared between pre-hydration bounds and final kernel evaluation. Private
query snapshots temporarily expose normal-only declarations; draw coverage is restored
before the existing original-revision publication fence. A cross-region ramp loads
region 2 beyond the initial visible/normal set. Missing payloads or a two-region budget
reject the complete gesture, preserving revision and actual GPU buffers. Hidden
height/anchor changes save and undo without exposing extra draw tiles. Independent
intermediate review found no concrete issue; full focused regressions follow.

Full focused regression after footprint promotion passes 154 tests in 20 suites
(68.870 seconds). Mesh paint/erase request data are added to the existing general
edit DTO; the worker still follows its prior height-only path until the next Green.
The next real-source tests require persisted deterministic spacing/variation, no-op
repainting, event-subdivision invariance, erasing/inverse history, surface filters
and atomic malformed/oversized/missing-model failures.


The first runtime scatter cycle passes five real-source tests through Red/Green/Refactor:
paint/spacing/variation, compact save/reload and exact inverse, erase, event-subdivision
invariance, surface filters/alignment, and atomic invalid/oversized/missing-model refusal.
The subsequent two-test work-budget regression cycle passes Green/Refactor after an
observed Red where repeated dabs incorrectly applied beyond the intended membership
search budget. Every per-record bounds test now consumes a visit. Lattice identity
also incorporates physical scale. Its initial regression required only a nonempty
second patch, which was weaker than the review's partial-fill scenario; a strengthened
comparison with an isolated second stroke is included in the next full brush selection.
Independent re-review found no remaining concrete issue in these two fixes. The open
model loading finding is addressed next with small bounded root/dependency/accessor
fixtures. A limits DTO is present; enforcement is not connected until the next Green.


Native glTF import-budget checks pass their six-test helper selection together with
all seven scatter tests through Red/Green/Refactor. The first cycle observed six
missing limit errors across root, external buffer/image, invalid-limit and accessor
cases; its positive bounded geometry remains valid. Independent review then found
repeated embedded image copies, empty target metadata, and unchecked sparse index
narrowing on WASM32. Two small additional native assertions reproduced the first
two gaps; both are now charged before conversion. Sparse indices use checked Int
conversion; the native64 regression already rejected by destination bounds, so it
is not evidence of executing the original WASM32 trap. All 13 selected cases pass.

The three actual model-path tests then observed a late root limit, unnecessary root
reopening, and lost palette import context across cache/fork actor calls. ModelAsset3D
now caps the asset manager's first read and uses provided bytes under bounded native
glTF import. Terrain readers capture default/scoped limits and retain them across
forks and save-reader adoption, installing them during palette model loading.
All 16 selected helper/model/scatter cases pass Green. These checks do not close
image pixel/mipmap/aggregate costs, OBJ/VOX expansion, optional sidecar aggregate
budgets or browser importing; those remain next implementation work.


The complete terrain fixture passes 172 tests in 22 suites after pixel-budget
integration (Green: 70.637 seconds) and its first Refactor. Native header checks
precede pixels; importer accounting carries geometry cost into one texture budget.
Initial image Red observed the three expected failures in PNG, TGA and distinct
multi-texture aggregation, while all prior 170 cases passed. A transient GitHub DNS
failure occurred before that valid Red and is recorded only as infrastructure.

Independent image review found two uncovered cases: nonzero Data slice indices in
PNG headers and underestimated ImageMipmaps conversion/alpha-mask staging. New small
regressions observe an invalid header at safe slice offset 8 (before offset 100 could
trap), and two admitted underfunded model imports: no mipmaps with only 2.5 times the base
pixel payload, and a thin varying-alpha mip chain with only 4 base-image sizes.
The next Green fixes slice offsets and uses conservative staging charges of four
base sizes without mipmaps and six with mipmaps. Positive eight-base-size controls
still require real model creation. The public decoder guide now documents header
inspection, scoped limits and a slice-safe bounded custom decoder example.


Both pixel-staging regressions pass Green (0.123 seconds). Slice offsets 8 and 100
preserve positive decoding and reject the low limit. Actual no-mip and thin varying-
alpha model imports reject insufficient staging allowances, while their larger
positive controls still construct models. The next Refactor retains those tests;
full importer/image/render owning selections and the complete 174-case terrain
fixture refresh remain required. Lint passes 133 scoped Swift files.


The refreshed owning import/render/image selection passes 147 tests in 33 suites
(6.260 seconds), including regular custom image-decoder loading and CPU mip/format
checks; GPU/performance gates remain separate. The decoder guide's exact custom
RGBA example and scoped-model snippet compile in an isolated consumer package.
The custom decoder executes slice-100 decoding and the low-budget rejection; the
model snippet is compiled, while real model execution is covered by runtime tests.

Bounded OBJ/VOX tests pass Red/Green/Refactor: both supplied-root decoders avoid
reopening files, OBJ meters parsing and rejects nan/inf, and a tiny sparse VOX
payload rejects its declared dense-grid footprint under the low limit. The first
OBJ attempt lacked the required resolver fixture setup and crashed before assertions;
it is infrastructure evidence only. Bounded OBJ now selects its built-in safe parser.

Review then found raw VOX frame expansion beyond the initial input multiplier and
quadratic OBJ copies. Actual diagnostics observed 599940000 copied index bytes for
10000 repeated faces, against a 480000-byte linear bound. The next recorded cycle
mutates stored primitives through immutable source streams and charges actual DTO
record strides before reservation; both tests pass Green/Refactor. A further review
found 49995000 material comparisons for 10000 distinct materials. Indexed lookup
initially still made 51608 comparisons, exceeding the unchanged 40000 bound; one
inout default-slot lookup now passes that bound. Malformed UTF-8 tags and strings
also fail their new assertions before failable decoding is installed. The two-case
metadata Green passes; Refactor and full 180-case/OBJ-VOX owning refresh follow.

The metadata Refactor passes. The full fixture now selects 182 tests in 22 suites;
two runs failed only the three-second source-queue readiness assertions (different
queue cases). Four isolated moving-camera fairness runs passed in 0.787–1.963
seconds. Other user-owned Swift builds were running concurrently. Independent
inspection found no concrete queue-blocking path; full-suite validation remains
unresolved. Preserve the deadline and assertions, add failure-stage diagnostics,
and rerun before concluding that this is scheduling load.

Optional meshlet/LOD resources now share the root/dependency encoded allowance and
a conservative decoded staging allowance, checked before bounded native reads and
parsing. The first three-case Red observed eight missing-budget assertions; Green
and Refactor passed. An intermediate compile failure exposed an inaccessible
resource-root getter and counts only as infrastructure, not behavioral evidence.
Independent review then found optional resources could displace mandatory textures
and rejected parsing retained a decoded reservation. The next Red observed three
failures using small valid/invalid sidecars and a real textured model. Mandatory
material preparation now reserves its footprint first; rejected parsing releases
decoded memory while preserving the encoded-I/O charge. All five selected tests
pass Green in 1.004 seconds. Refactor and owning regressions follow.

The ignored focused-fixture copier now normalizes source line endings before its
unchanged-content comparison. It still records hashes of the original test bytes;
this avoids rewriting CRLF test copies on every invocation.

The sidecar fallback Refactor passes. The refreshed owning selection passes 267
tests in 50 suites (9.709 seconds), including model, material, image, meshlet,
OBJ/VOX and voxel physics behavior. Layout-only cleanup afterward normalizes LF
in the edited model file and removes an empty line before the sidecar-test closing
brace; assertions remain unchanged. Source-queue failures now include update counts
and public stage diagnostics without changing their deadline or expectations.
Lint passes all 144 currently existing scoped Swift files. Two terrain guide checks
also pass; full profile/platform/GPU gates remain open.

Material schema Red observes unsupported version 3 in both a 32-layer round trip
and actual complete/incremental region saving. The new bounded palette validates
stable IDs, map paths, ranges, weights, fallback/interior/rule references, 32 layers
and 128 rules. Manifest version 3 preserves it through both save modes; versions
1 and 2 keep their prior serialization when no palette is present. The three-case
Green passes. The unknown-version regression advances its future version from
3 to 4 because 3 is now implemented, retaining the same rejection assertion.
This slice stores material definitions; runtime rule evaluation and rendering
remain subsequent implementation work, not inferred from serialization tests.

The material-schema Refactor passes (3 tests, 0.026 seconds). After layout fixes,
lint passes all 147 scoped Swift files and both terrain documentation checks pass.
The complete focused fixture passes 190 tests in 23 suites (63.373 seconds),
including both source-queue tests with their unchanged three-second deadlines and
readiness/buffer assertions. The earlier full-run failures remain documented above;
no queue implementation or deadline was changed to obtain this result.

Actual source-tile material-field Red observes missing canonical ID/weight rows in
both layer orders and the pruning/fallback case. The resolver compiles stable IDs
and rules once per job and evaluates with fixed SIMD storage, keeping at most four
normalized contributions. Canonical full-resolution rows are separate from display
LOD vertices; their staging allowance is reserved before snapshots. The two-case
Green/Refactor pass (including both layer-order arguments). An ambiguous Foundation/
Math acos overload was a compile prerequisite failure, not behavioral Red.

Independent review found false curvature on planar outer edges and material-row
recomputation on LOD-only updates. A diagnostic counter increments around actual
resolver calls, before the next Red; it does not change selection or caching.
The new four-case Red observes four wrong edge/corner classifications and two LOD
updates each making 16900 evaluations and allocating new ID/weight buffers (ten
failed assertions). The fix uses centered halo stencils or available one-sided
second differences, with neutral curvature when only two samples exist. Source
requests retain immutable canonical descriptors from the same generation; revision-
unchanged LOD changes reuse those fields while rebuilding display topology. The
unchanged four-case tests pass Green in 1.367 seconds, including zero evaluations
and stable actual MeshBuffer identities for both LOD changes. Independent inspection
found both fixes addressed; this is interim review, not overall approval.
Lint passes 150 scoped Swift files and diff whitespace checks pass. GPU material
sampling, texture detiling and painting remain upcoming work.

The unchanged four-case material-field Refactor passes. The next complete runtime
selection covers the field-cache integration with existing streaming, sculpting,
replacement/failure and persistence cases. Complete-fixture wrapper logs now use
unique timestamps so later runs retain earlier native evidence; the 190-case log
was archived before changing that ignored wrapper.

The complete source/material-field fixture passes 194 tests in 23 suites (62.837
seconds). The native timestamped log is
`.build-tools/contribution/terrain-complete-20261105T014217229046Z.log`.
The next rendering prerequisite is actual texture-array allocation: existing
backends recognize the array texture kind but allocate one layer. Pinned native
Tint verifies its hash and fresh SPIR-V-to-WGSL smoke using the existing original
tool cache; no third-party source or engine dependency was changed.

Native WebGPU array Red runs on NVIDIA GeForce RTX 4070 (D3D12 driver
32.0.16.1088) and observes one allocated slice for a requested 32-slice descriptor.
The safe capacity assertion precedes out-of-range uploads. TextureDescriptor now
exposes arrayLength; Metal and WebGPU allocate that count for 2D arrays. WebGPU
uses explicit array views even for one slice, and the browser binding layout uses
reflected texture dimensions. The unchanged GPU test passes Green in 1.782 seconds:
production ShaderCompiler/fullscreen draw/readback samples distinct first/last
slice colors in a 32-slice array and the single-slice array correctly. This is
native WebGPU pixel evidence, not Metal or browser execution. The decoder guide
now includes a low-level texture-array initialization example. Independent review
found no concrete regression; further material sampling/detiling remains open.

The texture-array GPU Refactor passes in 2.154 seconds. The next actual source-
material pixel fixture initially omitted Camera3D's render-graph/visibility bundle
and produced an empty frame: its geometry-coverage control failed. Although the
runner accepted an assertion failure, this is fixture prerequisite evidence, not
the intended material Red. The camera now uses the production Camera3D bundle,
then restores its orthographic projection; the coverage control and material
assertions are unchanged. Rerun Red before implementing material rendering.

That retry still failed coverage because the fixture's Euler helper oriented the
patch around a different axis, leaving it edge-on. The fixture now uses an explicit
X-axis quaternion and requires its transformed up vector to face the camera.
Neither empty-frame attempt counts as intended product Red; no unrelated math
implementation is changed. Retain both logs and rerun with the coverage control.

The next full-frame attempt exposes a real scheduler integration defect before
pixel assertions: TerrainPhysicsReadinessSystem declares a required ordering edge
to Physics3DSyncSystem even when Physics3DPlugin is absent. Prior focused terrain
tests drove preUpdate rather than the fixed pipeline. Keep physics optional; add
an explicit optional ordering relationship without weakening existing required
dependencies, and test the model-only fixed phases before resuming material Red.
The GPU scheduler-assertion log is infrastructure evidence for the material slice.


Optional physics scheduling now uses explicit `afterIfPresent`, preserving mandatory
missing-target diagnostics. Model-only fixed phase Green/Refactor passed. Independent
review exposed stale graph edges after optional target removal; new real execution
coverage reproduced counters 2 instead of 3 in both single/multi executors. Clearing
edges before relinking passes unchanged lifecycle Green/Refactor (0.003s). Read-only
independent review found no further scheduling defects. Scripting exhaustive consumers
preserve optional dependencies; owning suites remain to run. Native texture arrays
passed GPU Green/Refactor; complete terrain runtime previously passed 194 tests/23
suites in 62.837s before these scheduler/renderer changes. No whole-feature completion
or cross-platform renderer validation is claimed.


Actual terrain material Red now passes geometry coverage and fails only the three
expected tint/blend assertions (7.216s). The first renderer Green exposed a binding50
collision with existing distance-field constants; independent review identified it.
Terrain constants now use unused binding51. The unchanged full-frame GPU test passes
in 3.233s on the RTX4070: red/blue height layers and continuous purple tile-border
blend. This first slice shades layer tints and PBR scalars from immutable per-tile
RGBA8 slot/weight fields, built inside tile publication budgets and retained across
LOD changes. Texture-map arrays, detiling, projection and broader SDF-lit pixels are
still open. Review also found color-only update and palette-removal lifecycle gaps;
add behavioral regressions and fix them after this slice's Refactor.


The first tint-field GPU Refactor also passes. New source lifecycle Red reproduces
three expected assertions: stale color, retained terrain bindings after palette
removal, and retained old material identity. Updating existing tile factors on
color edits and explicitly selecting the plain fallback for a palette-free new
manifest passes unchanged Green (0.445s); mesh/field identity controls pass too.
The user article now describes actual tint/PBR-scalar behavior and explicitly marks
texture-map/detiling/projection settings as not rendered yet.


Lifecycle Refactor passes (0.381s); independent read-only re-review finds no further
concrete defects in binding51, color propagation, plain reload or LOD field reuse.
Whitespace-only test layout cleanup follows the completed cycle. Additional optional
scripting validator characterization covers absent targets, different schedulers,
registered targets, self-dependency and cycles; it expands coverage of the earlier
optional-dependency Red rather than claiming a manufactured new Red.


Broader native owning command `swift test --scratch-path .build --jobs 8
--force-resolved-versions --filter AdaECSTests|AdaScriptingTests|Terrain` runs 683 tests
in 116 suites (104.357s): all reported issues are three scripting assertions.
Optional validator characterization and terrain tests pass. Isolated skip-build
rerun on the unchanged binary reproduces the same three issues in 0.151s.
Independent inspection finds InputResourceBindingTests' two assertions already
omit mandatory AdaScriptVMExecution read/write access present in task base; the
save-read result-predicate failure is still being traced. Neither result is counted
as a passing owning suite or as a timing-only failure. Latest lint:169 files clean.
Next GPU test adds real PNG-backed layers alongside the existing tint-only control.


PNG-backed material GPU Red passes coverage and the tint-only control, failing only
three expected color assertions for textured=true (10.341s). After implementing
bounded raw-image loading, shared prepared mip palettes and array albedo shading,
unchanged GPU Green passes both cases (7.254s). The first Green attempt only exposed
raw Asset protocol/direct-return API compile prerequisites, not behavioral evidence.
Encoded bytes, conservative decoded staging and derived/new/retained array generations
now share the same remaining source mesh budget before allocation. Prepared palettes
survive camera residency, LOD and save adoption, while immutable GPU arrays reuse a
source UUID. Missing/incompatible maps produce bounded warnings and usable fallbacks.
Normal/ORM inputs are prepared but not sampled by the surface shader yet; blend-height,
detiling and projections remain open. Independent review found warnings are lost by
physics status reconstruction; reproduce and fix that after this Refactor.


The actual PNG/tint array GPU Refactor passes. Two documentation files contained
mojibake introduced by locale-default Python reads; a reversible CP1252/UTF-8
repair restores their original typography. All subsequent scripted text reads use
explicit UTF-8. No production Swift/shader files required this repair. The article's
old single-color limit is updated to match the tested source palette renderer.
Next regression covers a missing-map warning followed by real physics synchronization.


Missing-map/real-physics Red reproduces exactly the lost-warnings assertion (0.819s),
with ready source/collision controls passing. Forwarding warnings through readiness
status reconstruction passes unchanged Green (0.371s). Independent review also
finds a separate P1: the 8192-entry WebGPU bind-group cache strongly retains old GPU
array/field owners across palette generations, beyond the source lifetime budget.
Reproduce actual GPU allocation release with shadows/contact disabled, then prevent
transient terrain field bindings from entering that long-lived cache. Normal/ORM
surface shading and incremental texture upload scheduling remain open.


Warning preservation Refactor passes (0.306s). The new actual WebGPU allocation
lifetime Red reproduces both expected retained objects after three palette reloads,
source removal, eight clean frames and completed readback (4.193s). Render coverage,
reload adoption and source-state cleanup controls pass. Derived terrain field/array
textures now explicitly opt out of long-lived bind-group ownership, preserving
ordinary static-texture caching and avoiding a count-only cache silently exceeding
source generation budgets. This does not recreate meshes/materials on idle frames;
terrain bind groups use the renderer's existing uncached encoding path.


The unchanged real WebGPU allocation-lifetime test now passes Green (3.481s): both
obsolete albedo-array and canonical-field GPU owners release after reload/removal
and completed GPU work. Ordinary texture caching retains its prior policy; only
source-budgeted derived terrain textures disable persistent cache ownership.


GPU allocation lifetime Refactor passes in 2.689s. Next actual source pixel slice
selects normal/roughness/metallic debug targets with real PNG normal and ORM maps,
including non-unit layer factors, to establish map consumption in shared PBR.


Normal/ORM GPU Red passes coverage and fails exactly normal, roughness and metallic
assertions (6.721s). Shared normal and ORM arrays now shade the strongest four
contributions with explicit gradients; tangent normals use the existing PBR
cotangent frame, and linear G/B channels multiply layer factors. Default ORM is
white so absent maps preserve authored factors. R feeds the shared PBR surface AO
path. Unchanged three-case GPU Green passes in 8.092s. AO-lit/SDF-lit pixel coverage
is still open, as are detiling, triplanar projection, blend-height and upload pacing.


Normal/ORM Refactor passes (7.223s); independent read-only review finds no additional
concrete shading/binding/lifetime defects in this slice. Common GPU scene setup is
now shared before adding AO coverage; existing assertions and production source
paths remain unchanged. The AO test characterizes the R-channel path already
implemented by the preceding normal/ORM Red/Green, rather than fabricating a new Red.


Shared-fixture material GPU suite passes 7 tests/3 suites (17.696s), including actual
AO-dependent indirect-light pixels after replacing only ORM.R. Add non-debug PBR
coverage with an enabled empty SDF field to verify independent terrain/SDF uniform
bindings; this characterizes the prior binding51 fix rather than manufacturing Red.


Current full material GPU suite passes 8 tests/3 suites (16.345s), including enabled
empty-SDF/non-debug PBR compatibility. Root CPU/ECS runtime regression passes 381
tests/51 suites (58.563s) on the unchanged compiled binary. User-doc offline catalog
checks pass 2 tests; latest scoped lint171 files and diff whitespace checks pass.
Full scripting owning run retains its three separately recorded baseline issues.
Next TDD slice adds persisted opt-in stochastic texture controls with full UInt64
seeds, flips/rotations/offsets and bounded cell/macro settings; shader use follows.


Variation metadata Red reproduces 16 assertions (lost full seeds/settings across
input and both save modes, plus invalid ranges accepted). Unchanged two-test Green
passes in 0.039s after adding disabled-default Codable settings and layer validation.
Read-only independent review finds no schema/compatibility defect. Refactor removes
an unused import. The frozen tests retain two NSNumber style violations until this
cycle completes; convert to exact Swift UInt64 values afterward and revalidate
without changing expected values or claiming new behavioral Red.


Variation metadata Refactor passes (0.028s). Tests now use exact Swift UInt64
values instead of Objective-C NSNumber wrappers for style, retaining all expected
values. The next GPU Red includes these native-save tests as controls, plus an
asymmetric repeating map: enabled variation must break the grid, remain invariant
under translating owner and camera together, and reorient a constant tangent normal.


Actual variation GPU Red reproduces two enabled-case failures (periodic error zero
and unchanged tangent normals); disabled, local-translation and persisted-seed
controls pass (7.374s). Smooth four-neighbor affine randomization now transforms
albedo/normal/ORM UVs and explicit gradients together; normals return through the
transpose of the same orthogonal transform. Stable layer IDs and both seed halves
feed the hash, independent of chunk/camera IDs. Low-frequency seeded macro color
variation uses local coordinates. Unchanged GPU/native-save Green passes 3 tests/
3 suites in 5.955s. Review finds a separate accepted-extreme-scale arithmetic hole
(subnormal macro/layer scales can yield non-finite shader coordinates); reproduce
and bound/filter that after this Refactor. It is not treated as completed safety.


Stochastic variation Refactor passes 3 tests/3 suites in 4.748s. Next safety Red
uses accepted subnormal macro/layer scales on real GPU output. Macro sampling below
representable resolution should filter to neutral modulation, including zero
strength; unresolved layer UVs should use the coarsest prepared mip, not NaN/black.


Extreme-scale Red reproduces macro modulation and layer-color errors with accepted
subnormal scales; the zero-strength control passes (10.234s). Double coordinate
preflight and finite shader fallback now pass all three unchanged cases (11.445s).
Unresolved layer UVs sample actual last mip levels; unresolved macro modulation
uses its neutral filtered value. No non-finite UV/gradient is passed into sampling
or floor/mod/hash conversion for these admitted height tiles. Existing normal
scale paths retain their prior transforms and sampling.


Extreme-scale Refactor passes. Independent re-review confirms the tile-bound and
cell-scale guards, and identifies another distinct preflight hole: reciprocal
sample spacing can overflow the field-grid UBO. The next direct production-upload
regression reads actual uniform bytes and requires finite grid values or a clear
typed unsupported-spacing error, with ordinary spacing as a control.


Grid-UBO Red reads actual upload bytes and finds non-finite grid addressing for
spacing1e-40; spacing1 remains a control (0.259s). An earlier attempt hit a Swift
Testing key-path/rethrows macro compile issue, fixed in the fixture before valid
Red. Shared reciprocal-spacing preflight now runs before material preparation and
at the actual upload boundary; unsupported spacing reports a typed diagnostic.
Unchanged two-case Green passes in 0.188s. Refactor also checks positive/finite
spacing in the helper and clarifies the local grid-scale name.


Actual grid-UBO Refactor passes (0.143s). Independent read-only re-review finds no
further concrete arithmetic issue in the canonical heightfield material path.
Run the combined native material/texture GPU profile after all variation/safety
changes, then refresh owning CPU terrain/ECS validation before the next capability.


Combined real native WebGPU material/texture profile passes 13 tests/4 suites in
31.911s after all stochastic and finite-coordinate fixes. It includes32/single-slice
array allocation+pixels, old palette GPU release, albedo/normal/ORM/AO, empty-SDF
non-debug compatibility, variation/motion/normal controls, extreme scales and native
manifest settings. Updated scoped SwiftLint passes172 files; documentation catalog
checks pass2 tests. Refresh CPU terrain/ECS on this compiled snapshot next.


Current CPU/ECS snapshot passes386tests/51suites in61.602s after stochastic and
finite-coordinate fixes. Next GPU Red uses a slope4cliff and a one-axis stripe map:
triplanar X-axis projection should remain constant along surface X while planar
mapping repeats. Both modes must preserve the actual geometric normal with a flat
normal map, preventing an axis-biased/faceted normal blend.


First triplanar Green fixes projection but fails the flat-normal blue channel.
Inspection finds pre-existing Transform3D.transpose reconstructs its original rows
and returns the input matrix. Terrain's new transform cache now explicitly builds
rows from inverse columns, obtaining the required inverse transpose without changing
unrelated Math APIs. Keep the unchanged actual scene normal assertion and rerun
Green. Review separately identifies varying-normal interpolation under nonuniform
scale; add that regression after this basic projection cycle completes.


The corrected explicit inverse-transpose makes unchanged basic triplanar GPU Green
pass (4.936s): projected cliff stripes and flat-map geometric normal controls.
Terrain reuses its unused tangent varying slot, and a pose-keyed immutable binding52
normal matrix avoids chart-dependent transforms under owner scale. Independent
review still requires curved/ridged varying normals under nonuniform scale: applying
M after interpolation differs from the vertex-normalized geometric baseline. Add
that real GPU regression after this basic Refactor before treating triplanar normals
as complete. No whole-feature or full projection-transform coverage is claimed.


Basic triplanar Refactor passes4.791s. Next real GPU regression compares flat maps
against existing planar geometric-normal interpolation on a ridge with ownerScale
(1,4,1), for pure triplanar and mixed planar/triplanar layers. This targets the
reviewed interpolation-order defect rather than the already-tested planar slope.


Scaled-ridge Red reproduces2normal RGB mismatches, pure and mixed projection modes
(8.814s). Anchoring Input.ViewNormal and transforming only the local normal-map
perturbation passes unchanged Green9.568s. This preserves the vertex-normalized
interpolation convention under nonuniform scale while avoiding chart selection.
Keep non-flat map/normal-dominance crossover and reflected-pose coverage pending.


Scaled-ridge Refactor passes8.552s; independent re-review finds no further concrete
issue in the zero-perturbation baseline fix. Added characterization for a non-flat
map with near-tied3axis normals under scale(2,3,4), followed by reflected X scale.
This exercises the already-implemented projection-independent matrix path without
manufacturing Red. Run all material/texture GPU tests after the expanded coverage.


Height-map GPU Red reproduces absent height influence and missing-map warnings
(2issues/10.105s); unchanged Green9.010s and Refactor pass. Decode the fourth input
family under existing encoded/decoded budgets, pack linear height into ORM alpha,
and enable only successfully decoded IDs. Independent review catches discontinuity
in the initial maximum-score threshold formula as a third layer fades. Replace it
with strictly positive bounded multiplicative bias exp2(8*(height-.5)); missing maps
supply exact neutral .5. Equal heights preserve ratios; zero-weight influence tends0.
The three-layer regression initially compared sRGB debug pixels with linear weights.
Its post-fix failures therefore are not valid behavioral evidence. Correct the
fixture color-space conversion and characterize the fixed path without claiming
unchanged-test Green for that cycle; retain both original logs for review.

Corrected linear-color three-layer regression and original two-layer height/missing
map tests pass together:2tests/2suites14.469s. The independent reviewer confirms
the bounded bias's positive-denominator and continuous zero-weight properties.
Shared GPU fixture is now separate; staging includes both new files. Refresh the
complete texture/material GPU profile before continuing surface-paint persistence.


Complete texture/material GPU profile passes18tests/4suites71.512s, including
heightblend, missing maps, detiling, triplanar transforms and GPU lifetime.
Native surface/mask slice: initial test prerequisites exposed that AdaAssets has no
SwiftPM product; use the actual root owning target/private worktree scratch. Valid
ADATRN03 is rejected before production changes. Explicit Swift Testing requirements
record2behavioral Red issues; unchanged Green passes2tests. Add sparse64-byte
surface and8-byte mask sections with bounded table/record validation and exact bits.
Old height/placement-only encodings remain unchanged. Independent review identifies
sliced-Data indexing before application; reconstruct legacy payloads from zero-based
reader bytes. Add typed mixed-section/sliced-Data characterization after Green;
this coverage exercises already-implemented prevention, not a fabricated Red.
Runtime storage/cache/edit/material integration remains pending.

Surface asset Refactor passes4tests/.017s, including typed mixed sections and
nonzero-index Data. Cache admission Red exposes9expected issues across paint,
mask and combined payloads; legacy Codable control passes. Charge actual decoded
MemoryLayout strides under a separate32MiB default budget, reject before counter
publication, expose statistics and release charges on eviction. Unchanged Green
passes2tests/.138s. Independent cache arithmetic/compatibility review finds no
further concrete issues. Continue unchanged Refactor before storage integration.


Cache Refactor passes2tests/.082s. Canonical storage Red7issues/.018s reproduces
lost surface import/export, surface-only invalidation and shared-edge pruning.
COW canonical64cell sparse pages, separately bounded conservative hash/COW charges,
resource export and residency revisions pass unchanged Green3tests/.019s and
Refactor3tests/.017s. Independent review catches P1: pruning used physical-only
coverage and deleted hidden normal-only neighbors. Exact runtime residency regression
Red1issue/.004s reproduces deletion; both callbacks now include normal coverage,
matching existing height-page pruning. Unchanged Green1test/.003s passes. Retain
hidden draws and unchanged row generations; finish Refactor and re-review before
feeding native overrides/masks into canonical material resolution.


Normal-only pruning Refactor passes; independent re-review clears the P1.
Native material runtime Red5issues/.576s reproduces ignored masks/paint and silently
accepted missing active layer IDs. Immutable canonical surface lookup plus a throwing
resolver overload merges normalized automatic4 and manual4 contributions in fixed
SIMD storage, prunes deterministically and retains the original nonthrowing resolver.
Actual mask lookup defaults to0. Unchanged Green2tests/.280s passes full/partial
paint, half-weight mask, identical shared-border rows and missing-layer rejection.
Independent review finds no further concrete issues; no per-sample collection
allocation was introduced. Finish Refactor, then refresh broader owning CPU tests.


CPU material Refactor passes2tests/.325s. Supplemental negative/grid-limit material
addressing and custom storage-budget/snapshot checks pass in the full root terrain
filter:227tests/32suites63.683s. This is focused terrain ownership coverage, not a
claim that all root tests or the known unrelated scripting failures passed.
Next actual GPU regression adds native layer paint control plus tint/roughness
scenarios. The shared fixture writes real surface records into native assets;
Albedo assertions convert display sRGB to linear, roughness debug stays scalar.


Actual native layer/tint/roughness GPU Red reproduces2ignored-channel issues while
layer and outside controls pass(7.862s). Canonical premixed tint/premultiplied
roughness plus a separate mask share an optionalRGBA8vertical atlas at existing
main-pass binding17. Unpainted tiles use one neutral1x2 fallback. Upload disables
binding caching for derived atlases; preflight reserves another64bytes per canonical
vertex only on affected tiles before allocation. Unchanged Green3cases8.042s and
Refactor pass. Independent review finds P2: camera/LOD budget work walks all
unchanged layer-only paint samples despite retained canonical fields.
Instrument actual old preflight-loop visits in SourceBuild/State; regression with
16384native records observes36864visits perLOD change(Red2issues/.777s), while
retained IDs/evaluation-zero and exact edge/corner/negative/partial controls pass.
Cache optional64UInt64 coverage bits per immutable cell, rebuild after sample
pruning, retain with COW UUIDs; increase conservativecellcharge to1024. No authored
record iteration remains in coverage queries. Unchanged Green2tests/.679s passes;
independent re-review clears P2. Finish Refactor then rerun full material/texture GPU
and terrain CPU profiles. Do not infer whole-feature completion from these slices.


Coverage-cache Refactor completes; full texture/material GPU passes19tests/4suites
70.580s; full root terrain CPU passes230tests/33suites61.101s; lint189clean,
actual offline catalog regenerated/verified27guides, docs2tests pass, diffcheck clean.
Next native paint admission regression exposes4issues/.066s: data-only active paint
IDs bypass palette validation. Cache now validates active references once on admission
against its immutable manifest ID set, after memory guards and before publication;
cached reuse avoids repeated validation. ValidID and earlier-resident controls pass;
unchanged Green completes. Independent review clears this admission slice.
Review also confirms P1 in existing runtime persistence plumbing: new channels are
absent from dirty override capture, payload reconstruction, save baselines/removal,
acknowledgment and streaming reconstruction. Prepare real source save/stream and
boundary-only payload regressions before changing that path; fullfeature remains WIP.


Palette admission Refactor passes. Persistence P1 Red reproduces6issues/.791s in
real save/stream/revisit and boundary-only last-height erasure. Carry surface+mask
arrays through override capture, native reconstruction, save payload/baseline,
removal checks and acknowledgment; explicit empty arrays retain erasure semantics.
Charge decoded override records and subtract from the forked cache surface allowance.
Unchanged Green2tests/3cases/.829s passes; independent review clears the P1, requesting
late-ack coverage. Add actual immutable disk snapshot plus subsequent COW channel
change characterization (paint and mask separately), assert later values stay dirty
and next snapshot retains them while disk contains captured old values. This tests
the already-fixed acknowledgment branch without inventing a separate Red.

### Editor authoring safe-point correction (2026-11-06)

The first authoring Green attempt compiled and saved the private-version test, then crashed during cancellation. Symbolizing the native stack identified `QueryState.updateArchetypes` iterating while the asynchronous editor helper directly mutated ECS structure. The helper now requires the owning `AppWorlds`; every grouped ECS snapshot/read/write uses its existing `withWorldAccess` boundary, while filesystem and worker waits leave frames running. Tests now run each explicit `.preUpdate` within `withExclusiveWorldAccess` to exercise that same host contract. Their behavior assertions remain unchanged, but these test bytes differ from the earlier Red: subsequent passes are retained production-path coverage, **not an unchanged Green for that earlier cycle**. No generic ECS synchronization rewrite is included.
