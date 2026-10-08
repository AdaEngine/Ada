#version 450 core
#pragma stage : vert

layout (location = 0) out vec2 v_UV;

[[main]]
void light2d_directional_vert() {
    uint vi = gl_VertexIndex;
    vec2 uv = vec2(float(vi >> 1u), float(vi & 1u)) * 2.0;
    gl_Position = vec4(uv * vec2(2.0, -2.0) + vec2(-1.0, 1.0), 0.0, 1.0);
    v_UV = uv;
}

#version 450 core
#pragma stage : frag

layout (location = 0) in vec2 v_UV;
layout (location = 0) out vec4 o_Color;

layout (binding = 0) uniform texture2D u_ShadowMask;
layout (binding = 1) uniform sampler u_ShadowSampler;

layout (binding = 2) uniform DirectionalLightData {
    vec4 u_LightRGB_Energy;
    vec4 u_Flags;
};

[[main]]
void light2d_directional_frag() {
    vec3 rgb = u_LightRGB_Energy.rgb * u_LightRGB_Energy.a;
    if (u_Flags.x > 0.5) {
        float m = texture(sampler2D(u_ShadowMask, u_ShadowSampler), v_UV).r;
        rgb *= m;
    }
    o_Color = vec4(rgb, 1.0);
}
