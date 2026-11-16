# Hardware ray-query path tracing on SAGA Vulkan

Status: **Proposed — awaiting explicit human approval.**
Classification: feature (a new GPU capability behind the existing path tracer and a new backend-neutral ray-tracing API in AdaRender).
Related: [Path tracing denoising](path-tracing-denoising.md), [DLSS upscaling](dlss-upscaling.md),
[SAGA as AdaRender's only backend](saga-native-render-layer.md), [Path tracing guide](../PathTracing.md).

## Problem

AdaEngine's path tracer is a fragment-shader software tracer. The CPU flattens the scene into world-space triangles,
builds a BVH, and uploads both, together with materials and an atlas, as textures. Every ray walks that BVH in
`path_tracing_3d.wesl` (`intersectScene`). It works on every backend, but it never uses the ray-tracing units of the GPU,
rebuilds its CPU data whenever the scene changes, and caps the scene at 131072 triangles.

SAGA's Vulkan backend already implements acceleration structures (`createAccelerationStructure`, bottom-level builds from
triangle buffers, top-level builds from instances) and ray queries (`rayQuery` capability, `acceleration_structure`
bindings in compute and render stages, candidate/confirm/terminate semantics). AdaRender exposes none of it.

## What exists today (facts the design relies on)

- Traversal lives only in `intersectScene`; shading, lights, the sky, the denoisers and the DLSS Ray Reconstruction
  guides read the flattened triangle, material and atlas textures by triangle index.
- Intersection rules the software tracer implements: shadow rays skip triangles whose source does not cast shadows;
  single-sided materials reject back faces; alpha-test materials (mode 1) reject below the cutoff; stochastic alpha
  (mode 2) rejects randomly by coverage; hits closer than the ray bias are ignored.
- Skinned meshes are flattened on the CPU from the current palette; morph targets, terrain material layers and
  shader-graph shadow casters are not traceable and already make the view fall back to raster rendering.
- `PathTracing3DStatus.implementation` is `"portable-shader-bvh"`; statistics are per view.
- `RenderDevice` has no acceleration-structure type, build command or binding.

## Goals

1. On a Vulkan device that supports ray queries, the path tracer finds intersections with the GPU's ray-tracing
   hardware instead of the shader BVH, with the same image (within a stated tolerance) as the software tracer.
2. The software tracer stays the fallback and the default wherever hardware cannot be used, for the whole view, with a
   visible reason.
3. A backend-neutral acceleration-structure API in AdaRender that other features (for example ray-traced shadows) can
   reuse later.
4. Shading, lights, denoisers and DLSS Ray Reconstruction keep working unchanged on top of either traversal.

## Non-goals

- Metal, D3D12 and the browser. SAGA has ray-query paths for Metal and D3D12, but this design ships Vulkan only; those
  platforms keep the software tracer.
- A new tracer with different shading, ray-traced reflections or shadows in the raster pipeline, or a performance claim
  beyond what is measured here.
- Lifting the 131072-triangle budget. The CPU flattening that feeds shading stays, so the budget stays.
- Deforming geometry in version 1 (below).

## Behavior

### Selection

`PathTracing3D` gains an `intersection` setting:

- `.automatic` (default): hardware ray queries when the device supports them and the whole view can use them; otherwise
  the software BVH.
- `.software`: always the software BVH (reference renders, debugging, comparing).

A view that cannot use hardware falls back to software **as a whole** and the status says why. Reasons include: the device
reports no ray-query support, the scene contains skinned or morphed meshes, the budget is exceeded, an acceleration
structure build failed, or a shader variant failed to compile. Switching between traversals restarts the view's history,
like any other scene change.

### Status

`PathTracing3DStatus` gains `intersectionFallback: String?` (why hardware was not used) and its `implementation` reports
`"vulkan-ray-query"` or `"portable-shader-bvh"`. Both are visible through the existing statistics resource and, later, Studio.

### Dynamic geometry in version 1

Static mesh assets get a bottom-level structure that is built once from the asset's geometry and reused by every instance.
The top-level structure is rebuilt only when instance transforms, visibility or the instance set change. A scene that
contains skinned or morphed meshes uses the software tracer for the whole view and reports the reason. Refitting or
rebuilding deformed meshes every frame is a later improvement.

## Design

### Layers

1. **SAGA (no change expected).** Verified surface: acceleration-structure resources, bottom/top-level build commands,
   `acceleration_structure` bindings in render and compute stages, the `rayQuery` capability and candidate/confirm
   semantics. The plan confirms that a fragment stage on Vulkan can bind and query a top-level structure, and what the
   bottom-level build requires of the vertex buffer (layout and stride). If SAGA needs a change, it returns to the human
   as a design deviation.
2. **AdaRender API (backend-neutral).** A new `AccelerationStructure` resource, created through the device for a
   bottom-level triangle capacity or a top-level instance capacity; build commands on the command buffer (a bottom-level
   build from a vertex buffer and optional index buffer; a top-level build from instances with a transform, a mask and an
   instance ID); a new resource kind in `RenderResourceSet` so a pipeline can bind one; and
   `RenderDevice.supportsRayQueries` (false by default). Unsupported backends return false and no resource. The lasting
   decision is recorded as an ADR.
3. **Core pipelines.** The existing extraction keeps producing the flattened triangle, material and atlas tables used
   for shading. A new owner keeps a cache of bottom-level structures keyed by mesh part identity, builds the top-level
   structure from the extracted instances, and orders instances so that each instance's part is a contiguous run in the
   flattened triangle table. The instance ID is the first triangle index of that run; a hit's triangle is
   `instanceID + primitiveIndex`. The BVH build is skipped when hardware is selected.
