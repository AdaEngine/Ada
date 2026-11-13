import package::light2d_fullscreen::{LightVertex, fullscreenLightVertex};

@vertex
fn light2d_point_vert(@builtin(vertex_index) vertexIndex: u32) -> LightVertex {
    return fullscreenLightVertex(vertexIndex);
}

struct PointLightData {
    invViewProjection: mat4x4f,
    lightXYRadius: vec4f,
    lightRGBEnergy: vec4f,
    flags: vec4f,
}

@group(0) @binding(0) var shadowMask: texture_2d<f32>;
@group(0) @binding(1) var shadowSampler: sampler;
@group(0) @binding(2) var cookie: texture_2d<f32>;
@group(0) @binding(3) var cookieSampler: sampler;
@group(0) @binding(4) var<uniform> light: PointLightData;

@fragment
fn light2d_point_frag(input: LightVertex) -> @location(0) vec4f {
    let ndc = input.uv * vec2f(2.0, -2.0) + vec2f(-1.0, 1.0);
    let worldPosition = light.invViewProjection * vec4f(ndc, 0.0, 1.0);
    let world = worldPosition.xy / max(worldPosition.w, 1e-5);
    let radius = max(light.lightXYRadius.z, 1e-3);
    let distanceToLight = distance(world, light.lightXYRadius.xy);
    let attenuation = 1.0 - smoothstep(0.0, radius, distanceToLight);
    var rgb = light.lightRGBEnergy.rgb * light.lightRGBEnergy.a * attenuation;
    if light.flags.x > 0.5 {
        rgb *= textureSample(shadowMask, shadowSampler, input.uv).r;
    }
    if light.flags.y > 0.5 {
        rgb *= textureSample(cookie, cookieSampler, input.uv).rgb;
    }
    return vec4f(rgb, 1.0);
}
