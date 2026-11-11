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
