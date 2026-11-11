import package::fullscreen::{FullscreenVertex, fullscreenVertex};

@vertex
fn fullscreen_vertex(@builtin(vertex_index) index: u32) -> FullscreenVertex {
    return fullscreenVertex(index);
}

struct TemporalUniform {
    currentViewProjection: mat4x4f,
    previousViewProjection: mat4x4f,
    inverseJitteredProjection: mat4x4f,
    currentToPreviousView: mat4x4f,
    parameters: vec4f,
}

@group(0) @binding(0) var depthImage: texture_depth_2d;
@group(0) @binding(23) var<uniform> temporal: TemporalUniform;

@fragment
fn temporal_depth_fragment(input: FullscreenVertex) -> @builtin(frag_depth) f32 {
    // Load the exact value from the unfilterable depth texture.
    let size = vec2i(textureDimensions(depthImage, 0));
    let pixel = clamp(vec2i((input.uv + temporal.parameters.xy) * vec2f(size)), vec2i(0), size - vec2i(1));
    return textureLoad(depthImage, pixel, 0);
}
