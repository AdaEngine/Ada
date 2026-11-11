import package::fullscreen::{FullscreenVertex, fullscreenVertex};

struct DepthOfFieldUniform {
    parameters: vec4f,
    size: vec4f,
}

@group(0) @binding(0) var colorImage: texture_2d<f32>;
@group(0) @binding(1) var positionImage: texture_2d<f32>;
@group(0) @binding(2) var linearSampler: sampler;
@group(0) @binding(3) var nearestSampler: sampler;
@group(0) @binding(4) var<uniform> dof: DepthOfFieldUniform;

const SAMPLE_COUNT: i32 = 24;
const GOLDEN_ANGLE: f32 = 2.39996323;

@vertex
fn depth_of_field_vertex(@builtin(vertex_index) index: u32) -> FullscreenVertex {
    return fullscreenVertex(index);
}

fn circleOfConfusion(uv: vec2f) -> f32 {
    let position = textureSampleLevel(positionImage, nearestSampler, uv, 0.0).xyz;
    let depth = select(max(position.z, 0.001), 100000.0, length(position) < 0.0001);
    return clamp(dof.parameters.z * abs(depth - dof.parameters.y) / depth * dof.parameters.w, 0.0, dof.parameters.w);
}

fn colorAt(uv: vec2f) -> vec3f {
    return textureSampleLevel(colorImage, linearSampler, uv, 0.0).rgb;
}

// A neighbor contributes only as far as its own circle of confusion reaches.
fn gather(uv: vec2f) -> vec4f {
    let center = colorAt(uv);
    let radius = circleOfConfusion(uv);
    if radius < 0.5 {
        return vec4f(center, 1.0);
    }
    var sum = center;
    var weightSum = 1.0;
    for (var index = 0; index < SAMPLE_COUNT; index++) {
        let distanceInPixels = sqrt((f32(index) + 0.5) / f32(SAMPLE_COUNT)) * radius;
        let angle = f32(index) * GOLDEN_ANGLE;
        let sampleUV = uv + vec2f(cos(angle), sin(angle)) * distanceInPixels * dof.size.xy;
        let weight = clamp(circleOfConfusion(sampleUV) / max(distanceInPixels, 1.0), 0.0, 1.0);
        sum += colorAt(sampleUV) * weight;
        weightSum += weight;
    }
    return vec4f(sum / weightSum, 1.0);
}

@fragment
fn depth_of_field_fragment(input: FullscreenVertex) -> @location(0) vec4f {
    if dof.parameters.x < 0.5 {
        return gather(input.uv);
    }
    return vec4f(textureSampleLevel(colorImage, nearestSampler, input.uv, 0.0).rgb, 1.0);
}
