import package::fullscreen::{FullscreenVertex, fullscreenVertex};

struct FXAAUniform {
    inverseSize: vec4f,
}

@group(0) @binding(0) var sceneColor: texture_2d<f32>;
@group(0) @binding(1) var linearSampler: sampler;
@group(0) @binding(2) var<uniform> fxaa: FXAAUniform;

@vertex
fn fxaa_vertex(@builtin(vertex_index) index: u32) -> FullscreenVertex {
    return fullscreenVertex(index);
}

fn sampleColor(uv: vec2f) -> vec3f {
    // The scene color is a single-mip render target.
    return textureSampleLevel(sceneColor, linearSampler, uv, 0.0).rgb;
}

@fragment
fn fxaa_fragment(input: FullscreenVertex) -> @location(0) vec4f {
    let uv = input.uv;
    let pixel = fxaa.inverseSize.xy;
    let center = sampleColor(uv);
    let nw = sampleColor(uv + vec2f(-1.0, -1.0) * pixel);
    let ne = sampleColor(uv + vec2f(1.0, -1.0) * pixel);
    let sw = sampleColor(uv + vec2f(-1.0, 1.0) * pixel);
    let se = sampleColor(uv + vec2f(1.0, 1.0) * pixel);
    let luma = vec3f(0.299, 0.587, 0.114);
    let middle = dot(center, luma);
    let a = dot(nw, luma);
    let b = dot(ne, luma);
    let c = dot(sw, luma);
    let d = dot(se, luma);
    let minimum = min(middle, min(min(a, b), min(c, d)));
    let maximum = max(middle, max(max(a, b), max(c, d)));
    if maximum - minimum < max(0.0312, maximum * 0.125) {
        return vec4f(center, 1.0);
    }
    let edge = vec2f(-((a + b) - (c + d)), (a + c) - (b + d));
    let reduce = max((a + b + c + d) * 0.03125, 0.0078125);
    let direction = clamp(edge / (min(abs(edge.x), abs(edge.y)) + reduce), vec2f(-8.0), vec2f(8.0)) * pixel;
    let first = 0.5 * (sampleColor(uv + direction * (-1.0 / 6.0)) + sampleColor(uv + direction * (1.0 / 6.0)));
    let second = first * 0.5 + 0.25 * (sampleColor(uv - direction * 0.5) + sampleColor(uv + direction * 0.5));
    let secondLuma = dot(second, luma);
    return vec4f(select(second, first, secondLuma < minimum || secondLuma > maximum), 1.0);
}
