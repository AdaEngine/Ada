# Meshlet Culling for Shadow Views

Status: Approved — implementation in progress.
Approval: explicit user approval in this Claude Code conversation on 2026-11-10 ("Approve, build it"). Shadow LOD (§6) is not approved and stays out of scope.
Date: 2026-11-09.
Classification: improvement of existing subsystems (shadow rendering and meshlets).
Extends: [GPU-driven shadow batching](gpu-driven-shadow-batching.md),
[ADR-0028 meshlets and portable cluster culling](../ArchitectureDecisions/0028-meshlets-and-portable-cluster-culling.md)
(which lists "independent meshlet culling of shadows" as later work),
[ADR-0018 local lights and shadow scheduling](../ArchitectureDecisions/0018-local-lights-and-shadow-scheduling.md).
Related: [pipelined rendering](pipelined-rendering.md), whose §8 render-path cuts this continues.

## 1. Problem

The Sponza demo should hold 140+ FPS (≤ 7.0 ms per frame) on an RTX 4070 (WebGPU/Dawn D3D12).
Views that face the scene run at 85–105 FPS and are GPU-bound: per-command-buffer timestamps
(`ADAENGINE_GPU_TIMINGS=1`, added during this investigation) show the queue busy 900–960 ms per second.

| GPU work per frame, heavy view, 1890×784 | ms |
| --- | ---: |
| Local shadows (moving point light, ~5.5 faces redrawn, ~39 draws) | 4.3 |
| Main pass (meshlet culling and LOD) | 3.0 |
| Sun shadow (3 cascades) | 2.3 |
| UI, upscale, SSR composite | 0.1 |
| **Total** | **9.7** |

The scene has 8.8 M triangles. One ivy part holds 4.9 M of them, and the 75 parts above 20 K
triangles hold 92%. The main pass culls 96-triangle clusters per view and selects meshlet LOD.
Shadow views do not: they cull whole parts (on the CPU, or per caster on the GPU), and a large part
that touches a face or cascade draws all its triangles. The ivy spans the atrium, so it is drawn whole
in nearly every shadow view.

## 2. Decision

Cull **meshlet clusters** for shadow views on the GPU, and draw only the surviving clusters.

1. Large static meshlet-ready parts (§4.1) leave the per-caster shadow path and become **cluster casters**.
2. One compute dispatch per frame tests every cluster of every cluster caster against every shadow
   view that redraws this frame (dirty point/spot faces and all cascades).
3. Survivors are written as **one indexed-indirect argument per cluster**, compacted per (view, part)
   with a GPU counter. No index data is copied.
4. Each (view, part) issues one `multiDrawIndexedIndirect` that reads its draw count from the GPU
   counter buffer.

Culling alone does not change the image (§4.5). Shadow LOD is a separate, optional stage (§6, decision L1).

## 3. Goals and non-goals

| ID | Goal |
| --- | --- |
| G1 | Shadow maps and final frames are identical to today's path with culling only. |
| G2 | Shadow GPU cost scales with the clusters inside each view, not with whole parts. |
| G3 | CPU cost per frame stays bounded: one dispatch plus one draw call per (view, cluster caster). |
| G4 | Every backend stays correct; devices without the required features keep today's path. |
| G5 | Caster changes (add, remove, move, visibility, `castShadows`, asset reload) appear in the same frame. |

Non-goals:

