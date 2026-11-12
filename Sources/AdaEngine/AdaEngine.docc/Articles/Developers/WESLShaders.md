# Compile modular WESL shaders

Link local shader modules and compile feature variants to WGSL with the AdaEngine host tool.

AdaEngine links the modules in Swift and validates the result with the local SAGACompiler. The shader syntax follows the [WESL specification snapshot](https://github.com/webgpu-tools/wesl-spec/tree/37bf3f3a2164781040e7a42fc6529cb34e2c059b).

## Link two shader files

Save a helper as `shaders/common.wesl`.

```wgsl
fn shade() -> vec4f { return vec4f(1); }
```

Save the entry module as `shaders/main.wesl`.

```wgsl
import package::common::shade as baseColor;

@if(textured)
@group(0) @binding(0) var image: texture_2d<f32>;

@fragment fn fragmentMain() -> @location(0) vec4f {
    @if(textured)
    return textureLoad(image, vec2i(0), 0) * baseColor();
    @else
    return baseColor();
}
```

Enable the host export tools and compile both variants.

```sh
export ADAENGINE_WEB_EXPORT=1
swift run AdaShaderTranspilerTool --input shaders/main.wesl --output-directory compiled
swift run AdaShaderTranspilerTool --input shaders/main.wesl --output-directory compiled --feature textured
```

In PowerShell, set the variable with `$env:ADAENGINE_WEB_EXPORT = '1'`.
The tool writes `compiled/main.wgsl` and `compiled/main.textured.wgsl`. The textured variant declares a texture at group 0, binding 0. Use `--wesl-root` when the main module lives below the package root. Use `--wesl-dependency name=directory` to register a package for imports starting with `name::`. Inside that dependency, `package::` refers to its own root.

On SAGA and native WebGPU builds with WESL support, `ShaderModule.create(from:)` loads the default variant from a `.wesl` file. Use `ShaderModule.createWESL(from:packageRoot:features:)` to supply a package root or enable features. A shader module can have one entry point per active stage. The browser uses linked WGSL, and SAGA compiles the same linked source to MSL for Metal or SPIR-V for Vulkan. Enable the SAGA Metal development path with `ADAENGINE_SAGA_METAL=1`.

When porting a GLSL material, move its sampler and texture into separate WGSL bindings and pass vertex outputs explicitly between stages. The fragment example above uses `textureLoad` for integer texel coordinates. For normalized, filtered sampling, declare a `sampler` at a separate binding and use `textureSample(image, imageSampler, uv)`. Update the material's binding numbers to match the WESL declarations and compile every feature combination the material uses.

The built-in quad, circle, line, and linear gradient use WESL on WebGPU. The sprite, instanced sprite, Spine, text, and tilemap pipelines also use WESL on WebGPU. These shaders import the shared view projection from `ada_engine::view`. The runtime and web exporter register this package from the AdaRender shader resources. The 2D composite, point, and directional lighting passes share their fullscreen vertex stage through `light2d_fullscreen.wgsl`. Web export links their default variants on the host and packages the WGSL stages for browser startup. In automatic web export, the entry file's directory is the local package root. Backends without WESL support load the corresponding GLSL shaders.

Fullscreen presentation, local shadow atlas clears, and temporal tone mapping use a common fullscreen vertex module. The temporal tone mapping pass imports the output transform and color grading modules. Sky motion, FXAA, SSAO, the 3D debug view, and temporal output depth also use the fullscreen module. The depth pass and portable temporal reconstruction use depth texture bindings and integer texel loads. Reconstruction reads its R32Float history without filtering. Bloom, automatic exposure, depth of field, and camera effects use the same fullscreen vertex module. Camera effects also use the shared display dithering function.

The screen-space reflection pass and path-tracing composite import environment fog, exposure, bloom, and grading from the shared composite module.

Directional shadows and motion vectors use WESL base shaders and `ADA_MORPH` variants. They share mesh morphing, face and fade visibility, and base-color alpha sampling. Web export packages the linked variant with its feature name, for example `directional_shadow_3d.wesl.ADA_MORPH.vert.wgsl`.

Dynamic irradiance probe updates use integer texel reads for transport, history, and the local shadow atlas.

The meshlet map exports the base shader and the three combinations of its reflection response and surface attachments.

The linker reports linking errors with the affected file path. This initial implementation supports explicit local imports and conditional declarations. It rejects cyclic imports and local names that shadow linked bindings. Web export emits named variants for built-in pipelines that declare them. Caching linked artifacts and remapping compiler diagnostics to the original source are pending.


## Emit native backend code with SAGA

The host tool can compile linked WESL directly through SAGA to Metal source or binary SPIR-V.
Enable the host tools with `ADAENGINE_WEB_EXPORT=1`, then use the same source package and feature flags:

```sh
swift run AdaShaderTranspilerTool --input shaders/main.wesl --output-directory compiled --target msl
swift run AdaShaderTranspilerTool --input shaders/main.wesl --output-directory compiled --target spirv --feature textured
```

For the fragment-only example above these commands write `main.frag.msl` and
`main.textured.frag.spv`. Vertex and compute stages use `.vert` and `.comp` suffixes.
SPIR-V output is a little-endian binary module, not a GLSL string or a WGSL sidecar.
The default target remains WGSL. `--web-stages` is only valid with WGSL output.
A bundled module must have at most one entry point of each stage; the tool compiles every stage
before writing the native batch, so a compiler failure does not publish a partial batch.
Filesystem failures during writing can still leave individual completed files.

For in-process integration, `WESLBackendCompiler.compile(_:to:)` takes the artifact returned by
`WESLHostCompiler.compile` and returns each emitted stage, its source and generated entry-point names,
its code bytes and its full SAGA render/compute reflection. Use the reflected Metal buffer, texture
and sampler indices: WGSL binding numbers are not necessarily Metal resource slots.

Custom `ReflectedMaterial` types may override `shaderModule()` to supply a complete module instead of
separate legacy vertex/fragment sources. The default returns `nil`, preserving the current source path.
`CustomMaterial` retains a supplied module and uses per-instance material identity; it does not recompile
its stages as GLSL. Such a module must already have the correct reflection and selected feature variant:
passing shader defines afterward is rejected, and serializing a module-backed material without its
original source is unsupported. Hook loading failures propagate when creating the material's module.
The native WebGPU WESL loader now reads SAGA-validated IR for uniform-buffer
reachability and minimum byte sizes, including matrix padding. This layout query does not regenerate
WGSL: it follows function calls and global references in the selected entry's IR and uses validated
struct spans and array strides (with WGSL scalar/vector/matrix sizes for non-struct roots). `WESLBackendCompiler.webGPUUniformBuffers`
exposes those logical group/binding layouts without substituting Metal slots. Uniform binding arrays
are rejected until a runtime adapter exists. If a reflected uniform cannot be matched by the transitional
name parser, loading fails rather than allocating a zero-sized buffer.
This is not complete reflection integration: resource names, member metadata and non-uniform resources
still depend on the existing parser; material property-name mapping and browser sidecar metadata remain pending.
The new UI shadow source is therefore not yet selected by the production shadow material.

These command-line native outputs are code-generation artifacts, **not ready-to-load material packages**.
The command does not serialize the runtime reflection, cache identity, vertex-stream mapping or pipeline state.
The existing runtime still selects GLSL on backends without an integrated WESL loader.
Emitting or compiling Metal source does not prove draw-time binding correctness or pixel parity.

### Full GLSL removal is an in-progress breaking migration

The approved destination is WESL/WGSL input, SAGA compilation and reflection, and no first-party GLSL fallback.
This is not yet a completed cutover: user GLSL inputs remain supported by the old production loader until
its replacement and backend verification land. Do not delete working project assets based only on the new tool option.

When porting a shader, replace GLSL stage pragmas with WGSL entry-point attributes and use explicit
WESL imports instead of preprocessor includes. Port compile-time interface changes to WESL conditions,
keep buffer byte layouts and material bindings aligned with the host types, then compile and exercise every variant.
For example, the shared `shade` helper and `@fragment` entry point above replace a GLSL include and
fragment `main`; `@if(textured)` replaces a structural preprocessor condition, not a runtime branch.

Graph-backed Shader Graph assets will be regenerated through the new generator. Archives retaining only
GLSL source will require a manual WESL/WGSL port and rebake; no automatic lossless source conversion is promised.
The final loader diagnostic and archive-version migration are still pending implementation.
