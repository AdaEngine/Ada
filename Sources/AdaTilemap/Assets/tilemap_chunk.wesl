import ada_engine::view::view;

struct TileVertex {
    @builtin(position) position: vec4f,
    @location(0) color: vec4f,
    @location(1) uv: vec2f,
}

struct TileMapModel {
    transform: mat4x4f,
}

@group(0) @binding(0) var atlas: texture_2d<f32>;
@group(0) @binding(1) var atlasSampler: sampler;
@group(0) @binding(3) var<uniform> model: TileMapModel;

@vertex
fn tilemap_chunk_vertex(@location(0) position: vec4f, @location(1) color: vec4f, @location(2) uv: vec2f) -> TileVertex {
    return TileVertex(view.viewProjection * model.transform * position, color, uv);
}

@fragment
fn tilemap_chunk_fragment(input: TileVertex) -> @location(0) vec4f {
    let color = textureSample(atlas, atlasSampler, input.uv) * input.color;
    if color.a == 0.0 {
        discard;
    }
    return color;
}

