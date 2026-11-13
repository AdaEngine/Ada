import package::fullscreen::{FullscreenVertex, fullscreenVertex};
import package::tonemapping::ditherDisplay;

struct CameraEffectsUniform {
    lens: vec4f,
    blur: vec4f,
    size: vec4f,
    rain: vec4f,
}

@group(0) @binding(0) var colorImage: texture_2d<f32>;
@group(0) @binding(1) var motionImage: texture_2d<f32>;
@group(0) @binding(2) var positionImage: texture_2d<f32>;
@group(0) @binding(3) var linearSampler: sampler;
@group(0) @binding(4) var nearestSampler: sampler;
@group(0) @binding(5) var<uniform> effects: CameraEffectsUniform;

@vertex
fn camera_effects_vertex(@builtin(vertex_index) index: u32) -> FullscreenVertex {
    return fullscreenVertex(index);
}

fn bounded(uv: vec2f) -> vec2f {
    return clamp(uv, effects.size.xy * 0.5, vec2f(1.0) - effects.size.xy * 0.5);
}

fn colorAt(uv: vec2f) -> vec3f {
    return textureSampleLevel(colorImage, linearSampler, bounded(uv), 0.0).rgb;
}

fn depthAt(uv: vec2f) -> f32 {
    let position = textureSampleLevel(positionImage, nearestSampler, bounded(uv), 0.0).xyz;
    return select(max(position.z, 0.001), 100000.0, length(position) < 0.0001);
}

fn motionBlur(uv: vec2f, center: vec3f) -> vec3f {
    if effects.blur.x <= 0.0 {
        return center;
    }
    var velocity = textureSampleLevel(motionImage, linearSampler, bounded(uv), 0.0).xy * effects.blur.x;
    let pixels = length(velocity / effects.size.xy);
    if pixels < 0.5 {
        return center;
    }
    velocity *= min(1.0, effects.blur.y / max(pixels, 0.001));
    let depth = depthAt(uv);
    var sum = center;
    var weights = 1.0;
    let count = i32(effects.blur.z);
    for (var i = 0; i < 16; i++) {
        if i >= count {
            break;
        }
        let t = (f32(i) + 0.5) / f32(count) - 0.5;
        let sampleUV = uv + velocity * t;
        // Reject samples from unrelated depth layers.
        let difference = abs(depthAt(sampleUV) - depth);
        let weight = (1.0 - abs(t)) * (1.0 - smoothstep(max(0.15, depth * 0.08), max(0.3, depth * 0.2), difference));
        sum += colorAt(sampleUV) * weight;
        weights += weight;
    }
    return sum / weights;
}

fn dropHash(p: vec2f) -> f32 {
    return fract(sin(dot(p, vec2f(127.1, 311.7))) * 43758.5453);
}

// Refraction samples the finished scene before overlays and UI.
fn rainOnLens(uv: vec2f, original: vec3f) -> vec3f {
    if effects.rain.x <= 0.0001 {
        return original;
    }
    let grid = vec2f(12.0 * effects.rain.z, 12.0);
    let at = uv * grid;
    let root = floor(at);
    var normal = vec2f(0.0);
    var bead = 0.0;
    var rim = 0.0;
    for (var y = -1; y <= 1; y++) {
        for (var x = -1; x <= 1; x++) {
            let cell = root + vec2f(f32(x), f32(y));
            let seed = dropHash(cell);
            if seed > effects.rain.x * 0.82 {
                continue;
            }
            let phase = fract(effects.rain.y * (0.15 + seed * 0.15) + dropHash(cell + 17.0));
            let center = cell + vec2f(0.2 + 0.6 * dropHash(cell + 7.0), 0.1 + phase * 0.85);
            let delta = at - center;
            let radius = 0.11 + 0.12 * dropHash(cell + 31.0);
            let r = length(delta / vec2f(1.0, 1.3));
            let life = smoothstep(0.0, 0.06, phase) * (1.0 - smoothstep(0.85, 1.0, phase));
            let mask = (1.0 - smoothstep(radius * 0.72, radius, r)) * life;
            normal += delta * mask / max(radius, 0.01);
            bead = max(bead, mask);
            rim += exp(-abs(r - radius * 0.8) * 100.0) * life;
        }
    }
    let refracted = colorAt(uv + normal / grid * 0.16);
    let water = refracted * (1.0 - 0.12 * bead) + vec3f(0.22, 0.25, 0.28) * min(rim, 1.0) * 0.4;
    return mix(original, water, clamp(bead + rim * 0.3, 0.0, 1.0));
}

@fragment
fn camera_effects_fragment(input: FullscreenVertex) -> @location(0) vec4f {
    if effects.blur.w > 0.5 {
        return vec4f(colorAt(input.uv), 1.0);
    }
    let p = input.uv * 2.0 - 1.0;
    let radius2 = dot(p, p);
    // Overscan keeps distorted corner samples inside the source.
    let uv = 0.5 + p * (1.0 + effects.lens.x * radius2) / (1.0 + 2.0 * effects.lens.x) * 0.5;
    let raw = colorAt(uv);
    var color = motionBlur(uv, raw);
    let edge = smoothstep(0.3, 1.8, radius2);
    if effects.lens.y > 0.0 && edge > 0.0 {
        let shift = p * effects.size.xy * effects.lens.y * edge;
        color.r += colorAt(uv + shift).r - raw.r;
        color.b += colorAt(uv - shift).b - raw.b;
    }
    if effects.lens.z > 0.0 && edge > 0.0 {
        let stepUV = effects.size.xy * effects.lens.z * edge;
        let horizontal = vec2f(stepUV.x, 0.0);
        let vertical = vec2f(0.0, stepUV.y);
        let soft = (colorAt(uv + horizontal) + colorAt(uv - horizontal) + colorAt(uv + vertical) + colorAt(uv - vertical)) * 0.25;
        color = mix(color, soft, edge * 0.65);
    }
    if effects.lens.w > 0.0 {
        let seed = dot(floor(input.position.xy), vec2f(12.9898, 78.233)) + effects.size.z * 1.618;
        let noise = fract(sin(seed) * 43758.5453) - 0.5;
        color += vec3f(noise * effects.lens.w);
    }
    color = rainOnLens(input.uv, color);
    return vec4f(ditherDisplay(color, input.position.xy), 1.0);
}
