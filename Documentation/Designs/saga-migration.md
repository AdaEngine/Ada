# Migrate AdaEngine rendering and shader translation to SAGA

Status: Proposed.

## Scope

Replace Swan/Dawn on AdaEngine's WebGPU rendering path with SAGA and replace Tint's SPIR-V-to-WGSL translation with SAGACompiler. Preserve existing shader inputs, materials, scenes, and the native Metal path. Keep existing GLSL compilation and reflection in this migration.

## Local dependency

Use a local SwiftPM dependency named SAGA. Resolve it from `ADAENGINE_SAGA_PACKAGE_PATH` when set, otherwise from the sibling `../SAGA` checkout for SAGA-enabled builds. Resolve the sibling relative to the AdaEngine manifest. Wire the compiler and platform-specific runtime products into their owning targets. Propagate the checkout path into staged builds and CI, with a clear missing-checkout diagnostic. Keep headless builds independent of GPU runtime dependencies. A remote package or distribution strategy is outside this migration.

## Shader translation

Replace the Tint subprocess in `WGSLShaderCompiler` with SAGACompiler. Preserve entry point names, stages, binding layouts, diagnostics, and shader cache correctness. Exercise actual AdaEngine GLSL/SPIR-V inputs and validate emitted WGSL in the browser. Migrate the export and shader preparation callers before removing Tint installation, bootstrap, plugin and CI wiring.

## Rendering

Adapt the existing AdaRender backend boundary to SAGA. Use SAGAWebGPU for browser canvas rendering. Evaluate the local SAGAD3D12 and SAGAVulkan implementations against AdaEngine's native platform requirements before selecting them for Windows and other affected native builds. The checkout contains native implementation code, while its README lists only Metal and browser WebGPU as verified runtime paths. Treat native availability, presentation and feature parity as validation requirements.

Migrate shader translation first, then switch rendering paths as each passes its platform checks. Keep Swan/Dawn on paths awaiting parity during the transition. Before final removal, cover presentation and resize, render and compute passes, resource lifetime, uploads and readback, and existing Windows DLSS interop where enabled. Any supported behavior that requires a scope change returns for approval.

## Acceptance and documentation

- Local checkout resolution works from the root package, Studio, web export and CI, including an override path containing spaces.
- Production shaders compile with the intended entry points and bindings. Browser export runs through real WebGPU, and native and browser render checks pass against existing golden references within their existing tolerances.
- Existing Metal and headless builds pass. Every Dawn-backed configuration has a validated replacement before its dependency and packaging wiring are removed.
- Update the existing setup and build instructions in [Documentation/Tooling.md](../Tooling.md), including local checkout layout, override usage, supported platforms and verified Windows Studio and WASM commands. Check links and run those commands through their documented entry points.

## Addendum: Backend slice 1 — SAGAWebGPU for browser/WASM (proposed, awaiting approval)

Status: Proposed. No code is changed until this is approved.

### Findings

- Swan is used by about 6,000 lines in `Sources/AdaRender/Backends/WebGPU` (30 files) plus `WindowsApplication`, `LinuxApplication`, `RenderEngine` and `WGSLReflection`.
- AdaRender's backend is synchronous and object-oriented, written against Swan's WebGPU-style `GPUDevice`, `GPUBuffer`, `GPUTexture` and encoders.
- SAGA's `Device` is an `actor` with `async throws` creation calls returning `ResourceID` handles, and a `CommandList`/submission model. `SAGAWebGPU` currently contains only `BrowserBackend` and `BrowserComputeBackend`.
- The two models differ in threading, resource ownership and command recording, so this is an adapter layer, not a mechanical rename.

### Proposed approach

