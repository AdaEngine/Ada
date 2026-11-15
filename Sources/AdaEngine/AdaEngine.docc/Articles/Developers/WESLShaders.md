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

On SAGA and native WebGPU builds with WESL support, `ShaderModule.create(from:)` loads the default variant from a `.wesl` file. Use `ShaderModule.createWESL(from:packageRoot:features:)` to supply a package root or enable features. A shader module can have one entry point per active stage. The browser uses linked WGSL, and SAGA compiles the same linked source to MSL for Metal or SPIR-V for Vulkan. SAGAMetal is the default renderer on macOS, iOS, tvOS, and visionOS.

In Studio, choose **New → Shaders** and select **Vertex Shader**, **Fragment Shader**, or **Compute Shader** to create a `.wesl` file. The vertex and fragment templates match at location 0 for UV coordinates. The compute template clears the storage buffer bound at group 0, binding 0. The Studio code editor opens these files with WGSL highlighting.

The native headless renderer also loads built-in WESL modules. The CPU compiler links their feature variants and supplies the same uniform layouts to headless tools and tests. Set `ADAENGINE_HEADLESS=1` when building a native package for a machine without graphics hardware.

On visionOS SAGA records the compositor and hover passes on the same Metal queue as the
render graph. The geometry pass uses the selected layer of the system rate map.
A native pass resolves the packed color and depth textures to logical screen size
before screen-space effects and compositor presentation.

Windows, Linux and Android builds use the pinned SAGA Vulkan revision through SwiftPM. Set `ADAENGINE_SAGA_PACKAGE_PATH` when developing or testing against a local SAGA checkout.

On native SAGA backends, set `Environment3D.gpuOcclusionEnabled` to enable GPU
occlusion culling. The depth prepass feeds a current-frame Hi-Z pyramid. A WGSL
compute pass compacts visible instances and writes the arguments for indexed
indirect draws. The renderer uses CPU visibility while the compute pipelines and
per-view resources are preparing or unavailable.

For Studio Android export, the **SAGA checkout (optional)** setting and the CLI's `--saga` flag select a local checkout. Projects can use the published pin directly with the normal Android SDK and Swift toolchain.

When porting a GLSL material, move its sampler and texture into separate WGSL bindings and pass vertex outputs explicitly between stages. The fragment example above uses `textureLoad` for integer texel coordinates. For normalized, filtered sampling, declare a `sampler` at a separate binding and use `textureSample(image, imageSampler, uv)`. Update the material's binding numbers to match the WESL declarations and compile every feature combination the material uses.

The built-in quad, circle, line, and linear gradient use WESL on WebGPU. The sprite, instanced sprite, Spine, text, and tilemap pipelines also use WESL on WebGPU. These shaders import the shared view projection from `ada_engine::view`. The runtime and web exporter register this package from the AdaRender shader resources. The 2D composite, point, and directional lighting passes share their fullscreen vertex stage through `light2d_fullscreen.wgsl`. Web export links their default variants on the host and packages the WGSL stages for browser startup. In automatic web export, the entry file's directory is the local package root.

Fullscreen presentation, local shadow atlas clears, and temporal tone mapping use a common fullscreen vertex module. The temporal tone mapping pass imports the output transform and color grading modules. Sky motion, FXAA, SSAO, the 3D debug view, and temporal output depth also use the fullscreen module. The depth pass and portable temporal reconstruction use depth texture bindings and integer texel loads. Reconstruction reads its R32Float history without filtering. Bloom, automatic exposure, depth of field, and camera effects use the same fullscreen vertex module. Camera effects also use the shared display dithering function.

The screen-space reflection pass and path-tracing composite import environment fog, exposure, bloom, and grading from the shared composite module.

Directional shadows and motion vectors use WESL base shaders and `ADA_MORPH` variants. They share mesh morphing, face and fade visibility, and base-color alpha sampling. Web export packages the linked variant with its feature name, for example `directional_shadow_3d.wesl.ADA_MORPH.vert.wgsl`.

