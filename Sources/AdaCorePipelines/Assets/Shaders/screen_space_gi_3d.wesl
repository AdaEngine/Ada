import package::fullscreen::{FullscreenVertex, fullscreenVertex};

struct ScreenSpaceGI3DUniform {
    projection: mat4x4f,
    trace: vec4f,
    quality: vec4f,
}
@group(0) @binding(0) var positionImage: texture_2d<f32>;
@group(0) @binding(1) var normalImage: texture_2d<f32>;
@group(0) @binding(2) var colorImage: texture_2d<f32>;
@group(0) @binding(3) var surfaceImage: texture_2d<f32>;
@group(0) @binding(4) var<uniform> gi: ScreenSpaceGI3DUniform;
@group(0) @binding(5) var indirectImage: texture_2d<f32>;
@group(0) @binding(6) var rawImage: texture_2d<f32>;
@group(0) @binding(7) var nearestSampler: sampler;
const PI = 3.14159265359;

@vertex
fn fullscreen_vertex(@builtin(vertex_index) index: u32) -> FullscreenVertex {
    return fullscreenVertex(index);
}

fn positionAt(uv: vec2f) -> vec3f { return textureSampleLevel(positionImage, nearestSampler, uv, 0.0).xyz; }
fn normalAt(uv: vec2f) -> vec3f { return textureSampleLevel(normalImage, nearestSampler, uv, 0.0).xyz; }

// Replaces GLSL's out parameter without discarding the projection validity bit.
struct Projection {
    uv: vec2f,
    valid: bool,
}
fn project(position: vec3f) -> Projection {
    let clip = gi.projection * vec4f(position, 1.0);
    if clip.w <= 0.00001 { return Projection(vec2f(0.0), false); }
    let uv = clip.xy / clip.w * vec2f(0.5, -0.5) + 0.5;
    return Projection(uv, all(uv > vec2f(0.001)) && all(uv < vec2f(0.999)));
}

fn traceRay(origin: vec3f, direction: vec3f, receiver: vec3f) -> vec3f {
    var previousDistance = gi.trace.z;
    for (var step = 1; step <= 32; step++) {
        if step > i32(gi.trace.w) { break; }
        let fraction = f32(step) / gi.trace.w;
        let distance = gi.trace.z + fraction * fraction * gi.trace.x;
        let point = origin + direction * distance;
        let projected = project(point);
        if !projected.valid { break; }
        var uv = projected.uv;
        var surface = positionAt(uv);
        if length(surface) < 0.0001 { previousDistance = distance; continue; }
        let difference = point.z - surface.z;
        if difference >= 0.0 && difference < gi.trace.y + distance - previousDistance {
            // Refine the first crossing rather than shining through a wall.
            var low = previousDistance;
            var high = distance;
            for (var iteration = 0; iteration < 4; iteration++) {
                let middle = (low + high) * 0.5;
                let query = origin + direction * middle;
                let candidate = project(query);
                if !candidate.valid { break; }
                let visible = positionAt(candidate.uv);
                if length(visible) > 0.0001 && query.z >= visible.z { high = middle; uv = candidate.uv; }
                else { low = middle; }
            }
            surface = positionAt(uv);
            if length(surface - receiver) < gi.trace.z * 2.0 { return vec3f(0.0); }
            let hitNormal = normalAt(uv);
            if length(hitNormal) < 0.1 || dot(normalize(hitNormal), -direction) <= 0.0 { return vec3f(0.0); }
            // Only rebounce direct light and emission, not the baked ambient.
            let lit = textureSampleLevel(colorImage, nearestSampler, uv, 0.0).rgb;
            let indirect = textureSampleLevel(indirectImage, nearestSampler, uv, 0.0).rgb;
            return clamp(lit - indirect, vec3f(0.0), vec3f(gi.quality.z));
        }
        previousDistance = distance;
    }
    return vec3f(0.0);
}

@fragment
fn screen_space_gi_fragment(input: FullscreenVertex) -> @location(0) vec4f {
    let point = positionAt(input.uv);
    var normal = normalAt(input.uv);
    if length(point) < 0.0001 || length(normal) < 0.1 { return vec4f(0.0); }
    normal = normalize(normal);
    let surface = textureSampleLevel(surfaceImage, nearestSampler, input.uv, 0.0).rgb;
    if gi.quality.w > 0.5 {
        let size = vec2f(textureDimensions(rawImage, 0));
        var sum = vec3f(0.0);
        var weights = 0.0;
        for (var y = -1; y <= 1; y++) {
            for (var x = -1; x <= 1; x++) {
                let uv = clamp(input.uv + vec2f(f32(x), f32(y)) / size, vec2f(0.0), vec2f(1.0));
                let otherNormal = normalAt(uv);
                let otherPosition = positionAt(uv);
                if length(otherNormal) < 0.1 { continue; }
                let otherSurface = textureSampleLevel(surfaceImage, nearestSampler, uv, 0.0).rgb;
                let weight = pow(max(dot(normal, normalize(otherNormal)), 0.0), 16.0)
                    * exp(-abs(point.z - otherPosition.z) / max(0.04, gi.trace.z * 4.0))
                    * exp(-length(surface - otherSurface) * 8.0);
                sum += textureSampleLevel(rawImage, nearestSampler, uv, 0.0).rgb * weight;
                weights += weight;
            }
        }
        return vec4f(sum / max(weights, 0.00001), 1.0);
    }
    let tangent = normalize(select(cross(normal, vec3f(0, 1, 0)), cross(normal, vec3f(0, 0, 1)), abs(normal.z) < 0.9));
    let bitangent = cross(normal, tangent);
    // Stable fixed-pixel rotation; camera jitter is accumulated by TAA/DLSS.
    let rotation = fract(sin(dot(floor(input.uv * vec2f(textureDimensions(positionImage, 0))), vec2f(12.9898, 78.233))) * 43758.5453);
    var irradiance = vec3f(0.0);
    for (var ray = 0; ray < 16; ray++) {
        if ray >= i32(gi.quality.x) { break; }
        let u = (f32(ray) + 0.5) / gi.quality.x;
        let phi = 2.0 * PI * fract(f32(ray) * 0.61803398875 + rotation);
        let direction = tangent * (sqrt(u) * cos(phi)) + bitangent * (sqrt(u) * sin(phi)) + normal * sqrt(1.0 - u);
        irradiance += traceRay(point + normal * gi.trace.z, direction, point);
    }
    // Cosine-weighted hemisphere sampling cancels Lambert's pi.
    return vec4f(surface * irradiance * (gi.quality.y / gi.quality.x), 1.0);
}
