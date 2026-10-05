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

layout (location = 0) out vec4 o_Motion;
layout (location = 1) out vec4 o_Reactive;
[[main]]
void sky_motion_fragment() {
    vec4 point = u_InverseJitteredProjection * vec4(v_UV * vec2(2.0, -2.0) + vec2(-1.0, 1.0), 1.0, 1.0);
    vec4 direction = vec4(point.xyz / point.w, 0.0);
    vec4 current = u_CurrentViewProjection * direction;
    vec4 previous = u_PreviousViewProjection * direction;
    // These matrices are projection-only for sky, with camera translation removed by W=0.
    bool valid = current.w > 0.00001 && previous.w > 0.00001;
    o_Motion = vec4(valid && u_Parameters.z < 0.5 ? (previous.xy / previous.w - current.xy / current.w) * vec2(0.5, -0.5) : vec2(0.0), 0.0, 0.0);
    o_Reactive = vec4(valid ? 0.0 : 1.0);
}
