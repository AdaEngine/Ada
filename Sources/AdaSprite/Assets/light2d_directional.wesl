import package::light2d_fullscreen::{LightVertex, fullscreenLightVertex};

@vertex
fn light2d_directional_vert(@builtin(vertex_index) vertexIndex: u32) -> LightVertex {
    return fullscreenLightVertex(vertexIndex);
}

struct DirectionalLightData {
    lightRGBEnergy: vec4f,
    flags: vec4f,
}

@group(0) @binding(0) var shadowMask: texture_2d<f32>;
@group(0) @binding(1) var shadowSampler: sampler;
@group(0) @binding(2) var<uniform> light: DirectionalLightData;

@fragment
fn light2d_directional_frag(input: LightVertex) -> @location(0) vec4f {
    var rgb = light.lightRGBEnergy.rgb * light.lightRGBEnergy.a;
    if light.flags.x > 0.5 {
        rgb *= textureSample(shadowMask, shadowSampler, input.uv).r;
    }
    return vec4f(rgb, 1.0);
}
