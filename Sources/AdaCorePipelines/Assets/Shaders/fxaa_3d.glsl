#version 450 core
#pragma stage : vert
layout (location = 0) out vec2 v_UV;
[[main]]
void fxaa_vertex() {
    vec2 uv = vec2(float(gl_VertexIndex >> 1u), float(gl_VertexIndex & 1u)) * 2.0;
    gl_Position = vec4(uv * vec2(2.0, -2.0) + vec2(-1.0, 1.0), 0.0, 1.0);
    v_UV = uv;
}
#version 450 core
#pragma stage : frag
layout (location = 0) in vec2 v_UV;
layout (location = 0) out vec4 o_Color;
layout (binding = 0) uniform texture2D u_Color;
layout (binding = 1) uniform sampler u_Linear;
layout (binding = 2) uniform FXAA3DUniform { vec4 u_InverseSize; };
vec3 sampleColor(vec2 uv) { return texture(sampler2D(u_Color, u_Linear), uv).rgb; }
[[main]]
void fxaa_fragment() {
    vec2 pixel = u_InverseSize.xy;
    vec3 center = sampleColor(v_UV);
    vec3 nw = sampleColor(v_UV + vec2(-1.0, -1.0) * pixel);
    vec3 ne = sampleColor(v_UV + vec2(1.0, -1.0) * pixel);
    vec3 sw = sampleColor(v_UV + vec2(-1.0, 1.0) * pixel);
    vec3 se = sampleColor(v_UV + vec2(1.0, 1.0) * pixel);
    vec3 luma = vec3(0.299, 0.587, 0.114);
    float m = dot(center, luma), a = dot(nw, luma), b = dot(ne, luma), c = dot(sw, luma), d = dot(se, luma);
    float minimum = min(m, min(min(a, b), min(c, d)));
    float maximum = max(m, max(max(a, b), max(c, d)));
    if (maximum - minimum < max(0.0312, maximum * 0.125)) { o_Color = vec4(center, 1.0); return; }
    vec2 direction = vec2(-((a + b) - (c + d)), (a + c) - (b + d));
    float reduce = max((a + b + c + d) * 0.03125, 0.0078125);
    direction = clamp(direction / (min(abs(direction.x), abs(direction.y)) + reduce), vec2(-8.0), vec2(8.0)) * pixel;
    vec3 first = 0.5 * (sampleColor(v_UV + direction * (-1.0/6.0)) + sampleColor(v_UV + direction * (1.0/6.0)));
    vec3 second = first * 0.5 + 0.25 * (sampleColor(v_UV - direction * 0.5) + sampleColor(v_UV + direction * 0.5));
    float secondLuma = dot(second, luma);
    o_Color = vec4(secondLuma < minimum || secondLuma > maximum ? first : second, 1.0);
}
