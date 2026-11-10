# Path Tracing Denoising: DLSS Ray Reconstruction and a Portable Denoiser

Status: Implemented. The deviations and limitations in §11 were accepted by the human on 2026-11-10 ("Accept, then commit").
Approval: explicit user approval in this Claude Code conversation on 2026-11-10 ("Approve, build it"), including the four decisions of §10.
Date: 2026-11-10.
Classification: improvement of the existing path tracer ([PathTracing.md](../PathTracing.md),
[ADR-0021 hybrid ray tracing](../ArchitectureDecisions/0021-hybrid-ray-tracing.md)) and DLSS bridge ([DLSS.md](../DLSS.md)).
Supersedes items C, D and E of the unapproved
[interactive path-tracing proposal](path-tracing-interactive-quality.md); its items A and B stay there.

## 1. Problem

The Sponza path-tracing preset (RTX 4070, WebGPU/D3D12) shows heavy noise and a soft, low-detail image:

| # | Cause (verified in code or by running the demo) |
| --- | --- |
| P1 | **DLSS never runs in the demo.** NGX needs `nvngx_dlss.dll` beside the executable; the demo build does not stage it. NGX then reports "unavailable on the selected adapter/driver", which hides the real cause. After staging the DLL with `script/build_dlss.py --stage-runtime`, NGX starts and evaluates on this machine. |
| P2 | **No DLSS → reduced resolution.** Without DLSS the demo traces at 0.5× (or 0.25×) and upsamples with a four-tap filter. |
| P3 | **History resets every frame.** The history key contains the view matrix and every light's position. The demo's flying light is on by default, so accumulation never passes 1 sample per pixel even with a still camera. Camera motion also resets: there is no reprojection. |
| P4 | **Minimal denoising.** One 5×5 guided filter. DLSS Super Resolution upscales but does not denoise. |
| P5 | **Low-detail geometry.** The tracer is capped at 131,072 triangles, so Sponza traces a 121 K-triangle LOD, also for primary visibility. The raster G-buffer it already reads holds the full 8.8 M-triangle model. |

## 2. Decision

1. **Fix the DLSS runtime delivery (P1)** and report a missing runtime as such.
2. **Hybrid first hit (P5):** take primary visibility, normal, material and position from the raster G-buffer and trace
   only from the first bounce on. The image keeps full model detail. The denoisers' guides then match the noisy signal.
3. **Keep history through motion (P3):** history is never reset by camera or light motion. It is reprojected, validated
   and blended (§4.3). Only scene, setting and resolution changes reset it.
4. **Denoise with DLSS Ray Reconstruction where available:** native Windows, NVIDIA RTX, with the NGX runtime present.
   It denoises and upscales in one step and replaces DLSS Super Resolution for path-traced views.
5. **Denoise with a portable denoiser everywhere else:** an SVGF-style temporal and spatial filter in WGSL/GLSL
   (§4.4) for Metal, non-NVIDIA WebGPU and browsers, followed by the existing temporal upscaling (TAA/FSR).

## 3. Goals and non-goals

| ID | Goal |
| --- | --- |
| G1 | A still view converges to the same image as today's long accumulation. A moving view or light stays stable without noise crawling. |
| G2 | Path-traced views show full model detail at the primary hit (P5). |
| G3 | DLSS works in the demo and in Studio installs without manual DLL copying (P1). |
| G4 | Every backend gets a denoised image: Ray Reconstruction on RTX, the portable denoiser elsewhere. |
| G5 | The denoiser can be selected, and switched off for reference comparison. |

Non-goals:

- Path-tracer speed beyond what the hybrid first hit saves: light sampling (item B), BVH build time and the
  triangle cap are separate work.
- Hardware ray tracing, ReSTIR, and DLSS Frame Generation.
- Denoising raster lighting (SSGI/SSR).

## 4. Design

### 4.1 DLSS runtime delivery (AdaRender, tooling)

- `ada_tool install studio`, the Studio packager and the example build docs stage `nvngx_dlss.dll`,
  `nvngx_dlssd.dll` and the NVIDIA license beside the executable (`build_dlss.py --stage-runtime`, extended to both DLLs).
- When neither DLL is found beside the executable, the bridge reports "DLSS runtime nvngx_dlss.dll not found
  next to <exe>" before calling NGX. A development fallback reads the prepared SDK path from `ADAENGINE_DLSS_SDK_PATH`
  through NGX's feature path list, so `swift run` of an example works.
- Ray Reconstruction availability is queried separately (`SuperSamplingDenoising_Available`) and exposed as
  `RenderDevice.supportsRayReconstruction`.

