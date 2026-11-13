struct FullscreenVertex {
    @builtin(position) position: vec4f,
    @location(0) uv: vec2f,
}

fn fullscreenVertex(index: u32) -> FullscreenVertex {
    let uv = vec2f(f32(index >> 1u), f32(index & 1u)) * 2.0;
    let position = vec4f(uv * vec2f(2.0, -2.0) + vec2f(-1.0, 1.0), 0.0, 1.0);
    return FullscreenVertex(position, uv);
}
