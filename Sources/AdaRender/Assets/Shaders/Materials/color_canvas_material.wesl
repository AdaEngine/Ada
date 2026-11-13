import ada_engine::mesh2d::{Mesh2dVertexIn, Mesh2dVertexOut, mesh2dVertex};

// WESL port of color_canvas_material.glsl.

struct ColorCanvasMaterial {
    u_Color: vec4f,
}

@group(0) @binding(0) var<uniform> material: ColorCanvasMaterial;

@vertex
fn mesh_vertex(input: Mesh2dVertexIn) -> Mesh2dVertexOut {
    return mesh2dVertex(input);
}

@fragment
fn color_canvas_mesh_fragment(input: Mesh2dVertexOut) -> @location(0) vec4f {
    return material.u_Color;
}
