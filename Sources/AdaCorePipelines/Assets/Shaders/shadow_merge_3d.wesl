import package::fullscreen::fullscreenVertex;

@group(0) @binding(0) var staticDepth: texture_2d<f32>;
@group(0) @binding(1) var movingDepth: texture_2d<f32>;

@vertex
fn shadow_merge_vertex(@builtin(vertex_index) index: u32) -> @builtin(position) vec4f {
    return fullscreenVertex(index).position;
}

@fragment
fn shadow_merge_fragment(@builtin(position) position: vec4f) -> @location(0) vec4f {
    let texel = vec2i(position.xy);
    return vec4f(min(textureLoad(staticDepth, texel, 0).r, textureLoad(movingDepth, texel, 0).r));
}
