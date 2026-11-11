# Migrate the built-in shader library to WESL

Status: Proposed.

## Scope

Make WESL the maintained source of all built-in engine and Studio shaders. The initial inventory contains 42 staged GLSL files under `Sources` and two under `Editor`. The gradient already has a verified WESL port on native and browser WebGPU. The inventory also includes shared GLSL headers, embedded shader source, and the production Shader Graph generator. Keep GLSL imports available for existing user projects and compatibility tests.

## Migration sequence

1. Port the remaining UI passes, then the sprite, Spine, text, tilemap, and mesh2D passes. Share common transforms and data types through WESL imports. Preserve vertex locations, uniform offsets, resource bindings, color formats, and blending.
2. Port the 3D and compute passes. Carry over the actual material, skinning, terrain, wireframe, motion, and lighting variants. Use WESL conditions for structural changes and WGSL overrides for pipeline constants. Export every variant required by the browser. Use small parity batches and keep the production loader as the test entry point.
3. Port Shader Graph generation and baking to the same WESL/WGSL path. Preserve material identities, parameter and texture bindings, and existing project archives. Exercise generated variants together with the built-in templates they extend.
4. Deliver backend artifacts from the same WESL source. Native and browser WebGPU consume WGSL, Metal consumes MSL, and the current Android path consumes SPIR-V. Validate each output with its production backend before retiring that backend's duplicate built-in GLSL. Keep verified fallback paths during the transition.

## Shared requirements

Extend the in-process Swift linker and asset loaders where the migrated shaders require additional syntax, package resolution, and compute or variant metadata. Derive reflection and entry points from validated shader IR. Cache artifacts by entry point, backend, enabled features, toolchain revision, and the contents of all resolved source modules. The browser uses prelinked artifacts and their matching metadata. It does not link source files at startup.

GLSL compatibility for user projects remains part of the public shader-loading contract. Changing the GPU runtime backend is a separate migration.

## Acceptance and documentation

- Inventory production source and generator entry points before and after the migration. Every built-in shader has a WESL source and a tested artifact for each backend that uses it.
- Verify GPU output against existing render references and compute readbacks. Cover uniform layouts, variant selection, Shader Graph materials, and a real browser export with a representative 2D and 3D scene.
- Build and exercise native WebGPU, browser WebGPU, Metal, and Android. Track unavailable hardware or unsupported SAGA output separately from passing checks.
- Update the existing [WESL DocC article](../../Sources/AdaEngine/AdaEngine.docc/Articles/Developers/WESLShaders.md) with built-in shader organization, variants, backend prerequisites, and a tested porting example. Keep its DocC navigation and verify the docs build and example.
