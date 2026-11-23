// CORTAO temporal accumulation. The reference implementation leaves this stage to the application: its occlusion is
// noisy by design, and a different random seed every frame lets history average the noise away.
//
// The previous frame's accumulated occlusion is reprojected by the camera motion. History is rejected when the surface
// depth no longer matches (disocclusion, moving objects) and otherwise clamped to the current 3x3 neighbourhood so
// stale values cannot linger.
//
// The weight of the new frame is max(minimum blend, 1 / (history length + 1)), with the history length kept per pixel in a
// second target: a fresh or disoccluded pixel takes its first frames at full weight and converges in a handful of frames,
// then settles to the long exponential average. A fixed small weight would need seconds to clear the noise.
//
// Output 0: r = accumulated occlusion, gb = bent normal (octahedral, 0...1, when enabled), a = view depth of the pixel
// (the next frame's depth test). The bent normal is a view-space direction, so the history is rotated by the camera's
// rotation between the two frames before it is blended. Output 1: r = history length in frames (capped at 255).
import package::cortao_common::{cortaoOctDecode, cortaoOctEncode};
import package::fullscreen::{FullscreenVertex, fullscreenVertex};

struct TemporalUniform {
    // Previous view-projection * inverse(current view): current view space -> previous clip space.
    reprojection: mat4x4f,
    // Current view * inverse(previous view): previous view space -> current view space (directions use w = 0).
    viewRotation: mat4x4f,
    // blend weight of the new frame, history valid (0 or 1), relative depth tolerance, bent normal present (0 or 1)
    parameters: vec4f,
}

@group(0) @binding(0) var positionImage: texture_2d<f32>;
@group(0) @binding(1) var currentOcclusion: texture_2d<f32>;
@group(0) @binding(2) var historyImage: texture_2d<f32>;
@group(0) @binding(3) var nearestSampler: sampler;
@group(0) @binding(4) var<uniform> temporal: TemporalUniform;
@group(0) @binding(5) var historyAge: texture_2d<f32>;

struct TemporalOutput {
    @location(0) color: vec4f,
    @location(1) age: vec4f,
}

@vertex
fn cortao_temporal_vertex(@builtin(vertex_index) index: u32) -> FullscreenVertex {
    return fullscreenVertex(index);
}

@fragment
fn cortao_temporal_fragment(input: FullscreenVertex) -> TemporalOutput {
    let position = textureSampleLevel(positionImage, nearestSampler, input.uv, 0.0).xyz;
    let currentSample = textureSampleLevel(currentOcclusion, nearestSampler, input.uv, 0.0);
    let current = currentSample.r;
    if position.z <= 0.0 {
        return TemporalOutput(vec4f(1.0, currentSample.g, currentSample.b, 0.0), vec4f(0.0));
    }

    let texel = 1.0 / vec2f(textureDimensions(currentOcclusion, 0));
    var lowest = current;
    var highest = current;
    for (var y = -1; y <= 1; y++) {
        for (var x = -1; x <= 1; x++) {
            let neighbour = textureSampleLevel(currentOcclusion, nearestSampler, input.uv + vec2f(f32(x), f32(y)) * texel, 0.0).r;
            lowest = min(lowest, neighbour);
            highest = max(highest, neighbour);
        }
    }

    var result = current;
    var bent = currentSample.gb;
    var age = 0.0;
    let clip = temporal.reprojection * vec4f(position, 1.0);
    if temporal.parameters.y > 0.5 && clip.w > 0.0 {
        let previousUV = clip.xy / clip.w * vec2f(0.5, -0.5) + vec2f(0.5);
        if all(previousUV >= vec2f(0.0)) && all(previousUV <= vec2f(1.0)) {
            let history = textureSampleLevel(historyImage, nearestSampler, previousUV, 0.0);
            if abs(history.a - clip.w) < temporal.parameters.z * clip.w {
                age = textureSampleLevel(historyAge, nearestSampler, previousUV, 0.0).r;
                let blend = max(temporal.parameters.x, 1.0 / (age + 1.0));
                result = mix(clamp(history.r, lowest, highest), current, blend);
                if temporal.parameters.w > 0.5 {
                    let previous = (temporal.viewRotation * vec4f(cortaoOctDecode(history.gb * 2.0 - vec2f(1.0)), 0.0)).xyz;
                    let latest = cortaoOctDecode(currentSample.gb * 2.0 - vec2f(1.0));
                    // The direction comes from few random rays and shows as ripple under lighting, so it keeps more history.
                    let blended = mix(previous, latest, max(temporal.parameters.x * 0.5, 1.0 / (age + 1.0)));
                    if dot(blended, blended) > 0.0001 {
                        bent = cortaoOctEncode(normalize(blended)) * 0.5 + vec2f(0.5);
                    }
                }
            }
        }
    }
    return TemporalOutput(vec4f(result, bent, position.z), vec4f(min(age + 1.0, 255.0), 0.0, 0.0, 0.0));
}
