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
};

layout (binding = 0) uniform texture2D u_Depth;
layout (binding = 1) uniform sampler u_Sampler;
[[main]]
void temporal_depth_fragment() {
    gl_FragDepth = texture(sampler2D(u_Depth, u_Sampler), clamp(v_UV + u_Parameters.xy, vec2(0.0), vec2(1.0))).r;
}
