import package::fullscreen::fullscreenVertex;

@vertex
fn shadow_clear_vertex(@builtin(vertex_index) index: u32) -> @builtin(position) vec4f {
    return fullscreenVertex(index).position;
}

@fragment
fn shadow_clear_fragment() -> @location(0) vec4f {
    return vec4f(1.0);
}
