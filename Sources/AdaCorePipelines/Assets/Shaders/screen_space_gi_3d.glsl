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
layout (location = 0) out vec4 o_Color;
layout (binding = 0) uniform texture2D u_Position;
layout (binding = 1) uniform texture2D u_Normal;
layout (binding = 2) uniform texture2D u_Color;
layout (binding = 3) uniform texture2D u_Surface;
layout (binding = 5) uniform texture2D u_Indirect;
layout (binding = 6) uniform texture2D u_Raw;
layout (binding = 7) uniform sampler u_Nearest;
layout (binding = 4) uniform ScreenSpaceGI3DUniform {
    mat4 u_Projection;
    vec4 u_Trace; // maximum distance, thickness, normal bias, step count
    vec4 u_Quality; // ray count, intensity, radiance clamp, filter pass
};
const float PI = 3.14159265359;
vec3 positionAt(vec2 uv) { return textureLod(sampler2D(u_Position, u_Nearest), uv, 0.0).xyz; }
vec3 normalAt(vec2 uv) { return textureLod(sampler2D(u_Normal, u_Nearest), uv, 0.0).xyz; }
bool project(vec3 position, out vec2 uv) {
    vec4 clip = u_Projection * vec4(position, 1.0);
    if (clip.w <= 0.00001) { return false; }
    uv = clip.xy / clip.w * vec2(0.5, -0.5) + 0.5;
    return all(greaterThan(uv, vec2(0.001))) && all(lessThan(uv, vec2(0.999)));
}
vec3 traceRay(vec3 origin, vec3 direction, vec3 receiver) {
    float previousDistance = u_Trace.z;
    for (int step = 1; step <= 32; ++step) {
        if (step > int(u_Trace.w)) { break; }
        float fraction = float(step) / u_Trace.w;
        float distance = u_Trace.z + fraction * fraction * u_Trace.x;
        vec3 point = origin + direction * distance;
        vec2 uv;
        if (!project(point, uv)) { break; }
        vec3 surface = positionAt(uv);
        if (length(surface) < 0.0001) { previousDistance = distance; continue; }
        float difference = point.z - surface.z;
        if (difference >= 0.0 && difference < u_Trace.y + distance - previousDistance) {
            // Refine the first crossing rather than letting a coarse step shine through a wall.
            float low = previousDistance, high = distance;
            for (int iteration = 0; iteration < 4; ++iteration) {
                float middle = (low + high) * 0.5;
                vec3 query = origin + direction * middle;
                vec2 candidate;
                if (!project(query, candidate)) { break; }
                vec3 visible = positionAt(candidate);
                if (length(visible) > 0.0001 && query.z >= visible.z) { high = middle; uv = candidate; }
                else { low = middle; }
            }
            surface = positionAt(uv);
            if (length(surface-receiver) < u_Trace.z * 2.0) { return vec3(0.0); }
            vec3 hitNormal = normalAt(uv);
            if (length(hitNormal) < 0.1 || dot(normalize(hitNormal), -direction) <= 0.0) { return vec3(0.0); }
            // Baked ambient is already present: only rebounce direct light and emission.
            vec3 lit = textureLod(sampler2D(u_Color, u_Nearest), uv, 0.0).rgb;
            vec3 indirect = textureLod(sampler2D(u_Indirect, u_Nearest), uv, 0.0).rgb;
            return clamp(lit-indirect, vec3(0.0), vec3(u_Quality.z));
        }
        previousDistance = distance;
    }
    return vec3(0.0);
}
[[main]]
void screen_space_gi_fragment() {
    vec3 point = positionAt(v_UV), normal = normalAt(v_UV);
    if (length(point) < 0.0001 || length(normal) < 0.1) { o_Color = vec4(0.0); return; }
    normal = normalize(normal);
    vec3 surface = textureLod(sampler2D(u_Surface, u_Nearest), v_UV, 0.0).rgb;
    if (u_Quality.w > 0.5) {
        vec2 size = vec2(textureSize(sampler2D(u_Raw, u_Nearest), 0));
        vec3 sum = vec3(0.0); float weights = 0.0;
        for (int y = -1; y <= 1; ++y) for (int x = -1; x <= 1; ++x) {
            vec2 uv = clamp(v_UV + vec2(x,y) / size, vec2(0.0), vec2(1.0));
            vec3 otherNormal = normalAt(uv), otherPosition = positionAt(uv);
            if (length(otherNormal) < 0.1) { continue; }
            vec3 otherSurface = textureLod(sampler2D(u_Surface, u_Nearest), uv, 0.0).rgb;
            float weight = pow(max(dot(normal, normalize(otherNormal)), 0.0), 16.0)
                * exp(-abs(point.z-otherPosition.z) / max(0.04, u_Trace.z*4.0))
                * exp(-length(surface-otherSurface)*8.0);
            sum += textureLod(sampler2D(u_Raw, u_Nearest), uv, 0.0).rgb * weight;
            weights += weight;
        }
        o_Color = vec4(sum / max(weights, 0.00001), 1.0);
        return;
    }
    vec3 tangent = normalize(abs(normal.z) < 0.9 ? cross(normal, vec3(0,0,1)) : cross(normal, vec3(0,1,0)));
    vec3 bitangent = cross(normal, tangent);
    // Fixed pixel rotation is stable without a temporal resolver; TAA/DLSS can accumulate camera jitter.
    float rotation = fract(sin(dot(floor(v_UV * vec2(textureSize(sampler2D(u_Position,u_Nearest),0))),vec2(12.9898,78.233)))*43758.5453);
    vec3 irradiance = vec3(0.0);
    for (int ray = 0; ray < 16; ++ray) {
        if (ray >= int(u_Quality.x)) { break; }
        float u = (float(ray)+0.5) / u_Quality.x;
        float phi = 2.0 * PI * fract(float(ray)*0.61803398875 + rotation);
        vec3 direction = tangent*(sqrt(u)*cos(phi)) + bitangent*(sqrt(u)*sin(phi)) + normal*sqrt(1.0-u);
        irradiance += traceRay(point + normal*u_Trace.z, direction, point);
    }
    // Cosine-weighted hemisphere sampling cancels Lambert's pi.
    o_Color = vec4(surface * irradiance * (u_Quality.y / u_Quality.x), 1.0);
}
