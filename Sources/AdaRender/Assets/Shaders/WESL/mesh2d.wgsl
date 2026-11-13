import package::view::view;

// Shared 2D mesh vertex stage. Vertex layout selects attributes through the VERTEX_* features,
// matching the defines the canvas materials pass for the mesh's vertex descriptor.

struct Mesh2dUniform {
    u_MeshModel: mat4x4f,
    u_MeshInverseTransposeModel: mat4x4f,
}

@group(0) @binding(3) var<uniform> mesh2d: Mesh2dUniform;

struct Mesh2dVertexIn {
    @builtin(vertex_index) vertexIndex: u32,
    @if(VERTEX_POSITIONS) @location(0) position: vec3f,
    @if(VERTEX_NORMALS) @location(1) normal: vec3f,
    @if(VERTEX_UVS) @location(2) uv: vec2f,
    @if(VERTEX_COLORS) @location(3) vertexColor: vec4f,
}

struct Mesh2dVertexOut {
    @builtin(position) position: vec4f,
    @location(0) worldPosition: vec4f,
    @location(1) worldNormal: vec3f,
    @location(2) uv: vec2f,
    @location(3) vertexColor: vec4f,
}

fn mesh2dVertex(input: Mesh2dVertexIn) -> Mesh2dVertexOut {
    var worldPosition = vec4f(0.0);
    var worldNormal = vec3f(0.0);
    var uv = vec2f(0.0);
    var vertexColor = vec4f(0.0);
    let normalTransform = mesh2d.u_MeshInverseTransposeModel;
    let normalMatrix = mat3x3f(normalTransform[0].xyz, normalTransform[1].xyz, normalTransform[2].xyz);
    @if(VERTEX_POSITIONS) worldPosition = mesh2d.u_MeshModel * vec4f(input.position, 1.0);
    @if(VERTEX_NORMALS) worldNormal = normalMatrix * input.normal;
    @if(VERTEX_UVS) uv = input.uv;
    @if(VERTEX_COLORS) vertexColor = input.vertexColor;
    return Mesh2dVertexOut(view.viewProjection * worldPosition, worldPosition, worldNormal, uv, vertexColor);
}
