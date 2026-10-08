# Platform, Rendering, and Web

Read this reference for platform backends, windowing, GPU resources, shaders, render graph, WebGPU, WASI/browser export, or build plugins.

## Compile-Time Configuration

The root manifest defines platform symbols including `MACOS`, `WINDOWS`, `IOS`, `TVOS`, `VISIONOS`, `ANDROID`, `LINUX`, `DARWIN`, `METAL`, `WASM`, and `BROWSER`. WebGPU support is trait/environment dependent.

Relevant environment switches in the checked-out manifest include:

- `ADAENGINE_HEADLESS=1` or `ADAENGINE_DISABLE_SWAN=1` to avoid Swan/WebGPU dependency use in supported headless configurations.
- `ADAENGINE_WEB_EXPORT=1` to enable the web-export product/plugin path and WebGPU trait.
- CI and plugin scripts may define additional skip switches; inspect the current workflow and plugin source before relying on one.

Keep conditionals aligned between `Package.swift`, Swift sources, C/C++ settings, and plugin logic. Verify at least the affected platform configuration; do not assume a Darwin build proves Windows/WASI compatibility.

## Rendering

- Put backend-neutral types and scheduling in `AdaRender`; isolate Metal/WebGPU/platform details in existing backend boundaries.
- Treat render graph resource lifetime, pass ordering, and diagnostics as correctness constraints.
- Avoid creating GPU resources, pipelines, meshes, textures, tessellation output, or command infrastructure every frame when they can be cached safely.
- Shader changes may affect GLSL/SPIR-V/WGSL translation and bundled resources. Validate compilation/transpilation plus one real render path when possible.
- Keep coordinate systems, color spaces, texture formats, alignment, and row-byte assumptions explicit at API boundaries.

## WebAssembly Export

AdaEngine's browser export is experimental and spans the root manifest, `AdaWeb`, `AdaPlatform/Web`, `Plugins/AdaWebExportPlugin`, shader transpilation, resources, JavaScript runtime files, and the WASI SDK.

For detailed browser build/export/debug instructions, use the separate `adaengine-wasm-build` skill. For publishing demos into the website repository, use `adaengine-website-demos`. Do not duplicate or improvise their deployment workflow here.

An export is complete only when the emitted bundle contains its `.wasm`, JavaScript runtime/loader, manifests, package metadata, and required SwiftPM/game resources, and it is served over HTTP for a browser smoke test. A successful WASI compile alone is not an export validation.

## Native Platform Changes

Platform event, window, clipboard, cursor, display scale, timing, and lifecycle changes should be verified through the affected platform implementation and a shared semantic test where possible. Keep Apple-only APIs behind `canImport`/platform conditions and avoid leaking them into common modules.
