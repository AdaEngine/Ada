import package::light2d_fullscreen::{LightVertex, fullscreenLightVertex};

@vertex
fn light2d_composite_vert(@builtin(vertex_index) vertexIndex: u32) -> LightVertex {
    return fullscreenLightVertex(vertexIndex);
}

struct CompositeData {
    modulate: vec4f,
}

@group(0) @binding(0) var albedoImage: texture_2d<f32>;
@group(0) @binding(1) var lightAccum: texture_2d<f32>;
@group(0) @binding(2) var lightSampler: sampler;
@group(0) @binding(3) var<uniform> composite: CompositeData;

@fragment
fn light2d_composite_frag(input: LightVertex) -> @location(0) vec4f {
    let albedo = textureSample(albedoImage, lightSampler, input.uv);
    let addLight = textureSample(lightAccum, lightSampler, input.uv).rgb;
    return vec4f(albedo.rgb * composite.modulate.rgb + albedo.rgb * addLight, albedo.a);
}
