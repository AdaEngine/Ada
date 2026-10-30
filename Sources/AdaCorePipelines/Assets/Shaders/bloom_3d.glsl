#version 450 core
#pragma stage : vert
layout (location = 0) out vec2 v_UV;
[[main]]
void bloom_vertex() {
    vec2 uv = vec2(float(gl_VertexIndex >> 1u), float(gl_VertexIndex & 1u)) * 2.0;
    gl_Position = vec4(uv * vec2(2.0, -2.0) + vec2(-1.0, 1.0), 0.0, 1.0);
    v_UV = uv;
}
#version 450 core
#pragma stage : frag
layout (location = 0) in vec2 v_UV;
layout (location = 0) out vec4 o_Color;
layout (binding = 0) uniform texture2D u_Source;
layout (binding = 1) uniform sampler u_Sampler;
layout (binding = 2) uniform texture2D u_Exposure;
layout (binding = 4) uniform Bloom3DUniform {
    vec4 u_Parameters; // x mode (0 prefilter + downsample, 1 downsample, 2 upsample), y threshold, z knee, w scatter
    vec4 u_Texel;      // xy source texel size, z manual exposure scale, w 1 when automatic exposure is bound
};

vec3 fetch(vec2 uv) {
    return texture(sampler2D(u_Source, u_Sampler), uv).rgb;
}

// Manual exposure, times the adapted automatic exposure when that texture is bound.
float exposureScale() {
    float scale = u_Texel.z;
    if (u_Texel.w > 0.5) {
        vec2 state = textureLod(sampler2D(u_Exposure, u_Sampler), vec2(0.5), 0.0).rg;
        scale *= exp2(state.x + state.y);
    }
    return scale;
}

// Soft-knee threshold on exposed luminance. Clamping first keeps a single overbright texel from flooding the chain.
vec3 prefilter(vec3 color, float scale) {
    color = clamp(color * scale, vec3(0.0), vec3(65000.0));
    float brightness = max(color.r, max(color.g, color.b));
    float knee = max(u_Parameters.z, 0.0001);
    float soft = clamp(brightness - u_Parameters.y + knee, 0.0, 2.0 * knee);
    soft = soft * soft / (4.0 * knee + 0.0001);
    float contribution = max(soft, brightness - u_Parameters.y) / max(brightness, 0.0001);
    return color * contribution;
}

[[main]]
void bloom_fragment() {
    vec2 texel = u_Texel.xy;
    vec3 result;
    if (u_Parameters.x < 0.5) {
        float scale = exposureScale();
        result = prefilter(fetch(v_UV), scale) * 4.0
            + prefilter(fetch(v_UV + vec2(-texel.x, -texel.y)), scale)
            + prefilter(fetch(v_UV + vec2(texel.x, -texel.y)), scale)
            + prefilter(fetch(v_UV + vec2(-texel.x, texel.y)), scale)
            + prefilter(fetch(v_UV + vec2(texel.x, texel.y)), scale);
        result /= 8.0;
    } else if (u_Parameters.x < 1.5) {
        result = fetch(v_UV) * 4.0
            + fetch(v_UV + vec2(-texel.x, -texel.y))
            + fetch(v_UV + vec2(texel.x, -texel.y))
            + fetch(v_UV + vec2(-texel.x, texel.y))
            + fetch(v_UV + vec2(texel.x, texel.y));
        result /= 8.0;
    } else {
        result = fetch(v_UV + vec2(-texel.x * 2.0, 0.0))
            + fetch(v_UV + vec2(-texel.x, texel.y)) * 2.0
            + fetch(v_UV + vec2(0.0, texel.y * 2.0))
            + fetch(v_UV + vec2(texel.x, texel.y)) * 2.0
            + fetch(v_UV + vec2(texel.x * 2.0, 0.0))
            + fetch(v_UV + vec2(texel.x, -texel.y)) * 2.0
            + fetch(v_UV + vec2(0.0, -texel.y * 2.0))
            + fetch(v_UV + vec2(-texel.x, -texel.y)) * 2.0;
        result = result / 12.0 * u_Parameters.w;
    }
    o_Color = vec4(result, 1.0);
}