### 4.2 Hybrid first hit (path tracer)

- The tracer runs at the G-buffer resolution, which is the DLSS or temporal input resolution. A pixel's first hit is
  the G-buffer surface: view position, normal, roughness and metallic. Base colour comes from a new G-buffer
  **albedo** target (RGBA8, written by the main pass when path tracing is enabled), with emission added in the same
  target's spare capacity or a second small target.
- Direct light and continuation rays start from that surface, offset along the geometric normal, through the existing
  BVH. Secondary bounces still see the LOD geometry; their small-scale error is far below the noise level.
- Sky pixels (no G-buffer surface) take the sky radiance directly.
- The tracer writes **demodulated** irradiance: diffuse and specular radiance divided by their albedo, plus a hit
  distance. The portable denoiser filters demodulated light, and Ray Reconstruction receives the remodulated colour
  with separate albedos.

### 4.3 History without resets

- The reset key keeps scene generation, settings, resolution and sky. It no longer contains the view matrix or light
  values.
- Each frame reprojects history with the existing motion vectors. It rejects a history sample when the reprojected
  depth or normal differs beyond a threshold (disocclusion) and clamps it to the current neighbourhood's colour range
  (moment-based), which removes lag from moving lights.
- The blend weight is `max(1 / (age + 1), αmin)`. `αmin` is 1/32 for the portable path and is configurable, so a
  static view converges and moving lights fade old light within about half a second at 60 FPS.
- With Ray Reconstruction, the tracer's own accumulation is off: Ray Reconstruction keeps its own history and
  expects one fresh sample per frame.

### 4.4 Portable denoiser (AdaCorePipelines, WGSL/GLSL through the existing shader pipeline)

An SVGF-style chain at tracer resolution, run after the tracer:

1. **Temporal accumulation (§4.3)** of demodulated diffuse and specular, plus the first and second luminance moments
   and the history length.
2. **Variance estimate:** temporal variance from the moments, or a 7×7 spatial estimate while history is short.
3. **À-trous wavelet filter:** 4 iterations (step 1, 2, 4, 8). Weights come from depth, normal (power 128),
   luminance against filtered variance, and roughness for the specular term. The first iteration's output becomes
   the next frame's history.
4. **Remodulation** with albedo, then hand-off to the existing exposure, bloom and temporal upscaling chain (TAA/FSR or
   DLSS Super Resolution).

The existing 5×5 filter and four-tap reconstruction are replaced. The no-denoiser mode
(`PathTracingDenoiser.off`) keeps plain accumulation for reference renders.

### 4.5 Ray Reconstruction (CWebGPUDLSS bridge)

- New bridge entry points `ada_dlss_rr_view_create` and `ada_dlss_rr_evaluate`, following the Super Resolution view's
  design: shared D3D12 textures imported into Dawn, fence hand-off, three command allocators, no CPU readback.
- **Inputs at render resolution:**
  - noisy colour, from the tracer's remodulated output;
  - diffuse and specular albedo (G-buffer albedo with metallic, and the existing specular response);
  - normals with roughness packed in `.w` (`Roughness_Mode_Packed`, from `normalRoughness3D`);
  - hardware depth;
  - motion vectors and jitter, as Super Resolution uses them today;
  - specular hit distance;
  - world-to-view and view-to-clip matrices.
- **Output:** the denoised, upscaled HDR colour, copied back into the resolve texture. Exposure, bloom and grading
  continue unchanged.
- The view's temporal path selects Ray Reconstruction instead of Super Resolution when path tracing is active and the
  denoiser resolves to `.rayReconstruction`.

### 4.6 Settings (public API)

`PathTracing3D.denoiser: PathTracingDenoiser` with `.automatic` (the default), `.rayReconstruction`, `.portable` and
`.off`. `.automatic` picks Ray Reconstruction when the device supports it and DLSS temporal upscaling is enabled on the
camera, and the portable denoiser otherwise. `.rayReconstruction` falls back to `.portable` with a status reason when
unavailable. `Render3DPathTracingStatistics` reports the active denoiser and the fallback reason.

## 5. Alternatives considered

| Alternative | Why not |
| --- | --- |
| Ray Reconstruction only | No denoising on Metal, AMD, Intel or the browser (G4). |
| Portable only | Noticeably noisier at 1 sample per pixel than Ray Reconstruction on the hardware that has it. |
| Keep tracing primary rays through the LOD BVH | The guides would not match the colour; the model stays low detail (P5). |
| Raise the triangle cap instead of hybrid first hit | BVH memory, build time and per-ray cost grow with 8.8 M triangles. Hybrid gets full detail for free at the first hit. |
| NVIDIA NRD (ReBLUR/ReLAX) as the portable denoiser | HLSL/compute with a large integration surface and no Metal/browser path in this stack. SVGF fits the existing shader pipeline. |