1. Add a `SAGARenderBackend` inside AdaRender (browser-only, `#if SAGA_WEBGPU`) implementing the existing `RenderBackend`/`RenderDevice` protocols, leaving the Swan backend untouched.
2. Bridge sync AdaRender calls to SAGA with a resource-handle table: creation returns an AdaRender object immediately and finishes in the background; use is ordered through the command list, so no render-thread blocking.
3. Port in this order, each verified in the browser: swapchain/canvas presentation → buffers, textures, samplers → render pipelines and render pass → compute and the processors (visibility, shadow cull, meshlet, FSR) → readback and timestamp queries.
4. Select the backend per build: browser/WASM uses SAGA; native keeps Swan until slices 2 (Windows/Vulkan/D3D12) and 3 (shaders) pass parity.

### Validation

- Browser export renders the existing golden scenes within current tolerances and compute passes match.
- Existing Metal, headless and native Swan builds still pass.
- Each ported area has Swift Testing coverage written Red → Green first.

### Open decisions for the human

- Is the async-handle adapter acceptable, or should SAGA gain a synchronous resource API first?
- Features SAGAWebGPU lacks must be listed before porting (e.g. timestamp queries, pipeline disk cache, DLSS). Should missing ones block, or be disabled in the browser with a diagnostic?

### Addendum findings after starting slice 1 (blocker, needs decision)

- `SAGAWebGPU` is only a thin `BrowserBackend` that forwards to a `BrowserGPUHost` protocol. The real host (`WebGPUHost`, a binary opcode/packet RPC to JavaScript, about 590 lines) and its JS bridge (`web/webgpu.mjs`, `reactor.mjs`) live in the `SAGAWebDiagnostic` executable, not in a library product. AdaEngine cannot depend on them as-is.
- SAGA submits declarative command lists (pipeline, bindings, attachments per pass) through async RPC. AdaRender uses stateful immediate encoders (`setPipeline`, `setVertexBuffer`, `draw`). The adapter must record state per draw and flush it as a SAGA command list.
- Prerequisite in the SAGA repository: promote the browser host and JS bridge to a library product (for example `SAGAWebHost`) and ship the JS files with it. This is a scope change that needs approval.

### Implementation status: browser backend (slice 1)

- SAGA: `SAGAWebHost` library (opcode host plus pluggable `BrowserTransport`), `makeWebDeviceCapabilities`, and `host.attachCanvas` / `openWebGPU(null, { deferCanvas: true })` in `web/webgpu.mjs`.
- AdaRender: `Backends/SAGA` implements `RenderBackend`/`RenderDevice` for browser/WASM behind `SAGA_WEBGPU`. A page that defines `globalThis.__adaSAGAHost` renders through SAGA; otherwise Swan is used. The web export opens the host when the URL has `?renderer=saga` and ships `saga-webgpu.mjs` from the SAGA checkout.
- Sync AdaRender calls reach SAGA's async `Device` through `OrderedGPUWorkQueue`; a window is an offscreen texture copied to the canvas on present; each draw becomes one SAGA render command, and clear-only passes draw a degenerate triangle.
- Not yet supported on this backend: indirect/multi-draw, FSR/DLSS upscalers, GPU visibility/shadow/meshlet processors, timestamp queries, cube/array texture views, stencil-only attachments. The device reports these as unsupported.
- Remaining before Swan can be removed: browser golden-frame parity, the native Windows/Metal/Android backends, the shader migration, Shader Graph, and removal of Tint and Dawn wiring.

### Browser verification log

- 2026-11-12: `AdaWebPlayer` exported through `export-web` and packed with a small 3D project (camera with `Environment3D`, sun, three lit meshes). Loaded in Chromium at `?renderer=saga&solo=1`, the SAGA backend presented frames (`host.metrics().presentedFrames` 144 at 1369×829) and showed the sky and the three meshes. This is a smoke check, not golden-frame parity.
- Observed gaps: the 30×30 floor plane is not visible, and surfaces look darker than expected; both need investigation against the Swan path (the Swan path rendered only a blank dark canvas in the same browser session, so it could not serve as the reference there).
- Web Player fix made on the way: it now accepts `AdaCorePipelines.Environment3D`, `AdaScene.ScriptableComponents` and `AdaUI.CompanionPanel`.
- With `?sagadebug` (waits for each submission and logs `takeUncapturedErrors`), the smoke scene produced no SAGA device errors. The missing floor and dark shading are therefore not explained by a SAGA validation failure; they may come from the test scene (sun orientation, plane facing) and need a reference render to settle. The Swan browser path traps in `WGPUShadowCullProcessor.encode` in this session, so it cannot serve as that reference without a Swan-side fix.

