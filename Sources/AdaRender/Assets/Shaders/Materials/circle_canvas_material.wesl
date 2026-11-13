import ada_engine::mesh2d::{Mesh2dVertexIn, Mesh2dVertexOut, mesh2dVertex};

// WESL port of circle_canvas_material.glsl.

struct CircleCanvasMaterial {
    u_Fade: f32,
    u_Thickness: f32,
    u_Color: vec4f,
}

@group(0) @binding(0) var<uniform> material: CircleCanvasMaterial;

@vertex
fn mesh_vertex(input: Mesh2dVertexIn) -> Mesh2dVertexOut {
    return mesh2dVertex(input);
}

@fragment
fn circle_canvas_mesh_fragment(input: Mesh2dVertexOut) -> @location(0) vec4f {
    let fade = material.u_Fade;
    let thickness = material.u_Thickness;

    let uv = input.uv - vec2f(0.5);

    let dist = sqrt(dot(uv * 2.0, uv * 2.0)); // looks like we should pass local position)))
    if dist > 1.0 || dist < 1.0 - thickness - fade {
        discard;
    }

    var alpha = 1.0 - smoothstep(1.0 - fade, 1.0, dist);
    alpha = alpha * smoothstep(1.0 - thickness - fade, 1.0 - thickness, dist);
    return vec4f(material.u_Color.rgb, alpha);
}
