#version 450 core
#pragma stage : vert

#include <AdaEngine/View.glsl>
#include "mesh2d_uniform.glsl"
#include "mesh2d_functions.glsl"

#ifdef VERTEX_POSITIONS
layout (location = 0) in vec3 a_Position;
#endif

#ifdef VERTEX_NORMALS
layout (location = 1) in vec3 a_Normal;
#endif

#ifdef VERTEX_UVS
layout (location = 2) in vec2 a_UV;
#endif

#ifdef VERTEX_COLORS
layout (location = 3) in vec4 a_VertexColor;
#endif

struct VertexOut
{
#ifdef VERTEX_POSITIONS
    vec4 WorldPosition;
#endif
#ifdef VERTEX_NORMALS
    vec3 WorldNormal;
#endif
#ifdef VERTEX_UVS
    vec2 UV;
#endif
#ifdef VERTEX_COLORS
    vec4 VertexColor;
#endif
};

layout (location = 0) out VertexOut Output;

[[main]]
void mesh_vertex()
{
#ifdef VERTEX_POSITIONS
    Output.WorldPosition = Mesh2dPositionLocalToWorld(u_MeshModel, vec4(a_Position, 1.0));
#endif
    
#ifdef VERTEX_NORMALS
    Output.WorldNormal = Mesh2dNormalLocalToWorld(a_Normal);
#endif
    
#ifdef VERTEX_UVS
    Output.UV = a_UV;
#endif
    
#ifdef VERTEX_COLORS
    Output.VertexColor = a_VertexColor;
#endif
    
    gl_Position = u_ViewProjection * Output.WorldPosition;
}

#version 450 core
#pragma stage : frag

#include "mesh2d_vertex_output.glsl"

[[main]]
void mesh_fragment()
{
#ifdef VERTEX_COLORS
    COLOR = Input.VertexColor;
    
    // to avoid depth write
    if (COLOR.a == 0.0) {
        discard;
    }
#else
    COLOR = vec4(1.0, 0.0, 1.0, 1.0);
#endif
}
