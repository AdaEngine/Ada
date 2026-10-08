#version 450 core
#pragma stage : vert

layout (location = 0) out vec2 v_UV;

[[main]]
void light2d_point_vert() {
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
layout (binding = 2) uniform texture2D u_Cookie;
layout (binding = 3) uniform sampler u_CookieSampler;

layout (binding = 4) uniform PointLightUBO {
    mat4 u_InvViewProjection;
    vec4 u_LightXY_Radius;
    vec4 u_LightRGB_Energy;
    vec4 u_Flags;
};

[[main]]
void light2d_point_frag() {
    vec2 ndc = v_UV * vec2(2.0, -2.0) + vec2(-1.0, 1.0);
    vec4 world4 = u_InvViewProjection * vec4(ndc, 0.0, 1.0);
    vec2 world = world4.xy / max(world4.w, 1e-5);
    vec2 lp = u_LightXY_Radius.xy;
    float radius = max(u_LightXY_Radius.z, 1e-3);
    float d = distance(world, lp);
    float atten = 1.0 - smoothstep(0.0, radius, d);
    vec3 rgb = u_LightRGB_Energy.rgb * u_LightRGB_Energy.a * atten;
    if (u_Flags.x > 0.5) {
        float m = texture(sampler2D(u_ShadowMask, u_ShadowSampler), v_UV).r;
        rgb *= m;
    }
    if (u_Flags.y > 0.5) {
        vec3 cookie = texture(sampler2D(u_Cookie, u_CookieSampler), v_UV).rgb;
        rgb *= cookie;
    }
    o_Color = vec4(rgb, 1.0);
}
