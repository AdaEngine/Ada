struct ViewUniform {
    projection: mat4x4f,
    viewProjection: mat4x4f,
    viewMatrix: mat4x4f,
}

@group(0) @binding(2) var<uniform> view: ViewUniform;

fn projectPosition(position: vec4f) -> vec4f {
    return view.viewProjection * position;
}