## 6. Platform impact

| Platform | Denoiser |
| --- | --- |
| Windows, NVIDIA RTX, native WebGPU (Dawn D3D12), runtime present | Ray Reconstruction |
| Windows/Linux, other GPUs; macOS (Metal or Dawn) | Portable, then TAA/FSR |
| Browser WebGPU | Portable, then TAA |

## 7. Ownership

- `AdaRender`: DLSS runtime discovery and error reporting, Ray Reconstruction device support, and the Swift wrapper
  of the Ray Reconstruction view.
- `CWebGPUDLSS`: the Ray Reconstruction view.
- `AdaCorePipelines`:
  - the G-buffer albedo target, the hybrid first hit and demodulated output in `path_tracing_3d.glsl`;
  - history reprojection and the portable denoiser passes;
  - Ray Reconstruction selection in the temporal node.
- Tooling: `build_dlss.py`, `ada_tool` Studio install/packaging, and the example README.

## 8. Validation and acceptance

Tests (Swift Testing; GPU suites gated as today):

- History: a camera move and a moving light keep accumulation (`historyResets` unchanged). Disocclusion rejects
  history (a synthetic two-plane scene).
- Hybrid first hit: the primary-hit position equals the G-buffer position within float tolerance, and a
  sky pixel takes the sky radiance.
- Portable denoiser: deterministic output for a fixed seed. A still view converges to the `.off` reference
  within a bounded error. No NaN or Inf output.
- Golden frames (WebGPU and Metal) for the path-traced test scene, with the portable and `.off` denoiser.
- The DLSS runtime is missing → the stated error message. Ray Reconstruction is unavailable → `.automatic` reports
  portable.
- Ray Reconstruction: a Windows GPU test, gated like the existing DLSS smoke, evaluates a frame without device errors.

Acceptance in the Sponza demo (path-tracing preset, 1890×784 output, default lighting with the flying light, RTX 4070).
The reference is a 4096-frame `.off` accumulation of a still view.

| ID | Criterion |
| --- | --- |
| A1 | Still view: after 1 s, the portable denoiser is within a small mean relative error of the reference, and Ray Reconstruction is visually indistinguishable from it. Screenshots go in Evidence. |
| A2 | Moving camera and flying light: no visible noise crawl or ghost trails longer than 0.5 s, in recorded clips for both denoisers. |
| A3 | Full-detail primary hits: the ivy and Sponza detail match the raster preset in a side-by-side capture. |
| A4 | DLSS and Ray Reconstruction run in the demo and in an installed Studio without manual steps. |
| A5 | Cost at the demo's DLSS input resolution: portable chain ≤ 1.5 ms of GPU time; Ray Reconstruction measured and reported. The path-tracing frame rate does not drop below today's. |

## 9. User documentation

- Update [PathTracing.md](../PathTracing.md): hybrid first hit, history behaviour, the `denoiser` setting, denoiser
  selection and limits.
- Update [DLSS.md](../DLSS.md): Ray Reconstruction, both runtime DLLs and the runtime error.
- Update [Tooling.md](../Tooling.md): staging during Studio install.
- Update the DocC rendering article that links path tracing, if it lists settings.

## 10. Decisions for the human

1. Approve the **hybrid first hit** (§4.2) with a new G-buffer albedo target. It changes the main pass outputs, but
   only when path tracing is enabled.
2. Approve the **SVGF-style portable denoiser** (§4.4) as the replacement for the current 5×5 filter.
3. Approve **`.automatic` defaulting to Ray Reconstruction** whenever DLSS temporal upscaling is enabled on the camera.
4. Approve the **runtime staging** in Studio install/packaging and the development fallback that reads the SDK path
   (§4.1).

## 11. Implementation notes and deviations (pending human review)

Implemented on 2026-11-10 and measured in the Sponza demo (RTX 4070, Dawn D3D12, scene at 1890×784 with DLSS Quality,
tracer at 1260×523). Captures: `Evidence/PathTracingDenoising-2026-11-10/`.

Deviations from §4:

