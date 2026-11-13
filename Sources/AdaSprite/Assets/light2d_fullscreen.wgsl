struct LightVertex {
    @builtin(position) position: vec4f,
    @location(0) uv: vec2f,
}

fn fullscreenLightVertex(vertexIndex: u32) -> LightVertex {
    let uv = vec2f(f32(vertexIndex >> 1u), f32(vertexIndex & 1u)) * 2.0;
    return LightVertex(vec4f(uv * vec2f(2.0, -2.0) + vec2f(-1.0, 1.0), 0.0, 1.0), uv);
}
