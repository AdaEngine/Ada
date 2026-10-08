#version 450 core
#pragma stage : vert

#include <AdaEngine/View.glsl>

layout (location = 0) in vec3 a_WorldPosition;
layout (location = 1) in vec2 a_LocalPosition;
layout (location = 2) in float a_Thickness;
layout (location = 3) in float a_Fade;
layout (location = 4) in vec4 a_Color;

struct VertexOutput {
    vec2 LocalPosition;
    float Thickness;
    float Fade;
    vec4 Color;
};

layout (location = 0) out VertexOutput Output;

[[main]]
void circle_vertex() {
    Output.LocalPosition = a_LocalPosition;
    Output.Thickness = a_Thickness;
    Output.Color = a_Color;
    Output.Fade = a_Fade;
    gl_Position = u_ViewProjection * vec4(a_WorldPosition, 1.0);
}

#version 450 core
#pragma stage : frag

layout(location = 0) out vec4 color;

struct VertexOutput {
    vec2 LocalPosition;
    float Thickness;
    float Fade;
    vec4 Color;
};

layout (location = 0) in VertexOutput Input;

[[main]]
void circle_fragment() {
    float fade = Input.Fade;
    float dist = sqrt(dot(Input.LocalPosition, Input.LocalPosition));
    if (dist > 1.0 || dist < 1.0 - Input.Thickness - fade)
        discard;

    float alpha = 1.0 - smoothstep(1.0f - fade, 1.0f, dist);
    alpha *= smoothstep(1.0 - Input.Thickness - fade, 1.0 - Input.Thickness, dist);
    color = Input.Color;
    color.a *= alpha;
}
