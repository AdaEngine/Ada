import package::fullscreen::{FullscreenVertex, fullscreenVertex};
import package::tonemapping::{outputTransform, ditherDisplay};
import package::color_grading::applyLut;

struct TemporalUniform {
    currentViewProjection: mat4x4f,
    previousViewProjection: mat4x4f,
    inverseJitteredProjection: mat4x4f,
    currentToPreviousView: mat4x4f,
    parameters: vec4f,
    toneMapping: vec4f,
}

@group(0) @binding(0) var image: texture_2d<f32>;
@group(0) @binding(1) var imageSampler: sampler;
@group(0) @binding(2) var gradingLut: texture_2d<f32>;
@group(0) @binding(3) var gradingSampler: sampler;
@group(0) @binding(23) var<uniform> temporal: TemporalUniform;

@vertex
fn fullscreen_vertex(@builtin(vertex_index) index: u32) -> FullscreenVertex {
    return fullscreenVertex(index);
}

@fragment
fn temporal_tonemap_fragment(input: FullscreenVertex) -> @location(0) vec4f {
    let uv = input.uv + select(vec2f(0.0), temporal.parameters.xy, temporal.parameters.w > 0.5);
    let color = max(textureSample(image, imageSampler, uv).rgb, vec3f(0.0));
    let display = applyLut(gradingLut, gradingSampler, outputTransform(color, temporal.toneMapping.x), temporal.toneMapping.y);
    return vec4f(ditherDisplay(display, input.position.xy), 1.0);
}
