#version 450 core
#pragma stage : vert
#include <AdaEngine/View.glsl>
layout (location = 0) in vec2 a_Corner;
layout (location = 1) in vec4 i_Origin;
layout (location = 2) in vec4 i_AxisX;
layout (location = 3) in vec4 i_AxisY;
layout (location = 4) in vec4 i_Color;
layout (location = 5) in vec4 i_BottomUV;
layout (location = 6) in vec4 i_TopUV;
struct VertexOut { vec4 Color; vec2 TexCoordinate; };
layout (location = 0) out VertexOut Output;
[[main]]
void sprite_instanced_vertex() {
    Output.Color = i_Color;
    vec2 bottom = mix(i_BottomUV.xy, i_BottomUV.zw, a_Corner.x);
    vec2 top = mix(i_TopUV.xy, i_TopUV.zw, a_Corner.x);
    Output.TexCoordinate = mix(bottom, top, a_Corner.y);
    gl_Position = u_ViewProjection * (i_Origin + a_Corner.x * i_AxisX + a_Corner.y * i_AxisY);
}
#version 450 core
#pragma stage : frag
layout (location = 0) out vec4 color;
struct VertexOut { vec4 Color; vec2 TexCoordinate; };
layout (location = 0) in VertexOut Input;
layout (binding = 0) uniform texture2D u_Texture;
layout (binding = 1) uniform sampler u_Sampler;
[[main]]
void sprite_instanced_fragment() {
    color = texture(sampler2D(u_Texture, u_Sampler), Input.TexCoordinate) * Input.Color;
    if (color.a == 0.0) { discard; }
}
