import package::fullscreen::{FullscreenVertex, fullscreenVertex};

struct TemporalUniform {
    currentViewProjection: mat4x4f,
    previousViewProjection: mat4x4f,
    inverseJitteredProjection: mat4x4f,
    currentToPreviousView: mat4x4f,
    parameters: vec4f,
}

struct SkyMotion {
    @location(0) motion: vec4f,
    @location(1) reactive: vec4f,
}

@group(0) @binding(23) var<uniform> temporal: TemporalUniform;

@vertex
fn fullscreen_vertex(@builtin(vertex_index) index: u32) -> FullscreenVertex {
    return fullscreenVertex(index);
}

@fragment
fn sky_motion_fragment(input: FullscreenVertex) -> SkyMotion {
    let ndc = input.uv * vec2f(2.0, -2.0) + vec2f(-1.0, 1.0);
    let point = temporal.inverseJitteredProjection * vec4f(ndc, 1.0, 1.0);
    // W=0 removes camera translation from the sky projection.
    let direction = vec4f(point.xyz / point.w, 0.0);
    let current = temporal.currentViewProjection * direction;
    let previous = temporal.previousViewProjection * direction;
    let valid = current.w > 0.00001 && previous.w > 0.00001;
    var velocity = vec2f(0.0);
    if valid && temporal.parameters.z < 0.5 {
        velocity = (previous.xy / previous.w - current.xy / current.w) * vec2f(0.5, -0.5);
    }
    return SkyMotion(vec4f(velocity, 1.0, select(0.0, 1.0, valid)), vec4f(select(1.0, 0.0, valid)));
}
