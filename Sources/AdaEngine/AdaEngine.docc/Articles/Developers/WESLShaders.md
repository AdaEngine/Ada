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

On native WebGPU, `ShaderModule.create(from:)` loads the default variant from a `.wesl` file. Use `ShaderModule.createWESL(from:packageRoot:features:)` to supply a package root or enable features. A shader module can have one entry point per active stage.

The built-in quad, circle, line, and linear gradient use WESL on WebGPU. The sprite, instanced sprite, Spine, text, and tilemap pipelines also use WESL on WebGPU. These shaders import the shared view projection from `ada_engine::view`. The runtime and web exporter register this package from the AdaRender shader resources. The 2D composite, point, and directional lighting passes share their fullscreen vertex stage through `light2d_fullscreen.wgsl`. Web export links their default variants on the host and packages the WGSL stages for browser startup. In automatic web export, the entry file's directory is the local package root. Backends without WESL support load the corresponding GLSL shaders.

Fullscreen presentation, local shadow atlas clears, and temporal tone mapping use a common fullscreen vertex module. The temporal tone mapping pass imports the output transform and color grading modules. Sky motion, FXAA, SSAO, the 3D debug view, and temporal output depth also use the fullscreen module. The depth pass and portable temporal reconstruction use depth texture bindings and integer texel loads. Reconstruction reads its R32Float history without filtering. Bloom, automatic exposure, depth of field, and camera effects use the same fullscreen vertex module. Camera effects also use the shared display dithering function.

The screen-space reflection pass and path-tracing composite import environment fog, exposure, bloom, and grading from the shared composite module.

Directional shadows and motion vectors use WESL base shaders and `ADA_MORPH` variants. They share mesh morphing, face and fade visibility, and base-color alpha sampling. Web export packages the linked variant with its feature name, for example `directional_shadow_3d.wesl.ADA_MORPH.vert.wgsl`.

Dynamic irradiance probe updates use integer texel reads for transport, history, and the local shadow atlas.

The meshlet map exports the base shader and the three combinations of its reflection response and surface attachments.

The linker reports linking errors with the affected file path. This initial implementation supports explicit local imports and conditional declarations. It rejects cyclic imports and local names that shadow linked bindings. Web export emits named variants for built-in pipelines that declare them. Caching linked artifacts and remapping compiler diagnostics to the original source are pending.
