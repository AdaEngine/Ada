#version 450 core
#pragma stage : vert
#include <AdaEngine/View.glsl>

layout(location = 0) in vec4 a_Position;
layout(location = 1) in vec4 a_Color;
layout(location = 2) in vec2 a_TexCoordinate;
layout(binding = 3) uniform TileMapModel { mat4 u_TileMapModel; };

struct VertexOut { vec4 Color; vec2 TexCoordinate; };
layout(location = 0) out VertexOut Output;

[[main]]
void tilemap_chunk_vertex() {
    Output.Color = a_Color;
    Output.TexCoordinate = a_TexCoordinate;
    gl_Position = u_ViewProjection * u_TileMapModel * a_Position;
}

#version 450 core
#pragma stage : frag
layout(location = 0) out vec4 color;
struct VertexOut { vec4 Color; vec2 TexCoordinate; };
layout(location = 0) in VertexOut Input;
layout(binding = 0) uniform texture2D u_Texture;
layout(binding = 1) uniform sampler u_Sampler;

[[main]]
void tilemap_chunk_fragment() {
    color = texture(sampler2D(u_Texture, u_Sampler), Input.TexCoordinate) * Input.Color;
    if (color.a == 0.0) { discard; }
}
