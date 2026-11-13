import package::fullscreen::{FullscreenVertex, fullscreenVertex};

struct BloomUniform {
    parameters: vec4f,
    texel: vec4f,
}

@group(0) @binding(0) var sourceImage: texture_2d<f32>;
@group(0) @binding(1) var sourceSampler: sampler;
@group(0) @binding(2) var exposureImage: texture_2d<f32>;
@group(0) @binding(4) var<uniform> bloom: BloomUniform;

@vertex
fn bloom_vertex(@builtin(vertex_index) index: u32) -> FullscreenVertex {
    return fullscreenVertex(index);
}

fn fetch(uv: vec2f) -> vec3f {
    return textureSampleLevel(sourceImage, sourceSampler, uv, 0.0).rgb;
}

fn exposureScale() -> f32 {
    var scale = bloom.texel.z;
    if bloom.texel.w > 0.5 {
        let state = textureSampleLevel(exposureImage, sourceSampler, vec2f(0.5), 0.0).rg;
        scale *= exp2(state.x + state.y);
    }
    return scale;
}

fn prefilter(color: vec3f, scale: f32) -> vec3f {
    let exposed = clamp(color * scale, vec3f(0.0), vec3f(65000.0));
    let brightness = max(exposed.r, max(exposed.g, exposed.b));
    let knee = max(bloom.parameters.z, 0.0001);
    let soft = clamp(brightness - bloom.parameters.y + knee, 0.0, 2.0 * knee);
    let contribution = max(soft * soft / (4.0 * knee + 0.0001), brightness - bloom.parameters.y) / max(brightness, 0.0001);
    return exposed * contribution;
}

@fragment
fn bloom_fragment(input: FullscreenVertex) -> @location(0) vec4f {
    let uv = input.uv;
    let texel = bloom.texel.xy;
    let leftDown = vec2f(-texel.x, -texel.y);
    let rightDown = vec2f(texel.x, -texel.y);
    let leftUp = vec2f(-texel.x, texel.y);
    let rightUp = texel;
    if bloom.parameters.x < 0.5 {
        let scale = exposureScale();
        let result = prefilter(fetch(uv), scale) * 4.0
            + prefilter(fetch(uv + leftDown), scale) + prefilter(fetch(uv + rightDown), scale)
            + prefilter(fetch(uv + leftUp), scale) + prefilter(fetch(uv + rightUp), scale);
        return vec4f(result / 8.0, 1.0);
    }
    if bloom.parameters.x < 1.5 {
        let result = fetch(uv) * 4.0 + fetch(uv + leftDown) + fetch(uv + rightDown) + fetch(uv + leftUp) + fetch(uv + rightUp);
        return vec4f(result / 8.0, 1.0);
    }
    let result = fetch(uv + vec2f(-texel.x * 2.0, 0.0)) + fetch(uv + leftUp) * 2.0
        + fetch(uv + vec2f(0.0, texel.y * 2.0)) + fetch(uv + rightUp) * 2.0
        + fetch(uv + vec2f(texel.x * 2.0, 0.0)) + fetch(uv + rightDown) * 2.0
        + fetch(uv + vec2f(0.0, -texel.y * 2.0)) + fetch(uv + leftDown) * 2.0;
    return vec4f(result / 12.0 * bloom.parameters.w, 1.0);
}
