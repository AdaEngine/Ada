# GPU-Driven Shadow Batching

Status: Implemented on WebGPU (native and browser); native Metal and headless keep the CPU path.
Approval: explicit user approval in this Claude Code conversation on 2026-11-09 ("Ok, lets do that!").
Revision 2 (2026-11-09): updated to the implementation after review; the human accepted the deviations
listed in §10 ("Accept, update design").
Date: 2026-11-09.
Classification: improvement of an existing subsystem (shadow rendering, ADR-0018 / ADR-0020).
Evidence: [Sponza flying-lights measurements](../Performance/SponzaFlyingLights-2026-11-08.md);
Bevy 0.20-dev (`bevy_pbr/src/render/light.rs`, `bevy_light/src/lib.rs`, `mesh_preprocess.wesl`).
Existing contracts: [ADR-0018 local lights and shadow scheduling](../ArchitectureDecisions/0018-local-lights-and-shadow-scheduling.md),
[ADR-0020 GPU visibility](../ArchitectureDecisions/0020-gpu-visibility-and-animation-lod.md).
Plan: [2026-11-09-GPUDrivenShadowBatching.md](../Plans/2026-11-09-GPUDrivenShadowBatching.md).
Proposed follow-up: [Incremental mesh extraction and directional cascades](incremental-mesh-extraction-and-cascades.md).

## 1. Problem

Moving shadow-casting lights are CPU-bound. In the Sponza atrium (720p, WebGPU/D3D12, RTX 4070),
four moving point lights cost 12.8 ms per frame against 7.6 ms with no moving lights. Lowering the
resolution to 320×180 does not make either case faster.

A moving light changes its six face matrices every frame, so all 24 faces are rebuilt and redrawn:

| Per-frame CPU work (4 lights, after `ShadowBatchEncoder3D`) | Cost |
| --- | ---: |
| `VisibleMesh3DLists.prepare`: 24 lists, each rebuilt from every source, plus instance upload | ~1.6 ms |
| Recording ~2,330 shadow draws (~97 per face) | ~3.5 ms |

The GPU has spare capacity. The cost scales with *faces × draws per face* on the CPU.

## 2. Decision

Move the per-face work for ordinary static casters to the GPU, as Bevy does:

1. **Registry, kept between frames:** static casters are registered once; uploads happen only on change.
2. **One compute pass culls for every shadow view** and writes the indirect draw arguments.
3. **One multi-draw per draw group and view,** with no per-mesh CPU work, where the adapter supports it.

The image must stay exactly the same. Casters that the GPU path cannot reproduce exactly stay on
today's CPU path (§4.6).

Settled during Enrich (2026-11-09):

| ID | Decision |
| --- | --- |
| E1 | Covers point faces, spot maps and directional cascades, which already share `ShadowBatchEncoder3D`. |
| E2 | Shadow geometry goes into **shadow-only shared buffers**. Mesh storage for other passes is unchanged. |
| E3 | Without multi-draw support: **one `drawIndexedIndirect` per mesh part**, same GPU culling, same image. |
| E4 | Target: shadows near-free on the CPU (§7). Reaching 144 fps overall also needs the separate main-pass work. |

## 3. Goals and non-goals

| ID | Goal |
| --- | --- |
| G1 | Identical shadow maps and final frames compared with the CPU-culled path. |
| G2 | CPU cost of shadow faces does not grow with the number of static casters (with multi-draw). |
| G3 | Caster changes (add, remove, move, material, visibility, `castShadows`) show up in the same frame. |
| G4 | Correct on every backend. The GPU path runs on WebGPU (native D3D12/Vulkan/Metal through Dawn, and the browser); native Metal and headless use the CPU path with the same image (§10). |

Non-goals:
- Time-sliced or lower-rate shadow updates: these lag visually and are rejected.
- Main-pass batching.
- Moving all mesh storage into shared buffers.
- GPU LOD selection.
- Shadow occlusion culling with Hi-Z.
- GPU culling on native Metal in this change (§10).

## 4. Design

### 4.1 Caster registry (`ShadowCasterRegistry3D`, AdaCorePipelines)

A render-world resource that persists between frames. A caster is one instance of one mesh part.

- **Per caster:** world bounds (or "always visible"), its pooled part and an instance record
  identical to the CPU path's shadow record (model matrix, base colour × instance tint, zero
  material/texture/shadow flags).
- **Update rules:**
  - The first shadow node of a frame rebuilds the caster arrays from the extracted sources; the second
    node of the same frame reuses them (detected through the material frame counter).
  - The arrays are compared with the previous ones. Only a change increments `revision` and uploads
    the input; it also records the old and new bounds of every changed caster (`changedBounds`), or
    `nil` when the change cannot be bounded (pool rebuild).
- **Cost:** a frame with nothing changed costs one array build and compare per caster, independent of
  the number of faces and lights; nothing is uploaded.
