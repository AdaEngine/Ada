import package::fullscreen::{FullscreenVertex, fullscreenVertex};

@vertex
fn fullscreen_vertex(@builtin(vertex_index) index: u32) -> FullscreenVertex {
    return fullscreenVertex(index);
}

@group(0) @binding(0) var image: texture_2d<f32>;
@group(0) @binding(1) var imageSampler: sampler;

@fragment
fn fullscreen_fragment(input: FullscreenVertex) -> @location(0) vec4f {
    return textureSample(image, imageSampler, input.uv);
}
