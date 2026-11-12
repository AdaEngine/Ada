# SAGA renderer and WESL shader cutover

Status: Proposed.

This proposal supersedes the end state in [the initial SAGA migration design](saga-migration.md) and builds on the [built-in shader migration](wesl-builtin-shader-migration.md). The existing work in both checkouts is the starting point.

## Starting point and cutover order

- AdaEngine `514794db8` already has a shared SAGA adapter and a browser export that opens the SAGA host by default. The Vulkan backend has native window adapters, but the default on Windows, Linux, and Android still uses Swan/Dawn unless built with `ADAENGINE_SAGA_NATIVE=1`. Apple still uses AdaEngine's existing Metal backend. The browser smoke golden covers one scene; it does not establish parity across engines or platforms.
- The local SAGA checkout at `cc2aacc` does not export `SAGAWebHost` or provide the `makePresentableDevice`, `addSurface`, and `removeSurface` Vulkan APIs required by this AdaEngine checkout. Identify and pin a compatible SAGA revision, or land and validate the missing API there, before switching native defaults. Verify the product graph and browser host assets from a clean checkout in CI.
- Enable defaults platform by platform once the production build and presentation checks pass. Use Windows Vulkan and the existing browser smoke as the first verification targets; exercise Linux and Android on their own hosts and coordinate Apple separately. Keep the old native path available during verification. Remove it after the affected platforms pass their cutover checks.

## Runtime and platform ownership

AdaRender retains its public rendering interfaces. SAGA owns GPU resources, shader compilation for its backends, submission and presentation. AdaRender adapts its encoders to SAGA command lists and preserves resource lifetimes across queued work, including resize, surface replacement, device shutdown and readback. Headless configurations continue to work without a graphics device.

| Platform | Default rendering path | Validation owner |
| --- | --- | --- |
| Windows | SAGA Vulkan with native window presentation | Codex |
| Linux | SAGA Vulkan with native window presentation | Codex |
| Android | SAGA Vulkan with Android surface lifecycle integration | Codex |
| Web | SAGA WebGPU with the packaged browser host | Codex |
| Apple | SAGA Metal | Contributor on Apple hardware |

Vulkan on Windows reuses the existing adapter and lets Windows, Linux and Android share native rendering code. Windows-specific GPU integrations, including enabled DLSS configurations, need verified SAGA support or an explicit scope decision before retiring their current path. Changes to SAGA can supply missing capabilities. Keep Apple-specific runtime work with the contributor while coordinating changes to shared interfaces and manifests.

Engine apps, Studio, standalone players and exported games select SAGA through their normal entry points without a renderer flag. Package the matching SAGA dependencies and web host assets with each distribution. Keep the sibling checkout and `ADAENGINE_SAGA_PACKAGE_PATH` for local development. Release and CI builds resolve a reproducible SAGA revision, including when built outside the development checkout.

## Shaders and project compatibility

Use WESL for modular shader sources and variants, and WGSL for standalone sources and generated entry points. Migrate engine and Studio shaders, material templates, Shader Graph generation and baking, and build-time export variants. Generate reflection from the WESL/WGSL pipeline and preserve resource layouts, entry points and diagnostics. SAGA can compile target artifacts such as SPIR-V for Vulkan.

Existing scenes, built-in materials and editable Shader Graphs retain their behavior. Rebuild older baked Shader Graph artifacts from source and diagnose stale artifacts when the source is unavailable. Projects with handwritten GLSL receive an actionable migration diagnostic and a guide for porting to WESL/WGSL. The completed cutover removes GLSL, Swan/Dawn and Tint from rendering and export dependencies, tooling and distribution payloads.

## Acceptance

- Build and launch the engine, Studio and applicable players through documented default entry points. Build each supported export through its production command and run the result, including browser and Android exports. Check that build manifests and shipped assets resolve to SAGA.
- Run GPU pixel readback tests against established references with existing tolerances where scenes are comparable. Cover 2D sprites, text and UI, 3D materials and Shader Graphs, shadows, post-processing and compute-driven passes. Extend the browser smoke golden with representative coverage and compare new backend captures against known-good output before adopting references. Review any intended pixel differences with the contributor.
- Capture presented frames from Studio and exported players on the platforms where they ship. Exercise resize and surface recreation, and exercise Android pause/resume. Offscreen pixel tests complement these presentation checks. Record the command, platform, GPU/backend, reference, threshold, and diff or capture path for each run.
- Run contribution validation and independent review. Apple sign-off includes contributor-provided builds, presented frames and golden results. Any target without runtime evidence remains open.

## User documentation

Update the discoverable [WESL shaders article](../../Sources/AdaEngine/AdaEngine.docc/Articles/Developers/WESLShaders.md), linked from the [AdaEngine DocC catalog](../../Sources/AdaEngine/AdaEngine.docc/AdaEngine.md), and the [tooling and export guide](../Tooling.md). Include a GLSL-to-WESL material example, Shader Graph rebaking instructions, and platform setup and export commands. Compile the shader example, run the documented export commands, and check DocC links and navigation before review.
