import ada_engine::view::projectPosition;

struct QuadVertex {
    @builtin(position) position: vec4f,
    @location(0) color: vec4f,
    @location(1) uv: vec2f,
}

@group(0) @binding(0) var image: texture_2d<f32>;
@group(0) @binding(1) var imageSampler: sampler;

@vertex
fn quad_vertex(@location(0) position: vec4f, @location(1) color: vec4f, @location(2) uv: vec2f) -> QuadVertex {
    return QuadVertex(projectPosition(position), color, uv);
}

@fragment
fn quad_fragment(input: QuadVertex) -> @location(0) vec4f {
    let color = textureSample(image, imageSampler, input.uv) * input.color;
    // Discard transparent fragments so they cannot write depth.
    if color.a == 0.0 {
        discard;
    }
    return color;
}