- Time-sliced or lower-rate shadow updates (rejected in the batching design).
- Hi-Z occlusion or cone culling of shadow clusters.
- Meshlet culling for skinned, morphed, alpha-masked, Shader Graph or instanced casters.
- Changes to the main pass, to meshlet preparation or to the sidecar format.
- Native Metal, headless and browser WebGPU (they keep today's path; §8).

## 4. Design

### 4.1 Cluster casters (`ShadowCasterRegistry3D`)

A part becomes a cluster caster when:

- it passes `Meshlet3DEligibility.fallbackReason(_:allowInstances: false)` (singleton batch, static,
  opaque standard PBR, no deformation or parallax), so the cluster bounds describe its geometry exactly;
- it has base meshlets (`part.meshlets`), whose clusters are contiguous ranges of the part's own index
  buffer;
- it has at least `clusterCasterMinimumClusters` clusters (initially 256, about 24 K triangles; chosen by
  measurement in the plan). Smaller parts cost more as separate draws than they save;
- the device supports the path (§4.4).

The registry already rebuilds and compares its caster arrays once per frame, and only uploads when
something changes. It now also keeps:

- a persistent **cluster table** for all cluster casters: world-space bounds per cluster (transformed
  once when the caster changes), `firstIndex`, `indexCount`, and the caster's instance-record index;
- a part table: cluster range, vertex/index buffers, vertex layout, sidedness and material buffer.

A cluster caster is removed from the per-caster lists, so it is never drawn twice. When any input
cannot be prepared (budget, missing meshlets), the part stays a per-caster caster. That is today's
behavior.

### 4.2 Culling (`GPUShadowClusterCullProcessor`, AdaRender)

One compute pass, encoded on the shadow node's command buffer before its render pass:

- **Input:** the cluster table, the views redrawn this frame (6 planes each, the same
  `MeshVisibilityFrustum3D` planes and tolerance as `WGPUShadowCullShaders`), and a per-(view, part)
  segment table.
- **Dispatch:** x covers clusters (64 per workgroup), y covers views.
- **Per (view, cluster):** test the cluster bounds against the view planes. If the cluster intersects,
  `atomicAdd` the (view, part) counter and write `IndexedIndirectArguments(indexCount, 1, firstIndex, 0,
  instanceRecord)` into that segment.
- Counters are cleared with `clearBuffer` before the dispatch. No result is read back to the CPU.

Output buffers live in a ring of `maxFramesInFlight` slots, released on command completion like
`WGPUMeshletProcessor` frames. The segment capacity for a (view, part) is the part's cluster count.
A frame needing more than **64 MiB** of arguments (about 3.3 M cluster-view pairs) falls back to the
per-caster path for that frame. Sponza needs about 15 MiB: about 92 K clusters × about 8.5 redrawn views × 20 B.

### 4.3 Drawing

After the existing per-caster draws of a view, the shadow encoder draws each cluster caster:

1. Set the shadow pipeline for the part's vertex layout and sidedness. This is the same pipeline that
   draws the part today, so the shaders are unchanged.
2. Bind the part's own vertex and index buffers, the registry instance buffer and the material buffer,
   as the per-caster path does.
3. Call `multiDrawIndexedIndirect(arguments:offset:maxDrawCount:drawCountBuffer:drawCountOffset:)` over the
   (view, part) segment.

`RenderCommandEncoder` gains this count-buffer overload. It returns `false` when unsupported, as the
existing `multiDrawIndexedIndirect` does.

Draw order does not matter: shadow passes use a strict depth test and write fragment depth,
which the batching design already relies on.

### 4.4 Availability and switches

- Requires native WebGPU with `multiDrawIndirect` and `indirectFirstInstance`, which the device already
  requests when available, plus the existing GPU shadow culling. `RenderDevice.supportsGPUShadowClusterCull`
  reports it.
- `ADAENGINE_SHADOW_MESHLETS=0` disables cluster casters. `ADAENGINE_SHADOW_GPU=0` disables them together
  with the rest of the GPU shadow path.
- Point/spot face reuse is unchanged: faces kept by reuse are not culled or drawn.

### 4.5 Why the image does not change

- A culled cluster lies entirely outside one plane of the view frustum.
- Shadow pipelines clip depth (`unclippedDepth: false`), so such a cluster cannot produce a fragment.
- The test uses the existing planes with a tolerance toward drawing, so it never rejects a cluster
  whose triangles reach the view.
- Surviving clusters draw the same triangles, in the same pipeline, with the same instance record.

The rasterized depth is therefore identical. The tests compare shadow maps bit for bit (§9).

## 5. Alternatives considered

| Alternative | Why not |
| --- | --- |
| Reuse `WGPUMeshletProcessor` per shadow view | It copies surviving indices per view. The ivy alone needs up to 59 MB per view and frame slot, and shadows add up to 18 views. |
| Per-cluster arguments with zero instance count, no compaction | No count buffer needed, but every culled cluster still costs a GPU command-processor slot: about 92 K × views per frame. |
| Shadow proxy meshes (simplified casters) | Fastest, but it changes shadow shapes (coarse ivy) and needs a new shadow-only mesh API. It stays an option if this falls short. |
| Time-slicing moving-light faces | Rejected by the batching design: visible lag. |
| Lower shadow resolution | Does not help: the cost is triangles, not pixels. |

## 6. Shadow LOD (decision L1, for the human)

Clusters can also pick a meshlet LOD per shadow view, from the shadow tile resolution and a pixel error,
as the main pass does. That reduces ivy triangles much further, but **the image is no longer identical**:
simplified casters move shadow edges by up to the error and can add or remove small self-shadowing.

Proposal: **ship culling first (this design), measure, then decide.** If heavy views still miss 7.0 ms,
a follow-up adds `ShadowSettings.meshletLODPixelError` (default 0, meaning off), uses LOD hierarchies
with index-usable uploads, and gets its own measurement and visual comparison. That follow-up needs
separate approval.

## 7. Platform impact

| Platform | Behavior |
| --- | --- |
| Windows/Linux/macOS through Dawn (native WebGPU) with multi-draw | Cluster culling |
| Native WebGPU without multi-draw | Today's per-caster GPU path |
| Native Metal, headless | Today's CPU path |
| Browser WebGPU | Today's path (no count-buffer multi-draw) |

## 8. Ownership

- `AdaRender`: cluster cull processor protocol and WebGPU implementation (WGSL), the count-buffer
  multi-draw overload, `supportsGPUShadowClusterCull`.
- `AdaCorePipelines`: cluster casters in `ShadowCasterRegistry3D`, the dispatch and draw in
  `GPUShadowCull3D` / `ShadowBatchEncoder3D`, used by the directional and local shadow nodes.
- No public API changes besides the new optional `RenderCommandEncoder` overload and the device flag.

## 9. Validation and acceptance

Tests (Swift Testing; the GPU ones gated like the existing WebGPU GPU suites):

- Eligibility: what becomes a cluster caster, and what falls back and why.
- Cluster table update and revision behavior for G5 (add, move, hide, `castShadows`, reload).
- GPU: for a test scene with a large part crossing several faces and cascades, the shadow atlas with
  cluster culling equals the atlas with `ADAENGINE_SHADOW_MESHLETS=0`, **byte for byte**.
- Fallback: argument budget exceeded, or device without support → today's path, same image.
- Existing golden frames (`Render3DGPUTests`, WebGPU references) unchanged; `script/validate_webgpu.sh`.

Acceptance in the Sponza demo (autopilot, 1890×784, default lighting, RTX 4070), measured with
`ADAENGINE_GPU_TIMINGS=1`:

| ID | Criterion |
| --- | --- |
| A1 | Local plus sun shadow GPU time in heavy views ≤ 2.5 ms (from 6.6 ms). |
| A2 | Heavy-view frame rate ≥ 130 FPS median. 140 is the overall target; the remainder may need L1 or main-pass work. |
| A3 | No new frame-time spikes; CPU render path per frame grows ≤ 0.3 ms. |
| A4 | Final frames visually identical; shadow-atlas tests pass byte for byte. |

If A1 or A2 is missed, the measurements go to the human with the L1 option. The work is not
declared complete.

## 10. User documentation

Update the shadows section of [RenderingFoundation.md](../RenderingFoundation.md):

- which casters are culled per cluster, and the size threshold;
- memory use;
- the `ADAENGINE_SHADOW_MESHLETS=0` switch.

Add the switch, and `ADAENGINE_GPU_TIMINGS=1` for measuring, to [Tooling.md](../Tooling.md). Both are
existing guides linked from the documentation index; no new article is needed for an internal path
with no new authoring API.

## 11. Implementation notes and deviations (pending human review)

Measured on 2026-11-10: Sponza demo, autopilot, scene at 1890×784, default lighting, RTX 4070, 143 Hz.
"Heavy" means seconds in which the main pass takes more than 2 ms of GPU time. Each run lasts 50 s; GPU
times come from `ADAENGINE_GPU_TIMINGS=1`.

| Per heavy frame | `ADAENGINE_SHADOW_MESHLETS=0` | Cluster culling |
| --- | ---: | ---: |
| Local shadows (GPU) | 3.2–3.3 ms | 1.2 ms |
| Sun shadow, 1 cascade (GPU) | 2.6–3.3 ms | 2.8–3.2 ms |
| Shadows total (GPU) | 5.8–6.6 ms | 4.0–4.4 ms |
| Frame rate over the run, mean / lowest second | 124–127 / 87–94 FPS | 119–127 / 86–96 FPS |

- **A1 is not met** (4.0–4.4 ms against 2.5 ms). Local shadows meet their share. The sun does not
  improve: the demo uses the default single cascade, an 80 m box centred 40 m ahead of the camera, which
  contains the whole model (all 8.8 M opaque triangles) in every frame, so frustum culling has nothing to
  remove. A CPU probe of the existing meshlet LOD cut at the 2048-texel tile kept 77% / 76% / 75% of those
  triangles at 0.5 / 1 / 2 texels of error, so shadow LOD (§6) cannot close the gap either.
- **A2 is not met.** Heavy views stay at about 90–110 FPS.
- **A3 is met.** Light views hold 143–145 FPS. Per-frame validation of the cluster table and redundant
  pipeline/material rebinding were removed after they cost light views about 10 FPS.

Deviation in §4.2–4.3, **merged runs**:
- One indirect draw per surviving cluster (about 51 K per view for the ivy) stopped the Dawn D3D12 queue:
  every submission, the window included, stopped completing. This happened with and without the GPU
  draw-count buffer, and no driver reset was logged.
- The cull therefore runs in two steps. `classify` writes visibility per (view, cluster). `emit` writes one
  draw per run of up to 1024 consecutive visible clusters of a part.
- Clusters tile their part's index range in order (`MeshletGeometry` validates this), so a run is one
  contiguous index range of exactly the visible clusters' triangles. The image argument of §4.5 is unchanged.
- With this change, 6 of 6 runs completed without stalling, against 2 stalls in 4 runs before.

Not yet done: the tests of §9 (byte-identical shadow atlas, eligibility, fallback), the guide updates
of §10, and the independent review.
