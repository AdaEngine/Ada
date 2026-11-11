import package::fullscreen::{FullscreenVertex, fullscreenVertex};

struct SSAOUniform {
    projection: mat4x4f,
    parameters: vec4f,
    passParameters: vec4f,
}

@group(0) @binding(0) var positionImage: texture_2d<f32>;
@group(0) @binding(1) var normalImage: texture_2d<f32>;
@group(0) @binding(2) var rawAO: texture_2d<f32>;
@group(0) @binding(3) var nearestSampler: sampler;
@group(0) @binding(4) var<uniform> ssao: SSAOUniform;

@vertex
fn ssao_vertex(@builtin(vertex_index) index: u32) -> FullscreenVertex {
    return fullscreenVertex(index);
}

fn sampleAt(image: texture_2d<f32>, uv: vec2f) -> vec3f {
    return textureSampleLevel(image, nearestSampler, uv, 0.0).xyz;
}

fn bilateralAO(uv: vec2f, position: vec3f, normal: vec3f) -> f32 {
    let pixel = 1.0 / vec2f(textureDimensions(rawAO, 0));
    var sum = 0.0;
    var weightSum = 0.0;
    for (var y = -2; y <= 2; y++) {
        for (var x = -2; x <= 2; x++) {
            let sampleUV = clamp(uv + vec2f(f32(x), f32(y)) * pixel, pixel * 0.5, vec2f(1.0) - pixel * 0.5);
            let other = sampleAt(positionImage, sampleUV);
            let otherNormal = sampleAt(normalImage, sampleUV);
            if other.z <= 0.0 || length(otherNormal) < 0.1 {
                continue;
            }
            var weight = exp(-f32(x*x + y*y) / 4.0) * exp(-abs(position.z - other.z) / max(0.02, ssao.parameters.x * 0.1));
            weight *= pow(max(dot(normal, normalize(otherNormal)), 0.0), 8.0);
            sum += sampleAt(rawAO, sampleUV).r * weight;
            weightSum += weight;
        }
    }
    if weightSum > 0.0001 {
        return sum / weightSum;
    }
    return 1.0;
}

fn rawOcclusion(screenPosition: vec2f, position: vec3f, normal: vec3f) -> f32 {
    let helper = select(vec3f(1.0, 0.0, 0.0), vec3f(0.0, 1.0, 0.0), abs(normal.y) < 0.95);
    let tangent = normalize(cross(helper, normal));
    let bitangent = cross(normal, tangent);
    let cell = floor(screenPosition) % 4.0;
    let rotation = fract(sin(dot(cell, vec2f(12.9898, 78.233))) * 43758.5453) * 6.2831853;
    var occlusion = 0.0;
    for (var index = 0; index < 32; index++) {
        if index >= i32(ssao.parameters.w) {
            break;
        }
        let fraction = (f32(index) + 0.5) / ssao.parameters.w;
        let radial = sqrt(fraction);
        let angle = f32(index) * 2.3999632 + rotation;
        let direction = tangent * cos(angle) * radial + bitangent * sin(angle) * radial + normal * sqrt(1.0 - fraction);
        let samplePoint = position + direction * ssao.parameters.x * mix(0.2, 1.0, fraction * fraction);
        let clip = ssao.projection * vec4f(samplePoint, 1.0);
        if clip.w <= 0.0 {
            continue;
        }
        let uv = clip.xy / clip.w * vec2f(0.5, -0.5) + 0.5;
        if any(uv < vec2f(0.0)) || any(uv > vec2f(1.0)) {
            continue;
        }
        let surface = sampleAt(positionImage, uv);
        if surface.z <= 0.0 || distance(surface, position) > ssao.parameters.x {
            continue;
        }
        let range = smoothstep(0.0, 1.0, ssao.parameters.x / max(abs(position.z - surface.z), 0.001));
        occlusion += select(0.0, range, surface.z < samplePoint.z - ssao.parameters.z);
    }
    return clamp(1.0 - occlusion / ssao.parameters.w * ssao.parameters.y, 0.1, 1.0);
}

@fragment
fn ssao_fragment(input: FullscreenVertex) -> @location(0) vec4f {
    let position = sampleAt(positionImage, input.uv);
    let normal = sampleAt(normalImage, input.uv);
    if length(normal) < 0.1 || position.z <= 0.0 {
        return vec4f(1.0);
    }
    let direction = normalize(normal);
    if ssao.passParameters.x > 0.5 {
        return vec4f(vec3f(bilateralAO(input.uv, position, direction)), 1.0);
    }
    return vec4f(vec3f(rawOcclusion(input.position.xy, position, direction)), 1.0);
}
