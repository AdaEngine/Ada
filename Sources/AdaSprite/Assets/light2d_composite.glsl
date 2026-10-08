#version 450 core
#pragma stage : vert

layout (location = 0) out vec2 v_UV;

[[main]]
void light2d_composite_vert() {
    uint vi = gl_VertexIndex;
    vec2 uv = vec2(float(vi >> 1u), float(vi & 1u)) * 2.0;
    gl_Position = vec4(uv * vec2(2.0, -2.0) + vec2(-1.0, 1.0), 0.0, 1.0);
    v_UV = uv;
}

#version 450 core
#pragma stage : frag

layout (location = 0) in vec2 v_UV;
layout (location = 0) out vec4 o_Color;

layout (binding = 0) uniform texture2D u_Albedo;
layout (binding = 1) uniform texture2D u_LightAccum;
layout (binding = 2) uniform sampler u_Sampler;

layout (binding = 3) uniform Light2DCompositeData {
    vec4 u_Modulate;
};

[[main]]
void light2d_composite_frag() {
    vec4 albedo = texture(sampler2D(u_Albedo, u_Sampler), v_UV);
    vec3 addLight = texture(sampler2D(u_LightAccum, u_Sampler), v_UV).rgb;
    vec3 lit = albedo.rgb * u_Modulate.rgb + albedo.rgb * addLight;
    o_Color = vec4(lit, albedo.a);
}