The browser's PBR mesh pipeline also links from WESL. Web export packages four versions of `flat3d.wesl`: the default, terrain, wireframe, and terrain with wireframe. For example, the terrain vertex stage is `flat3d.wesl.ADA_TERRAIN.vert.wgsl`. Native SAGA builds link their material variants on demand.

Web export and the host shader tool take WESL shader modules. If an older project contains GLSL sources, port them to `.wesl`, update the material references, and export again. For a Web Player project asset that names a standalone WGSL fragment, compile the WESL module to `.wgsl` and reference that output. Web export reports the path of the first legacy shader in the project assets or a resource bundle used by the build. If the reported file is left over in a previous build directory, export again with a fresh `--scratch-path`. The export packages linked WGSL with the WESL entry modules.

Web exports load the prelinked WGSL stages from the export, including when using the headless renderer. Standalone headless WASI builds link WESL at runtime through the SAGA CPU compiler. Both WASI profiles require WESL for shader modules.

Native Vulkan builds on Windows, Linux and Android link shader modules through SAGA and require
`.wesl` module inputs. Port existing GLSL stages and update material references before loading them.
Custom reflected and UI materials supply both stages through `shaderModule()`. For materials
that select feature variants, set `usesVariantShaderModules` to `true` and implement `variantShaderModule(defines:)`.

Shader Graph materials keep one generated WGSL program for the native WESL templates and the browser's baked fragments. Studio's Source view displays that WGSL. Its preview validates the generated functions with SAGA when the CPU compiler is available and maps source diagnostics to graph nodes and ports.

In Swift tooling, use `graph.compileWGSL().validateWGSL()` for CPU-only validation. Use the WESL host compiler for standalone shader stages and rebake Shader Graph archives from the original graph assets. The old GLSL validator and GLSL-to-SPIR-V fragment export APIs have been removed.

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
The native WESL loader reads SAGA-validated IR for uniform-buffer
reachability and minimum byte sizes, including matrix padding. This layout query does not regenerate
WGSL: it follows function calls and global references in the selected entry's IR and uses validated
struct spans and array strides (with WGSL scalar/vector/matrix sizes for non-struct roots). `WESLBackendCompiler.webGPUUniformBuffers`
exposes those logical group/binding layouts without substituting Metal slots. Uniform binding arrays
are rejected until a runtime adapter exists. If a reflected uniform cannot be matched by the transitional
name parser, loading fails rather than allocating a zero-sized buffer.
The loader reads resource names, member metadata, and non-uniform resources from the linked WGSL.
The production UI shadow material uses its linked WESL module on SAGA.

These command-line native outputs are code-generation artifacts, **not ready-to-load material packages**.
The command does not serialize the runtime reflection, cache identity, vertex-stream mapping or pipeline state.
Emitting or compiling Metal source does not prove draw-time binding correctness or pixel parity.

### Migrating projects from GLSL

Use WESL or WGSL for project shaders on SAGA. The asset loader rejects GLSL-backed
`.mat` files and reports the material path at load time. Direct `ShaderSource`
initializers also reject GLSL files and inline GLSL. Load WESL with
`ShaderModule.create(from:)`, or use `ShaderSource(source:lang: .wgsl)` when
you need to hold raw WGSL text. Keep the original project assets while porting
their shaders and verifying the replacement.

When porting a shader, replace GLSL stage pragmas with WGSL entry-point attributes and use explicit
WESL imports instead of preprocessor includes. Port compile-time interface changes to WESL conditions,
keep buffer byte layouts and material bindings aligned with the host types, then compile and exercise every variant.
For example, the shared `shade` helper and `@fragment` entry point above replace a GLSL include and
fragment `main`; `@if(textured)` replaces a structural preprocessor condition, not a runtime branch.

Rebake a project that has the original graph assets from the engine checkout:

```sh
ADAENGINE_WEB_EXPORT=1 swift run AdaShaderGraphBaker path/to/GameAssets
```

The baker regenerates WGSL and writes the current archive version. The runtime rejects older GLSL-baked archives
with a rebake diagnostic. If a project has only GLSL source, port its stages to WESL first.