### Browser parity check (smoke scene)

Scene: [Tests/WebGolden/SAGASmoke](../../Tests/WebGolden/SAGASmoke/README.md) (camera with `Environment3D`, sun with shadows, a floor, two cubes and a sphere).
Reference captures from the same bundle and browser: [Swan](assets/saga-browser-parity/swan.jpg) and [SAGA](assets/saga-browser-parity/saga.jpg).

Findings fixed while making SAGA match Swan:

1. **Front-face winding.** An unset `frontFaceWinding` means clockwise on the other backends; SAGA pipelines defaulted to counter-clockwise, which culled the visible faces (dark shading, missing floor).
2. **Attachment stores.** SAGA runs each draw as its own render pass, so a pass that declares "don't store" left later draws of the same AdaRender pass with undefined depth. Draws now always store attachments (only one of three shadows appeared before the fix).
3. **Swan in the browser.** `WGPUShadowCullProcessor` traps in WASM; the Swan device now reports no GPU shadow cull there so it can serve as the reference.

Comparison is visual: floor, cube/sphere shading and all three cast shadows match. It is not an automated golden-frame test: WebGPU canvases read back blank from the page, so a pixel capture needs an engine-side readback hook in the host (`present`) or a headless browser harness. That remains to do before Swan can be removed from the browser path.

Debug aids (opt in with `?sagadebug`): waits for every submission, prints SAGA device errors, and prints once per pipeline the declared versus bound resources and vertex layout.

### Golden-frame test (browser)

- SAGA's JS host exposes `host.captureNextFrame()` (reads the presented texture back to RGBA) and `web/golden.mjs` provides `captureStable`, `checkGolden`, `compareFrames` and PNG helpers. The export ships them as `saga-webgpu.mjs` and `saga-golden.mjs`.
- Reference: `Tests/AdaEngineTests/GoldenFrames/saga-browser/smoke-160x96.png`, recorded from the frame that visually matched Swan. A fresh page load reproduces it exactly (mean error 0); a frame darkened to half brightness fails (mean error about 76), so the check detects regressions.
- Runner: `node script/web_golden_saga.mjs <bundle> [--record]` (needs `playwright-core` and a WebGPU Chromium). It has not been executed end to end in this environment because no browser automation package is installed; the same helpers were run in the in-app browser instead.
- Open: the reference is a SAGA self-golden validated by eye against Swan on this one scene; Swan frames cannot be captured the same way (its canvas reads back blank), so there is no automated cross-backend diff yet.

### Status: browser builds no longer link Swan

- `AdaWebPlayer` builds for wasm without Swan's `WebGPU` product (Package.swift limits it to Apple, Linux, Windows and Android). The built wasm contains no `WebGPUWasm` references. The WASM shader-loading paths key on `WEBGPU_ENABLED` instead of `canImport(WebGPU)`.
- The web export always opens SAGA's host and fails with a clear message when no SAGA checkout is found. `?renderer=swan` no longer exists.
- Golden check on the default URL passes against `smoke-160x96.png` (mean error 0) with the Swan-free build.
- Still on Swan/Dawn: native Windows, Linux and Android WebGPU. Still GLSL: the ten shaders listed in the shader migration plan.

### Status: native Vulkan adapter (offscreen)

