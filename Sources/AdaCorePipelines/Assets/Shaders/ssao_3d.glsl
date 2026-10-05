#version 450 core
#pragma stage : vert
layout (location = 0) out vec2 v_UV;
[[main]]
void ssao_vertex() {
    vec2 uv = vec2(float(gl_VertexIndex >> 1u), float(gl_VertexIndex & 1u)) * 2.0;
    gl_Position = vec4(uv * vec2(2.0, -2.0) + vec2(-1.0, 1.0), 0.0, 1.0);
    v_UV = uv;
}
#version 450 core
#pragma stage : frag
layout (location = 0) in vec2 v_UV;
layout (location = 0) out vec4 o_Color;
layout (binding = 0) uniform texture2D u_Position;
layout (binding = 1) uniform texture2D u_Normal;
layout (binding = 2) uniform texture2D u_RawAO;
layout (binding = 3) uniform sampler u_Nearest;
layout (binding = 4) uniform SSAO3DUniform {
    mat4 u_Projection;
    vec4 u_Parameters; // world radius, intensity, bias, sample count
    vec4 u_Pass; // 0 raw / 1 bilateral
};
[[main]]
void ssao_fragment() {
    vec3 position = texture(sampler2D(u_Position, u_Nearest), v_UV).xyz;
    vec3 normal = texture(sampler2D(u_Normal, u_Nearest), v_UV).xyz;
    if (length(normal) < 0.1 || position.z <= 0.0) { o_Color = vec4(1.0); return; }
    normal = normalize(normal);
    if (u_Pass.x > 0.5) {
        vec2 pixel = 1.0 / vec2(textureSize(sampler2D(u_RawAO, u_Nearest), 0));
        float sum = 0.0;
        float weightSum = 0.0;
        for (int y = -2; y <= 2; ++y) {
            for (int x = -2; x <= 2; ++x) {
                vec2 uv = clamp(v_UV + vec2(float(x), float(y)) * pixel, pixel * 0.5, vec2(1.0) - pixel * 0.5);
                vec3 other = texture(sampler2D(u_Position, u_Nearest), uv).xyz;
                vec3 otherNormal = texture(sampler2D(u_Normal, u_Nearest), uv).xyz;
                if (other.z <= 0.0 || length(otherNormal) < 0.1) { continue; }
                float weight = exp(-float(x*x + y*y) / 4.0) * exp(-abs(position.z - other.z) / max(0.02, u_Parameters.x * 0.1));
                weight *= pow(max(dot(normal, normalize(otherNormal)), 0.0), 8.0);
                sum += texture(sampler2D(u_RawAO, u_Nearest), uv).r * weight;
                weightSum += weight;
            }
        }
        float ao = weightSum > 0.0001 ? sum / weightSum : 1.0;
        o_Color = vec4(vec3(ao), 1.0); return;
    }
    vec3 helper = abs(normal.y) < 0.95 ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0);
    vec3 tangent = normalize(cross(helper, normal));
    vec3 bitangent = cross(normal, tangent);
    vec2 cell = mod(floor(gl_FragCoord.xy), 4.0);
    float rotation = fract(sin(dot(cell, vec2(12.9898, 78.233))) * 43758.5453) * 6.2831853;
    float occlusion = 0.0;
    for (int index = 0; index < 32; ++index) {
        if (index >= int(u_Parameters.w)) { break; }
        float fraction = (float(index) + 0.5) / u_Parameters.w;
        float radial = sqrt(fraction);
        float angle = float(index) * 2.3999632 + rotation;
        vec3 direction = tangent * cos(angle) * radial + bitangent * sin(angle) * radial + normal * sqrt(1.0 - fraction);
        vec3 samplePoint = position + direction * u_Parameters.x * mix(0.2, 1.0, fraction * fraction);
        vec4 clip = u_Projection * vec4(samplePoint, 1.0);
        if (clip.w <= 0.0) { continue; }
        vec2 uv = clip.xy / clip.w * vec2(0.5, -0.5) + 0.5;
        if (any(lessThan(uv, vec2(0.0))) || any(greaterThan(uv, vec2(1.0)))) { continue; }
        vec3 surface = texture(sampler2D(u_Position, u_Nearest), uv).xyz;
        if (surface.z <= 0.0 || distance(surface, position) > u_Parameters.x) { continue; }
        float range = smoothstep(0.0, 1.0, u_Parameters.x / max(abs(position.z - surface.z), 0.001));
        occlusion += surface.z < samplePoint.z - u_Parameters.z ? range : 0.0;
    }
    float ao = clamp(1.0 - occlusion / u_Parameters.w * u_Parameters.y, 0.1, 1.0);
    o_Color = vec4(vec3(ao), 1.0);
}