- **Availability:** the registry builds nothing on devices without GPU shadow culling
  (`RenderDevice.supportsGPUShadowCull`) or with `ADAENGINE_SHADOW_GPU=0`; it then releases its pools.

### 4.2 Shadow geometry pool (inside the registry)

Every eligible mesh part's original vertex and index bytes are copied on the GPU (`copyBufferToBuffer`)
into one shared vertex/index buffer pair **per vertex layout**, addressed with `baseVertex` / `firstIndex`.
Shadow pipelines are already specialised per vertex layout, so the CPU path's pipeline is reused and the
shader inputs are byte-identical. Meshes always use 32-bit indices; a part without them keeps the CPU path.

- **Lifetime:** parts are keyed by their source buffers and kept alive by the pool. New parts are
  appended. A full pool, or a pool with more than 4 MiB of parts unused for 300 frames that make up
  over half of it, is rebuilt into new buffers by copying its live parts again; frames in flight keep
  reading the old buffers. Freed ranges are not reused in place.
- **Memory:** the source geometry size, plus up to 50% headroom (at least 64 KiB per buffer).
  `ShadowCasterRegistry3D.pooledBytes` exposes the size; it is not yet published in
  `Render3DPerformanceMetrics` (§10).
- **Limit:** a layout whose shadow geometry would exceed 256 MiB (baseline WebGPU `maxBufferSize`)
  sends every caster to the CPU path.
- **Copies** are encoded at the start of any shadow pass, so they never accumulate.

### 4.3 GPU culling (`GPUShadowCullProcessor`)

Each frame one dispatch covers (shadow view × caster) for every view that redraws: dirty point/spot
faces and all cascades. Faces kept by the existing face reuse are not culled. For each pair the pass:

1. **Tests the caster against the view** with the same planes and bounds as `MeshVisibilityFrustum3D`,
   with a small relative tolerance toward drawing, so it never rejects a caster the CPU test keeps. An
   extra draw of an off-face caster is clipped or discarded by the atlas tile bounds and changes no pixel.
2. **Copies the surviving instance record** (the first 128 bytes the shadow shaders read) into a compacted
   per-(view, part) segment with an atomic counter, the scheme `WGPUVisibilityProcessor` already uses.
   The CPU writes each (view, part) `IndexedIndirectArguments` with instance count 0 beforehand.

The processor is created by the render device, like the existing visibility processors. The WebGPU
implementation is WGSL in `AdaRender` (`WGPUShadowCullProcessor`). Native Metal and headless return no
processor (§10).

### 4.4 Drawing

The shadow shaders are unchanged: instances are read from the compacted buffer at vertex slot 3.

Opaque casters do not depend on their material except for **single- vs double-sided** and the alpha
mode, which the fragment shader reads from the material uniform. Each opaque draw group therefore binds
the material buffer of one opaque member with the same sidedness. Draw groups are:

- **Opaque:** one group per vertex layout and sidedness.
- **Alpha-masked (non-graph):** one group per vertex layout, material buffer and base-colour texture.

Per shadow view, after the CPU-path batches, the encoder sets each group's pipeline, resources and pool
buffers, then:
- **With multi-draw** (`multi-draw-indirect` and `indirect-first-instance` on the adapter): one
  `multiDrawIndexedIndirect` over the group's consecutive arguments; each argument carries its segment's
  `firstInstance`.
- **Without it:** one `drawIndexedIndirect` per part, with `firstInstance` 0 and the instance buffer bound
  at the segment's offset (decision E3). A zero instance count is a GPU no-op.

Draw order does not affect the result: the shadow passes use a strict depth test and write the
fragment depth, the property `ShadowBatchEncoder3D` already relies on.

### 4.5 Backend additions (AdaRender)

- `RenderCommandEncoder.multiDrawIndexedIndirect(arguments:offset:drawCount:) -> Bool`; `false` when
  unsupported (default, Metal, headless, browser).
- `RenderDevice.supportsMultiDrawIndirect`, `supportsGPUShadowCull`, `createGPUShadowCullProcessor()`.
- WebGPU requests `multiDrawIndirect` and `indirectFirstInstance` when the native adapter has them.
- `ADAENGINE_SHADOW_GPU=0` forces the CPU path; `ADAENGINE_SHADOW_MULTIDRAW=0` forces the E3 fallback.

### 4.6 Casters that stay on the CPU path

These keep the current `VisibleMesh3DLists` + `ShadowBatchEncoder3D` path, because their per-view
result depends on CPU state the GPU path would not reproduce exactly:

| Caster | Reason |
| --- | --- |
| Skinned or morphed | Per-frame palettes and morph weights; small counts in practice. |
| Shader-graph alpha-masked | Needs the graph's own pipeline per material. |
| Has LOD alternatives | LOD selection uses per-view hysteresis on the CPU. |
| Finite `maximumDistance` | The distance fade drives the dither pattern per view. |
| Part without 32-bit indices, or with an unaligned vertex buffer | Cannot be pooled by a buffer copy. |
| Blend materials | Do not cast shadows; unchanged. |

