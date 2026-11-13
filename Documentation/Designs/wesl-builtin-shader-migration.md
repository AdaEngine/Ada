# Replace the GLSL pipeline with SAGA and WESL/WGSL

Status: Accepted — implementation in progress.

Approval: explicit approval of this revised document in the project conversation on 2026-11-11; source reference recorded in the local contributor task state.

Scope decisions confirmed in the project conversation on 2026-11-11: use SAGA and WESL/WGSL throughout the first-party shader pipeline, and remove support for user-authored GLSL as well as built-in GLSL. These decisions supersede the earlier compatibility-preserving proposal. Approval of this revised document is recorded separately before implementation.

## Scope

Make WESL the maintained source of all built-in engine and Studio shaders. The checked-out inventory on 2026-11-11 contains 55 first-party tracked GLSL files under `Sources` and `Editor`, including shared headers and an editor sample. Of these, 31 have a same-basename WESL source and 24 do not. These are source-file counts, not executable-pass counts or proof of backend parity. Shared WGSL modules already cover some differently named GLSL headers. The inventory also includes embedded shader source and the production Shader Graph generator. The final public shader-loading contract accepts WESL/WGSL, not GLSL. Legacy inputs remain only as temporary migration references until cutover.

Third-party shader sources in `Sources/box3d`, `Sources/glslang`, and `Sources/harfbuzz` are outside the built-in migration. Do not rewrite vendored dependencies merely to reach a repository-wide zero-GLSL count.

## Current state and remaining ownership

- **Core pipelines:** the same-basename ports are present for most post-processing, 2D primitives, directional shadows, motion, and meshlet mapping. Remaining entry sources without peers are `flat3d`, `glass`, `local_volumetric_fog_3d`, `volumetric_fog_3d`, `particles_3d`, `path_tracing_3d`, and `screen_space_gi_3d`. The PBR port must preserve all actual material and geometry variants, not just the default mesh.
- **Render materials and mesh2D:** migrate the two canvas material sources, `mesh2d` and its three include modules. Reuse the existing `view.wgsl`, `mesh_morph.wgsl`, `color_grading.wgsl`, `tonemapping.wgsl`, and `mesh_visibility.wgsl` where applicable. Their presence is not evidence that every GLSL consumer has been migrated. Audit remaining baked diffuse, distance-field, and shadow-PCF helpers and all transitive consumers before retiring public GLSL headers.
- **UI and Studio:** port `ui_shadow`, `agent_activity`, `mobile_voice_orb`, and the `AgentActivityGlow` example. Preserve their existing appearance and parameters; this is not a UI redesign.
- **Generated shaders:** migrate `ShaderGraphProgram`, `ShaderGraphPipeline`, and `AdaShaderGraphBaker` together with the templates they extend. The current generator emits GLSL and the pipeline injects it through a GLSL marker. The baker still explicitly uses GLSL sprite/PBR/shadow/motion templates. Version archive and artifact identities when generated source format changes. Preserve graph topology and material parameters that can be regenerated through the new generator; explicitly reject legacy source-only GLSL archives rather than compiling them through a hidden fallback.

### Runtime and export constraints

`ShaderModule.supportsBundledWESL` currently selects WESL only for supported WebGPU builds. Native `createWESL` requires a WGSL device and excludes Android; Metal still consumes MSL and Android currently consumes SPIR-V on its WebGPU path. Consequently, same-basename GLSL files remain live fallbacks, not automatically redundant files.

The web exporter currently discovers both WESL and staged GLSL sources. Make source selection deterministic for migrated passes without dropping required fallback/backend artifacts. Move the hard-coded PBR variant inventory from its GLSL-only assumptions when porting `flat3d`; retain existing morph and meshlet variants and artifact naming/reflection compatibility. Browser startup continues to consume prelinked WGSL rather than SPIR-V or WESL source.

