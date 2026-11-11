import ada_engine::view::projectPosition;

struct CircleVertex {
    @builtin(position) position: vec4f,
    @location(0) localPosition: vec2f,
    @location(1) thickness: f32,
    @location(2) fade: f32,
    @location(3) color: vec4f,
}

@vertex
fn circle_vertex(
    @location(0) position: vec3f,
    @location(1) localPosition: vec2f,
    @location(2) thickness: f32,
    @location(3) fade: f32,
    @location(4) color: vec4f,
) -> CircleVertex {
    return CircleVertex(projectPosition(vec4f(position, 1.0)), localPosition, thickness, fade, color);
}

@fragment
fn circle_fragment(input: CircleVertex) -> @location(0) vec4f {
    let distance = sqrt(dot(input.localPosition, input.localPosition));
    let innerEdge = 1.0 - input.thickness;
    if distance > 1.0 || distance < innerEdge - input.fade {
        discard;
    }
    let outerAlpha = 1.0 - smoothstep(1.0 - input.fade, 1.0, distance);
    let innerAlpha = smoothstep(innerEdge - input.fade, innerEdge, distance);
    return vec4f(input.color.rgb, input.color.a * (outerAlpha * innerAlpha));
}
