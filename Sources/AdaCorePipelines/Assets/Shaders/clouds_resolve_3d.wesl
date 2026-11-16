import package::fullscreen::{FullscreenVertex, fullscreenVertex};
import package::atmosphere_common::{atmosphere, linearSampler};

// Blends the fresh cloud sample with last frame's result, reprojected with the previous camera and clamped to the
// colors around the current texel so moving clouds do not leave trails. The result goes to the history texture and to
// a fixed display texture that the composite reads, so the composite never depends on which history texture is current.
struct CloudResolveUniform {
    previousViewProjection: mat4x4f,
    // x: history weight, y: 1 when the history must be ignored, z: base altitude, w: thickness.
    parameters: vec4f,
}

struct ResolveOutput {
    @location(0) history: vec4f,
    @location(1) display: vec4f,
}

@group(0) @binding(5) var<uniform> resolve: CloudResolveUniform;
@group(0) @binding(6) var currentImage: texture_2d<f32>;
@group(0) @binding(7) var historyImage: texture_2d<f32>;

@vertex
fn clouds_resolve_vertex(@builtin(vertex_index) index: u32) -> FullscreenVertex {
    return fullscreenVertex(index);
}

fn both(value: vec4f) -> ResolveOutput {
    return ResolveOutput(value, value);
}

@fragment
fn clouds_resolve_fragment(input: FullscreenVertex) -> ResolveOutput {
    let size = vec2i(textureDimensions(currentImage, 0));
    let pixel = vec2i(input.position.xy);
    let current = textureLoad(currentImage, pixel, 0);
    if resolve.parameters.y > 0.5 {
        return both(current);
    }
    var lowest = current;
    var highest = current;
    for (var y = -1; y <= 1; y++) {
        for (var x = -1; x <= 1; x++) {
            let neighbour = textureLoad(currentImage, clamp(pixel + vec2i(x, y), vec2i(0), size - 1), 0);
            lowest = min(lowest, neighbour);
            highest = max(highest, neighbour);
        }
    }
    // Reproject a point in the middle of the cloud layer with the previous camera.
    let ground = atmosphere.planet.x;
    let ndc = vec2f(input.uv.x * 2.0 - 1.0, 1.0 - input.uv.y * 2.0);
    let viewFar = atmosphere.inverseProjection * vec4f(ndc, 1.0, 1.0);
    let viewRay = normalize(viewFar.xyz / viewFar.w);
    let direction = normalize((atmosphere.inverseView * vec4f(viewRay, 0.0)).xyz);
    let cameraWorld = atmosphere.inverseView[3].xyz;
    let planetCenter = vec3f(0.0, -ground, 0.0);
    let relative = cameraWorld - planetCenter;
    let middle = ground + resolve.parameters.z + resolve.parameters.w * 0.5;
    let b = dot(relative, direction);
    let c = dot(relative, relative) - middle * middle;
    let discriminant = b * b - c;
    if discriminant < 0.0 {
        return both(current);
    }
    // Below or inside the middle sphere the ray leaves through its far side; above it the ray enters through the near side.
    let root = sqrt(discriminant);
    let distance = max(select(-b + root, -b - root, c > 0.0), 0.0);
    let world = cameraWorld + direction * min(distance, 60000.0);
    let previous = resolve.previousViewProjection * vec4f(world, 1.0);
    if previous.w <= 0.0 {
        return both(current);
    }
    let previousNDC = previous.xy / previous.w;
    let previousUV = vec2f(previousNDC.x * 0.5 + 0.5, 0.5 - previousNDC.y * 0.5);
    if previousUV.x < 0.0 || previousUV.x > 1.0 || previousUV.y < 0.0 || previousUV.y > 1.0 {
        return both(current);
    }
    let history = clamp(textureSampleLevel(historyImage, linearSampler, previousUV, 0.0), lowest, highest);
    return both(mix(current, history, resolve.parameters.x));
}