Producing MSL/SPIR-V from the maintained WESL source and integrating those artifacts is a required work item, not an assumed existing compiler capability. Establish available compiler output and validate representative resource layouts before removing any backend fallback. If a required output is unsupported, implement the missing SAGA capability as an explicit prerequisite or report the cutover as blocked. Temporary GLSL paths may exist during development but cannot remain in the delivered production pipeline. Do not silently switch runtime backends or declare a batch fully migrated without backend evidence.

## Migration sequence

1. Port the remaining UI passes, then the sprite, Spine, text, tilemap, and mesh2D passes. Share common transforms and data types through WESL imports. Preserve vertex locations, uniform offsets, resource bindings, color formats, and blending.
2. Port the 3D and compute passes. Carry over the actual material, skinning, terrain, wireframe, motion, and lighting variants. Use WESL conditions for structural changes and WGSL overrides for pipeline constants. Export every variant required by the browser. Use small parity batches and keep the production loader as the test entry point.
3. Port Shader Graph generation and baking to the same WESL/WGSL path. Preserve material identities and parameter/texture bindings; regenerate graph-backed archives and explicitly diagnose unsupported legacy source-only GLSL archives. Exercise generated variants together with the built-in templates they extend.
4. Deliver backend artifacts from the same WESL source. Native and browser WebGPU consume WGSL, Metal consumes MSL, and the current Android path consumes SPIR-V. Validate each output with its production backend before retiring that backend's duplicate built-in GLSL. Keep verified fallback paths during the transition.

## Shared requirements

Extend the in-process Swift linker and asset loaders where the migrated shaders require additional syntax, package resolution, and compute or variant metadata. Derive reflection and entry points from validated shader IR. Cache artifacts by entry point, backend, enabled features, toolchain revision, and the contents of all resolved source modules. The browser uses prelinked artifacts and their matching metadata. It does not link source files at startup.

## Breaking change and cutover

The user explicitly selected removal of user-authored GLSL support. WESL/WGSL is the maintained input format; SAGA supplies validation, compilation and authoritative IR-derived reflection. Replace GLSL-dependent reflection paths as part of cutover. Metal and other backend artifacts must originate from these inputs through SAGA, not a retained GLSL/SPIRV-Cross/Tint compilation route. Changing the GPU runtime backend is not implied by this shader migration.

- Reject `.glsl` inputs and legacy GLSL-backed materials with an actionable diagnostic naming the asset and the WESL/WGSL migration guide. Do not silently reinterpret source, render a substitute material, or automatically overwrite project assets.
- Regenerate Shader Graph artifacts from retained graph data. Source-only GLSL archives require manual porting and rebaking; provide a version-specific error rather than promising lossless automatic conversion.
- Remove first-party GLSL entrypoints, embedded source generators, packaged shader resources, export/baker recipes and production GLSL compiler dependencies after all supported backend replacements pass. Preserve negative tests proving legacy inputs fail clearly. Remove obsolete GLSL success fixtures or replace them with WESL/WGSL equivalents without dropping behavioral coverage.
- Remove direct first-party glslang, SPIRV-Cross and Tint pipeline dependencies when their callers have been replaced. Inspect remaining callers before removing targets or vendored directories: third-party-owned source is outside scope, but must not serve as a concealed first-party fallback.
- Review existing accepted shader-source/SAGA designs and ADRs for compatibility promises; record a superseding decision at implementation time instead of rewriting historical decisions.
- Final acceptance requires no production first-party GLSL compilation or fallback on any supported platform. A missing SAGA backend or unavailable required device check blocks full completion; retaining the old path is not the final solution.

## Acceptance and documentation