4. **Shader.** `path_tracing_3d.wesl` gets a build variant (a macro, like the PBR shader features) in which
   `intersectScene` runs a ray query instead of the BVH loop: candidates are accepted in the shader with the same rules
   as today (back-face rejection by material, alpha test, stochastic alpha, ray bias), shadow rays use the instance mask
   to select shadow casters, and the committed hit is mapped to the triangle table. Everything after the hit is
   unchanged. Both variants share the same pass structure, so the Ray Reconstruction guide and denoiser passes need no
   change.

### Lifetime and failure

Bottom-level structures are destroyed when their asset or the view goes away, after the work that used them retires.
A failed build or a variant that does not compile sets the view's fallback reason and uses software from the next frame;
it never leaves a view half-hardware.

### Budgets

The flattened-triangle budget (131072) and material budget are unchanged. Top-level capacity follows the number of
extracted instances; exceeding the device limit is a fallback reason.

## Platform and hardware

| Platform | Behavior |
| --- | --- |
| Windows, Linux with a Vulkan device that supports ray queries | Hardware traversal (verified on an RTX 4070 only) |
| Same, device without ray queries | Software BVH; status reason |
| Metal, D3D12, browser, Android | Software BVH, unchanged |

## Alternatives considered

- **One bottom-level structure built from the flattened world-space triangles:** simplest, but it rebuilds the whole
  structure whenever anything moves; per-asset bottom-level structures with a per-frame top-level structure scale to
  moving objects.
- **A separate hardware scene representation:** rejected; it would duplicate the extraction and the shading data.
- **A compute tracer with its own shading:** rejected for version 1; it would fork the shading, the guides and the
  denoiser inputs. Only intersection is replaced.
- **An internal-only SPI instead of an AdaRender API:** rejected; the capability is useful beyond the path tracer and an
  SPI would have to be replaced later.

## Risks

- Vulkan fragment-stage ray queries through SAGA's SPIR-V output are verified by reading, not yet by running on a driver;
  the plan starts with a spike that traces a single ray from a fragment shader.
- Image differences from the software tracer (precision, watertightness, ray bias) are bounded by a tolerance rather than
  being exactly zero; the tolerance is set from measured error.
- Memory for bottom-level structures and per-frame top-level builds; both are measured.
- This host cannot build the full test target (compiler crash), so GPU suites run from a small scratch package and CI/hardware
  evidence is needed for the rest.

## Acceptance criteria

1. On an RTX GPU, a path-traced view with `.automatic` reports `implementation == "vulkan-ray-query"` and no fallback.
2. The hardware image of the standard path-tracing test scenes is within a recorded tolerance of the software image
   (same scene, same frames, both traversals in one run) and shows the same shadows, alpha-tested and stochastic
   transparency, and back-face behavior.
3. With `.software`, on a device without ray queries, or with a skinned or morphed mesh, the view uses the software
   tracer, reports a specific `intersectionFallback`, and the existing software golden frames are unchanged.
4. Moving an object rebuilds only the top-level structure; adding or removing a mesh asset builds or releases only its
   bottom-level structure; a view's history restarts only when the traversal or the scene changes.
5. A build failure or shader failure falls back to software without a crash, validation error or half-hardware frame.
6. DLSS Ray Reconstruction and the portable denoiser both work with the hardware traversal.
7. The trace pass is measured against the software tracer on the Sponza path-tracing benchmark. If hardware is not at
   least as fast, `.automatic` stays on software for that configuration and the result is reported to the human
   rather than shipped silently.
8. No Vulkan validation errors on resize, scale change, scene change and traversal toggle.

## Validation

- Unit tests (no GPU): selection and fallback logic, status values, settings round-trip and legacy decode, instance
  ordering and instance-ID/triangle mapping, bottom-level cache lifetime.
- AdaRender API tests against a fake device (capability reporting, validation of build inputs).
- GPU tests on the RTX 4070, gated by an environment variable like the DLSS tests: software-versus-hardware comparison
  per scene, fallback cases, a toggle/resize run, and the benchmark. They run from the small scratch package because the
  full test target crashes the Windows compiler on this host; the remaining checks need CI or other hardware.
- `python script/check_contribution.py` for each stage; independent review before completion.

## User documentation delivery plan

- **Article:** `Sources/AdaEngine/AdaEngine.docc/Articles/3D/HardwarePathTracing.md` — what it does, requirements, the
  `intersection` setting, reading the status and fallback reason, limits (static geometry, Vulkan only, no performance
  guarantee), with a runnable example and verification of the snippets against the shipped API.
- **Navigation:** linked from `AdaEngine.md`; the editor's offline guide snapshot is regenerated
  (`Editor/scripts/update-offline-documentation.py`).
- **Guide update:** `Documentation/PathTracing.md` stops saying the tracer never uses hardware ray intersection and
  links to the article.
- **ADR:** `Documentation/ArchitectureDecisions/` records the backend-neutral acceleration-structure API.
- Docs and example checks are declared with the runner's `documentation` command and updated before independent review.

## Open items for the plan

- Exact SAGA build requirements for the bottom-level vertex input and whether position data needs a compact copy.
- The tolerance for criterion 2 and the benchmark scene for criterion 7.
- Whether `.automatic` should also require a minimum device class, decided from measurements.