- The SAGA adapter is shared by the browser and native builds (`SAGA_RENDER`). The device factory and shader format are injected: WGSL for the browser, SPIR-V for Vulkan. `SAGAShader` accepts WGSL source and SPIR-V.
- `ADAENGINE_SAGA_NATIVE=1` builds AdaRender with SAGA's Vulkan runtime on Windows and Linux. It does not need Swan, so it also builds with `ADAENGINE_HEADLESS=1`, which avoids the Dawn artifact download.
- `SAGAVulkanDeviceTests` (3 tests) pass on the Windows Vulkan device: buffer round trip, offset write, and a render pass that draws a fullscreen triangle into an `rgba8` texture and reads back the expected pixel colors. The run reported no SAGA device errors.
- Not done on native: a `RenderBackend` that creates windows. SAGA's Vulkan device must be created together with the window's surface, while the engine creates GPU resources before any window exists. The queued device factory can wait for the first surface, but capabilities are read synchronously, so a surface-less probe device or a deferred-capabilities design is needed first. Also open: engine GLSL/SPIR-V reflection and bindings on native, multiple render targets on D3D12, and Linux/Android/Metal.

## Native Vulkan renders the real 3D pipeline (status)

`Render3DGPUTests/SagaNative` renders the debug-view scene (four PBR spheres, sun with cascaded shadows, floor, SSAO,
screen-space reflection composite) on SAGA's Vulkan runtime through `flat3d.wesl` and the other WESL shaders:

```bash
ADAENGINE_GOLDEN_SAGA=1 ADAENGINE_SAGA_NATIVE=1 ADAENGINE_SAGA_WINDOWLESS=1 swift test --filter Render3DGPUTests/SagaNative
```

Getting there needed these changes:

- **SAGA Vulkan multiple render targets.** Pipelines, render passes, the planner and the recorder accept color targets at
  locations 1 to 7 (flat3d writes four). A location without a target is an unused attachment that writes nothing.
  Multisampled and resolving passes with extra targets are still rejected. `SAGAVulkanDeviceTests.aPassWritesEveryColorTarget`
  covers it on a real device.
- **SAGA Vulkan `float32-filterable` and `float32-blendable`** are reported from the adapter's format properties, so
  rgba32f depth/position buffers can be sampled with a filtering sampler.
- **SAGA sampled-texture capacity 16 -> 24** per stage. flat3d with lightmap and irradiance grid binds 17 textures.
- **One SAGA device.** `createLocalRenderDevice()` returns a device on the primary context. A resource id is only valid on
  the device that created it, and textures loaded through the "local" device are bound by the renderer's passes.
- **Windowless devices.** The primary device normally waits for the first window's surface. Offscreen tools and tests set
  `ADAENGINE_SAGA_WINDOWLESS=1` (or pass `windowless: true`) to create it without one.
- **Attachment lifetime.** A render pass keeps its attachment textures alive until its commands were built, because a
  texture destroys its GPU resource when it is released.

Diagnostics: `ADAENGINE_SAGA_DEBUG=1` prints device errors and each pipeline's declared and unbound resources;
`ADAENGINE_SAGA_TRACE=1` prints every queued job's origin as it begins, ends or fails.

Not verified yet: pixel parity with the Metal and WebGPU references (no reference exists for this backend, and
`ADAENGINE_GOLDEN_RECORD=1` would pin this GPU's output), other scenes, and presentation of the 3D scene to a window.

### Shader Graph on the WESL templates (status)

The native renderer now compiles a Shader Graph through `ShaderGraph.compileWGSL()` and splices it into the surface
templates at their `// ADA_GRAPH_SOURCE_MARKER` line: `flat3d.wesl`, `directional_shadow_3d.wesl` (shadow and contact
depth alpha masks) and `motion_3d.wesl`. `ShaderModule.createWESL(source:packageRoot:features:)` links the generated
source in memory (`WESLHostCompiler.compile(source:...)`), so templates can import their package siblings. The graph's
local result variable is `ada_graph_result` because a template may import a binding called `surface`.

`Render3DGPUTests/SagaNative/aShaderGraphMaterialRendersThroughTheWESLTemplate` renders a graph-colored floor on Vulkan.

Still GLSL: sprite graphs (`SpriteGraphPipeline`), the offline baker (`AdaShaderGraphBaker`) and the web export, which
prelinks flat3d, mesh2d and canvas variants only as GLSL until the exporter links WESL. `ShaderGraphArchive` stays at
version 1: its fragments are keyed by GLSL source, so the version bump and the rejection of GLSL-era archives belong with
the baker port.