- Inventory production source and generator entry points before and after the migration. Every built-in shader has a WESL source and a tested artifact for each backend that uses it.
- Verify GPU output against existing render references and compute readbacks. Cover uniform layouts, variant selection, Shader Graph materials, and a real browser export with a representative 2D and 3D scene.
- Build and exercise native WebGPU, browser WebGPU, Metal, and Android. Track unavailable hardware or unsupported SAGA output separately from passing checks.
- Add regression tests for rejected GLSL assets and legacy source-only archives, graph-backed archive regeneration, SAGA reflection, and absence of production fallback/dependency wiring.
- Update the existing [WESL DocC article](../../Sources/AdaEngine/AdaEngine.docc/Articles/Developers/WESLShaders.md) with built-in shader organization, variants, backend prerequisites, and a tested GLSL-to-WESL porting example. Explain the breaking change, manual source-only archive migration and graph rebaking; link it from `Sources/AdaEngine/AdaEngine.docc/AdaEngine.md`. Keep its DocC navigation and verify the docs build and example.

## Implementation status (2026-11-12)

Done and tested:

- **Studio and UI passes:** `agent_activity.wesl` and `mobile_voice_orb.wesl` are WESL ports of the GLSL passes, and `ui_shadow.wesl` is now loaded by its material through `ReflectedMaterial.shaderModule()`. `BuiltInWESLShaderTests` links all three with the host compiler and checks entry points, the material uniform size (48, 48 and 32 bytes) and Metal stage output. The GLSL stage sources remain as the transitional fallback for backends without WESL support.
- **Native SAGA backend:** `RenderBackendType.saga` consumes WESL modules (`consumesWGSL`) and compiles GLSL-derived SPIR-V directly. `ADAENGINE_SAGA_NATIVE=1` links `AdaWGSLCompiler` so `ShaderModule.supportsBundledWESL` is true there.
- **Shader Graph generator:** `ShaderGraph.compileWGSL()` produces WGSL from the same lowered IR and shared analysis as `compileGLSL()` (identical parameter slots, texture bindings and source map). `ShaderGraphWGSLTests` links every math node across scalar and vector types, the noise graph and a textured graph, and checks bindings and uniform block size against the GLSL program. The existing GLSL graph tests still pass.

Blocked, in order:

1. **`flat3d`, `glass`, `particles_3d`, `path_tracing_3d`:** the PBR port must carry every material, skinning, terrain, wireframe, morph and meshlet variant and needs GPU reference comparison before the GLSL source can go. Not started.
2. **`mesh2d` family and the two canvas materials:** `ReflectedMaterial.shaderModule()` does not support macro variants, which `mesh2d` selects with `VERTEX_*` defines. The hook needs conditional-feature variants first.
3. **Shader Graph consumers:** `ShaderGraphPipeline`, the baker and the archive still embed GLSL in GLSL templates. The archive version must not change until the baker generates WGSL from the WESL templates in step 1, otherwise existing GLSL-baked archives would be mislabelled. At that point version 1 archives are rejected with a version-specific rebake error.
4. **GLSL removal:** loaders, packaged GLSL resources and compiler dependencies go last, after backend evidence for each platform.

## Shared helper modules (ported)

`Tonemapping`, `ColorGrading`, `ShadowPCF`, `Morph`, `DistanceField3D` and `BakedDiffuse3D` now exist as WESL modules in
`Sources/AdaRender/Assets/Shaders/WESL` (`tonemapping`, `color_grading`, `shadow_pcf`, `morph`, `distance_field`,
`baked_diffuse`), imported as `ada_engine::<module>`. Textures and samplers that the GLSL headers expected as includer
globals are function parameters. `Morph`, `DistanceField3D` and `BakedDiffuse3D` keep their fixed bindings and are gated by
the `ADA_MORPH`, `ADA_LIGHTMAP` and `ADA_IRRADIANCE_GRID` features. `WESLLibraryModuleTests` links each through an entry
shader and compiles it to MSL.

Known linker issue: a library function parameter that has the same name as a global declared in the importing entry file
(for example `lut`) fails with "Name ... is not imported". The tests use distinct global names; fix in SAGA's WESL linker.
