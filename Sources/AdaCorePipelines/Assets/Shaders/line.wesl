import ada_engine::view::projectPosition;

struct LineVertex {
    @builtin(position) position: vec4f,
    @location(0) color: vec4f,
}

@vertex
fn line_vertex(@location(0) position: vec3f, @location(1) color: vec4f) -> LineVertex {
    return LineVertex(projectPosition(vec4f(position, 1.0)), color);
}

@fragment
fn line_fragment(input: LineVertex) -> @location(0) vec4f {
    return input.color;
}