`VisibleMesh3DLists` only sees the CPU-path sources, so the per-face rebuild shrinks to them. Both paths
draw into the same face in one render pass. If GPU culling cannot be encoded for a frame, the dirty
faces are rebuilt from every caster on the CPU path instead.

### 4.7 Face reuse

A point/spot face kept from an earlier frame stays kept only if its matrix and CPU-path content are
unchanged and no GPU-path caster changed inside it: the registry's `changedBounds` (old and new bounds)
are tested against the face frustum. An unbounded change, a switch between paths, or a missed revision
redraws every face.

### 4.8 Ownership

| Module | Changes |
| --- | --- |
| AdaRender | Multi-draw encoder method, capabilities, cull processor protocol and WebGPU implementation, WebGPU feature request, index buffers usable as copy sources. |
| AdaCorePipelines | Registry and pools, `GPUShadowCull3D` helper, changes to `LocalShadow3DRenderNode` / `DirectionalShadow3DRenderNode`. |
| AdaScene | None. |

## 5. Alternatives considered

| Alternative | Why not chosen |
| --- | --- |
| Record draws once into render bundles and replay them per face | Removes recording cost but not culling; a bundle is invalid whenever a caster changes; it helps no other pass; Bevy does not use it. |
| Shared buffers for all passes (full Bevy mesh allocator) | Also speeds up the main pass, but changes import, every pass and memory ownership; decided against in E2. |
| One converted shadow vertex layout for all parts | Needs new shader variants and CPU-side conversion; per-layout byte copies reuse existing pipelines with identical inputs. |
| Draw every cube face in one pass with instancing ×6 | Needs clip-distance support (optional in WebGPU) and an atlas change; does not remove culling. |
| Time-sliced moving-light shadows | Visual lag; rejected by the requirement of no visual downgrade. |

## 6. Risks

- **Exactness:** the GPU frustum test must never reject a caster the CPU path draws; tested against the
  CPU test with randomized views and bounds (A2).
- **Driver support:** without multi-draw the CPU gain is small (§9); the fallback keeps the image.
- **Memory:** a second copy of static shadow geometry with headroom; layouts above 256 MiB use the CPU path.

## 7. Acceptance criteria

| ID | Criterion | Result |
| --- | --- | --- |
| A1 | Full WebGPU validation gives the same issue list and differing-pixel counts as before, with the GPU path on, multi-draw forced off, and the GPU path off. | Met (348 tests, identical 25 pre-existing issues in all three modes). Metal goldens: blocked, no Mac. |
| A2 | Per-view GPU cull results include every caster the CPU frustum test keeps. | Met (`shadowCullKeepsEveryCasterTheCPUFrustumTestKeeps`). |
| A3 | Frames are bit-identical between CPU and GPU paths for opaque, single/double-sided, masked, instanced and mixed CPU-path casters, culled and reused faces. | Met (`GPUShadowBatchingSceneTests`, multi-draw on and off). |
| A4 | Add, remove, move, material change and `castShadows` are reflected; pool growth and rebuild keep parts addressable. | Met (`ShadowCasterRegistry3DTests`). |
| A5 | Sponza atrium, 720p, release, WebGPU/D3D12, RTX 4070: (4 moving lights) − (no moving lights) ≤ 1.0 ms, from 5.2 ms. | ~1.1 ms (8.42 vs 7.34 ms, 2 rounds, multi-draw active); accepted (§10). |
| A6 | `check_contribution.py` passes; Metal build and goldens on macOS. | Blocked: no Mac; full Editor rebuild not run while GitHub artifact downloads failed. |

## 8. User documentation

Internal performance improvement with no new public API. User-facing effect and switches:

- `Documentation/RenderingFoundation.md`, **Shadow casting cost**: GPU culling, CPU-path casters,
  multi-draw dependence, backends, memory and limit, switches.
- `Documentation/Tooling.md`, **GPU-driven shadows**: the two environment variables.

## 9. Measured result

| atrium, 720p, Hi-Z off | ms/frame |
| --- | ---: |
| No flying lights | 7.34 |
| 4 flying lights, GPU path + multi-draw | 8.42 |
| 4 flying lights, GPU culling, one indirect draw per mesh | 14.07 |
| 4 flying lights, GPU path off | 14.57 |

## 10. Accepted deviations from revision 1

Accepted by the human on 2026-11-09:

- Native Metal gets no GPU culling processor; it keeps the CPU path (same image, no speedup).
- The compute shader is WGSL in `AdaRender` instead of shared GLSL in `AdaCorePipelines`.
- The pool copies original bytes per vertex layout instead of one fixed shadow layout, and reclaims
  space only by rebuilding.
- Opaque sidedness is handled by per-sidedness draw groups instead of a per-instance flag.
- Pool size is not yet reported in `Render3DPerformanceMetrics`.
- A layout over 256 MiB sends every caster to the CPU path.
- A5 measured ~1.1 ms against the 1.0 ms target; without multi-draw the gain is small.
