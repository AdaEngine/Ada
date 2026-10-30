#version 450 core
#pragma stage : vert
layout (location = 0) out vec2 v_UV;
[[main]]
void fullscreen_vertex() {
    vec2 uv = vec2(float(gl_VertexIndex >> 1u), float(gl_VertexIndex & 1u)) * 2.0;
    gl_Position = vec4(uv * vec2(2.0, -2.0) + vec2(-1.0, 1.0), 0.0, 1.0);
    v_UV = uv;
}
#version 450 core
#pragma stage : frag
layout (location = 0) in vec2 v_UV;
layout (binding = 23) uniform Temporal3DUniform {
    mat4 u_CurrentViewProjection; mat4 u_PreviousViewProjection; mat4 u_InverseJitteredProjection;
    mat4 u_CurrentToPreviousView; vec4 u_Parameters;
    vec4 u_ToneMapping; // x tone mapper (see Tonemapping.glsl), y LUT intensity
};

layout (binding = 2) uniform texture2D u_GradingLUT;
layout (binding = 3) uniform sampler u_GradingSampler;
#include <AdaEngine/Tonemapping.glsl>
#include <AdaEngine/ColorGrading.glsl>

layout (binding = 0) uniform texture2D u_Color;
layout (binding = 1) uniform sampler u_Sampler;
layout (location = 0) out vec4 o_Color;
[[main]]
void temporal_tonemap_fragment() {
    vec2 uv = v_UV + (u_Parameters.w > 0.5 ? u_Parameters.xy : vec2(0.0));
    vec3 color = max(texture(sampler2D(u_Color, u_Sampler), uv).rgb, vec3(0.0));
    vec3 display = adaApplyLut(adaOutputTransform(color, u_ToneMapping.x), u_ToneMapping.y);
    o_Color = vec4(adaDitherDisplay(display, gl_FragCoord.xy), 1.0);
}
