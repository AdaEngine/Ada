#version 450 core
#pragma stage : vert
layout (location = 0) out vec2 v_UV;
[[main]]
void auto_exposure_vertex() {
    vec2 uv = vec2(float(gl_VertexIndex >> 1u), float(gl_VertexIndex & 1u)) * 2.0;
    gl_Position = vec4(uv * vec2(2.0, -2.0) + vec2(-1.0, 1.0), 0.0, 1.0);
    v_UV = uv;
}
#version 450 core
#pragma stage : frag
layout (location = 0) in vec2 v_UV;
layout (location = 0) out vec4 o_Color;
layout (binding = 0) uniform texture2D u_Source;
layout (binding = 1) uniform texture2D u_Auxiliary; // normal and roughness (meter) or the previous state (adapt)
layout (binding = 2) uniform sampler u_Nearest;
layout (binding = 3) uniform sampler u_Linear;
layout (binding = 4) uniform AutoExposure3DUniform {
    vec4 u_Parameters; // x mode (0 meter, 1 downsample, 2 adapt), y delta time, z speed up, w speed down
    vec4 u_Limits;     // x minimum EV, y maximum EV, z reset (ignore the previous state)
};

const float METER_SIZE = 64.0;

// One meter texel averages a 4 x 4 grid of scene pixels: x holds the mean log2 luminance of metered pixels
// scaled by coverage, y the coverage. Pixels without geometry, and pixels with no light at all (a frame that has
// not been lit yet), carry no weight, so a black frame cannot drive exposure to an extreme.
vec4 meter() {
    vec2 origin = v_UV - vec2(0.5 / METER_SIZE);
    vec2 sum = vec2(0.0);
    for (int y = 0; y < 4; ++y) {
        for (int x = 0; x < 4; ++x) {
            vec2 uv = origin + (vec2(float(x), float(y)) + 0.5) / 4.0 / METER_SIZE;
            float covered = length(textureLod(sampler2D(u_Auxiliary, u_Nearest), uv, 0.0).xyz) > 0.1 ? 1.0 : 0.0;
            vec3 color = max(textureLod(sampler2D(u_Source, u_Nearest), uv, 0.0).rgb, vec3(0.0));
            float luminance = clamp(dot(color, vec3(0.2126, 0.7152, 0.0722)), 0.0, 65000.0);
            // Keep genuinely dim surfaces in the average. A hard 0.001 cut discarded dark rooms entirely
            // and made their meter coverage jump as lights crossed that threshold. Exact black still holds.
            float metered = luminance > 0.0 ? covered : 0.0;
            sum += vec2(log2(max(luminance, 0.000001)), 1.0) * metered;
        }
    }
    return vec4(sum / 16.0, 0.0, 1.0);
}

// Moves the stored exposure (in stops) toward the value that maps the metered average to mid gray.
vec4 adapt() {
    vec4 sums = textureLod(sampler2D(u_Source, u_Linear), vec2(0.5), 0.0);
    vec4 previous = textureLod(sampler2D(u_Auxiliary, u_Nearest), vec2(0.5), 0.0);
    float coverage = sums.y;
    bool valid = coverage > 0.0005;
    float averageLog = sums.x / max(coverage, 0.0005);
    float desired = clamp(log2(0.18) - averageLog, u_Limits.x, u_Limits.y);
    // Exposure starts neutral (0 EV, kept inside the limits) and always adapts at the configured speeds. The first
    // frames of a scene are often only partly lit, so snapping to their measurement would strand a slow
    // adaptation at an extreme.
    bool initialized = previous.w > 0.5 && u_Limits.z < 0.5;
    // Profiles may tighten the gain range while history is alive, including a paused (zero-speed) camera.
    float base = clamp(initialized ? previous.x + previous.y : 0.0, u_Limits.x, u_Limits.y);
    float ev = base;
    if (valid) {
        float speed = desired > base ? u_Parameters.z : u_Parameters.w;
        float blend = speed >= 1000000.0 ? 1.0 : 1.0 - exp(-u_Parameters.y * speed);
        ev = mix(base, desired, blend);
    }
    // A single half loses small temporal steps at high FPS (e.g. 5.8 EV with slow adaptation toward 6 EV).
    // Retain the rounding residual in a second half. These core packing operations require no f16 GPU feature.
    float high = unpackHalf2x16(packHalf2x16(vec2(ev, 0.0))).x;
    return vec4(high, ev - high, coverage, 1.0);
}

[[main]]
void auto_exposure_fragment() {
    if (u_Parameters.x < 0.5) {
        o_Color = meter();
    } else if (u_Parameters.x < 1.5) {
        o_Color = textureLod(sampler2D(u_Source, u_Linear), v_UV, 0.0);
    } else {
        o_Color = adapt();
    }
}
