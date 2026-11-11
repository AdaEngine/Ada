# WESL shader sources in AdaEngine

Status: Accepted. Implementation is in progress.

## Goal

Use WESL as the source format for new modular WGSL shaders. Support shared shader code and compile-time variants while preserving the existing shader paths during incremental migration.

## First milestone

Follow the upstream [Imports](https://wesl-lang.dev/spec/Imports), [Visibility](https://wesl-lang.dev/spec/Visibility), and [Conditional Translation](https://wesl-lang.dev/spec/ConditionalTranslation) semantics for the supported syntax. Pin the upstream specification revision in the implementation and record its supported subset. This milestone covers local shader packages, explicit item and module imports, grouped imports, aliases, and qualified references. Resolve `package::` and `super::` paths within configured package roots, preferring `.wesl` over `.wgsl`. Defer wildcard imports, public re-exports, registry integration, and package publishing. Report unsupported syntax with source locations.

Apply `@if`, `@elif`, and `@else` using boolean build features before resolving imports. Cover conditional imports, top-level declarations, structure members, parameters, and statements. Keep WGSL `override` available for pipeline constants. Feature flags that alter the shader interface produce distinct artifacts with matching reflection.

## Integration

Use one in-process Swift WESL linker for native WebGPU and web export. AdaEngine supplies the package roots, entry points, and variant features. The linker resolves declarations and produces ordinary WGSL with original source locations for diagnostics. The JavaScript linker was evaluated, and the contributor selected an implementation in the engine. A textual include expander cannot provide the required name resolution and visibility.

Validate the linked WGSL and derive the entry point and resource metadata from the WGSL path using SAGA. Use the same artifacts for browser export, with linking and validation performed on the host. Include the active transitive module sources, feature flags, entry points, and toolchain version in the artifact cache key. Keep the existing GLSL and SPIR-V paths available to their current callers during migration.

## Acceptance and documentation

- Exercise the normal native and export entry points with a shader that imports a reusable helper and has two variants with different binding layouts. Use a small 2D pass before migrating the PBR suite.
- Verify aliases, relative and qualified paths, duplicate and missing symbols, visibility, inactive imports, and diagnostics referring to the imported source. Check that edits to a transitive module invalidate the affected artifact and that variants cannot share incompatible reflection.
- Verify the resulting shader and bindings on native WebGPU and in a real browser export. Compare rendering with the existing reference for the migrated pass.
- Add a WESL article to the AdaEngine DocC catalog and link it from its Topics. Include a tested two-file shader, variant configuration, supported syntax and diagnostics. Verify the documentation build and run the documented example through the production paths.
