import package::fullscreen::{FullscreenVertex, fullscreenVertex};

struct TemporalConstants {
    parameters: vec4f,
}

struct TemporalOutput {
    @location(0) color: vec4f,
    @location(1) history: vec4f,
    @location(2) depth: f32,
}

@group(0) @binding(0) var colorImage: texture_2d<f32>;
@group(0) @binding(1) var depthImage: texture_depth_2d;
@group(0) @binding(2) var motionImage: texture_2d<f32>;
@group(0) @binding(3) var reactiveImage: texture_2d<f32>;
@group(0) @binding(4) var historyImage: texture_2d<f32>;
@group(0) @binding(5) var historyDepth: texture_2d<f32>;
@group(0) @binding(6) var linearSampler: sampler;
@group(0) @binding(7) var nearestSampler: sampler;
@group(0) @binding(8) var<uniform> temporal: TemporalConstants;

@vertex
fn fullscreen_vertex(@builtin(vertex_index) index: u32) -> FullscreenVertex {
    return fullscreenVertex(index);
}

fn toYCoCg(color: vec3f) -> vec3f {
    return vec3f(dot(color, vec3f(0.25, 0.5, 0.25)), color.r - color.b, color.g - (color.r + color.b) * 0.5);
}

fn toRGB(color: vec3f) -> vec3f {
    return vec3f(color.x + color.y * 0.5 - color.z * 0.5, color.x + color.z * 0.5, color.x - color.y * 0.5 - color.z * 0.5);
}

@fragment
fn temporal_fragment(input: FullscreenVertex) -> TemporalOutput {
    let size = vec2i(textureDimensions(colorImage, 0));
    let texel = 1.0 / vec2f(size);
    let uv = clamp(input.uv + temporal.parameters.xy, texel * 0.5, vec2f(1.0) - texel * 0.5);
    let center = clamp(vec2i(uv * vec2f(size)), vec2i(0), size - 1);
    var selected = center;
    var closest = 1.0;
    var low = vec3f(1e20);
    var high = vec3f(-1e20);
    for (var y = -1; y <= 1; y++) {
        for (var x = -1; x <= 1; x++) {
            let pixel = clamp(center + vec2i(x, y), vec2i(0), size - 1);
            let color = toYCoCg(textureLoad(colorImage, pixel, 0).rgb);
            low = min(low, color);
            high = max(high, color);
            let depth = textureLoad(depthImage, pixel, 0);
            if depth < closest {
                closest = depth;
                selected = pixel;
            }
        }
    }
    let motion = textureLoad(motionImage, selected, 0);
    let previousUV = input.uv + motion.xy;
    let currentDepth = textureLoad(depthImage, center, 0);
    let historySize = vec2i(textureDimensions(historyImage, 0));
    let historyPixel = clamp(vec2i(previousUV * vec2f(historySize)), vec2i(0), historySize - 1);
    let oldDepth = textureLoad(historyDepth, historyPixel, 0).r;
    let inside = all(previousUV > vec2f(0.0)) && all(previousUV < vec2f(1.0));
    let threshold = max(0.00015, abs(dpdx(currentDepth)) + abs(dpdy(currentDepth)));
    let valid = temporal.parameters.z < 0.5 && inside && motion.w > 0.5 && abs(oldDepth - motion.z) < threshold;
    let current = textureSampleLevel(colorImage, linearSampler, uv, 0.0).rgb;
    if !valid {
        return TemporalOutput(vec4f(current, 1.0), vec4f(current, 1.0), currentDepth);
    }
    let history = clamp(toYCoCg(textureSampleLevel(historyImage, linearSampler, previousUV, 0.0).rgb), low, high);
    let reactive = textureSampleLevel(reactiveImage, nearestSampler, uv, 0.0).r;
    let speed = length(motion.xy * vec2f(size));
    let weight = mix(0.92, 0.55, clamp(speed / 32.0, 0.0, 1.0)) * (1.0 - reactive);
    // Luminance compression limits the influence of bright emitters on history.
    let previous = max(toRGB(history), vec3f(0.0));
    let a = weight / (1.0 + max(max(previous.r, previous.g), previous.b));
    let b = (1.0 - weight) / (1.0 + max(max(current.r, current.g), current.b));
    let result = vec4f((previous * a + current * b) / max(a + b, 0.000001), 1.0);
    return TemporalOutput(result, result, currentDepth);
}