| § | Design | Implemented | Why |
| --- | --- | --- | --- |
| 4.2 | New G-buffer albedo target | Path-traced views reuse the two optional outputs that SSR and SSGI leave unused while tracing: base colour in the diffuse-surface target (RGBA8) and emission in the reflection-response target (RGBA16F), selected by the shader define `ADA_PATH_TRACING_SURFACE` | Every main-pass pipeline (PBR, particles, graphs, terrain, meshlet map) already supports these attachments; a new one would have touched all of them |
| 4.2 | (not specified) | New public component `PathTracingGeometry3D` (`.rasterOnly`, `.pathTracingOnly`) | The full-detail first hit is only visible when the rasterized model can differ from the traced one; the demo's traced LOD would otherwise also be drawn |
| 4.3 | Moment-based clamp; reset on scene, setting, resolution changes | History is clamped to the current 3×3 mean ± 2σ. Light motion keeps history, but adding, removing, switching or retuning a light restarts it | Existing GPU tests require a light switched off or turned away to vanish at once |
| 4.4 | Temporal moments for variance | Spatial 3×3 luminance variance in each wavelet iteration | One RGBA16F target per pass, no MRT pipeline |
| 4.1 | `RenderDevice.supportsRayReconstruction` | `TemporalUpscaler.supportsDenoising`, mirrored to `RenderViewTarget.rayReconstructionAvailable` | The capability belongs to the view's DLSS upscaler, which the tracer must match |

Also fixed while implementing:
- **Shader cache.** `ShaderCache` recorded a changed source hash before compiling, so a failed compile left a stale
  translation in use on every later launch. A failed compile now rolls the entry back.
- **Shader variant gate.** The path-tracing surface variant is requested only when both outputs are attached;
  requesting it without them crashed in required-shader loading.

Acceptance (§8):

| ID | Status |
| --- | --- |
| A1 | Still views are visually clean with both denoisers (captures). The quantitative comparison against a 4096-frame reference was not run. |
| A2 | Flying light: clean with both denoisers in still captures. Recorded motion clips were not made. The matrices passed to Ray Reconstruction were not validated in motion. |
| A3 | Met: full-detail model and ivy in path tracing (captures). |
| A4 | The demo works with `ADAENGINE_DLSS_SDK_PATH` or staged DLLs. Studio install/packaging staging is implemented but not run. |
| A5 | Portable chain about 1.1 ms of GPU time (42.7 against 41.7 ms for `.off`). Ray Reconstruction cost not measured. The tracer frame rate stays 16–18 FPS. |

Tests:
- headless: 45 tests in 9 suites, including the new settings, variant-gate and role-extraction tests;
- GPU: `Render3DPathTracing*` 17 tests on WebGPU (`ADAENGINE_GOLDEN_WEBGPU=1`). New tests: portable history survives
  camera and light motion but restarts on a light change; `.off` restarts on camera motion; portable output is
  finite and within 15% of the converged `.off` reference; Ray Reconstruction falls back to portable with a reason;
- not run: Metal, `check_contribution.py` (SwiftLint is unavailable on Windows), a Ray Reconstruction GPU test.

### Independent review (2026-11-10)

Fixed after review:
- `rayReconstructionAvailable` is reset every frame. Ray Reconstruction also requires active temporal upscaling,
  so turning DLSS off can no longer leave an undenoised frame.
- Ray Reconstruction traces at its input size regardless of `resolutionScale`, matching decision 3.
  Previously the default scale 0.5 kept it from ever running.
- Pixels without a G-buffer surface show the sky directly and are never traced, so tracer-only proxies stay
  invisible.
- Ray Reconstruction resets when the tracer's history restarts (scene, light set, settings, denoiser).
- Radiance is clamped before emission is added, so demodulation is exact for bright emitters.
- The runtime lookup cannot throw across the C API. A missing `nvngx_dlssd.dll` disables only Ray Reconstruction,
  with a message.
- Doc comments, the Studio staging error and the Metal claim in the guide.

Remaining deviations and limitations for the human:
1. Reprojection uses the camera's previous matrices and the pixel's world position, not per-object motion vectors.
   Moving or skinned objects fail the history check and stay at the noise level of a single frame.
2. No specular hit distance is passed to Ray Reconstruction (§4.5 listed it).
3. The specular albedo guide is F0, not a pre-integrated environment BRDF.
4. The portable history is the temporal output, not the first wavelet iteration (§4.4).
5. First-hit continuation rays start 2 × `rayBias` off the raster surface. A tracer proxy that differs from the
   raster model by more than a few millimetres can shadow itself.
6. `PathTracingGeometry3D` is new public API.
7. The view-matrix layout passed to Ray Reconstruction is believed correct but was not validated in motion.
