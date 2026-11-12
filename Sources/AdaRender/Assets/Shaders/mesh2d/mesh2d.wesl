import ada_engine::mesh2d::{Mesh2dVertexIn, Mesh2dVertexOut, mesh2dVertex};

// WESL port of mesh2d.glsl: the default canvas mesh material.

@vertex
fn mesh_vertex(input: Mesh2dVertexIn) -> Mesh2dVertexOut {
    return mesh2dVertex(input);
}

@fragment
fn mesh_fragment(input: Mesh2dVertexOut) -> @location(0) vec4f {
    var color = vec4f(1.0, 0.0, 1.0, 1.0);
    @if(VERTEX_COLORS) color = input.vertexColor;
    // To avoid depth write.
    @if(VERTEX_COLORS) if color.a == 0.0 { discard; }
    return color;
}
