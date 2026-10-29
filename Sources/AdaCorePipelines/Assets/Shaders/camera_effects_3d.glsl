#version 450 core
#pragma stage : vert
layout (location = 0) out vec2 v_UV;
[[main]]
void camera_effects_vertex() {
    vec2 uv = vec2(float(gl_VertexIndex >> 1u), float(gl_VertexIndex & 1u)) * 2.0;
    gl_Position = vec4(uv * vec2(2.0, -2.0) + vec2(-1.0, 1.0), 0.0, 1.0);
    v_UV = uv;
}
#version 450 core
#pragma stage : frag
layout (location = 0) in vec2 v_UV;
layout (location = 0) out vec4 o_Color;
layout (binding = 0) uniform texture2D u_Color;
layout (binding = 1) uniform texture2D u_Motion;
layout (binding = 2) uniform texture2D u_Position;
layout (binding = 3) uniform sampler u_Linear;
layout (binding = 4) uniform sampler u_Nearest;
layout (binding = 5) uniform CameraEffects3DUniform {
    vec4 u_Lens;   // distortion, corner chromatic shift (px), corner softness (px), monochromatic grain
    vec4 u_Blur;   // shutter fraction (0 disables), maximum trail (px), sample count, copy mode
    vec4 u_Size;   // reciprocal output width/height, frame seed, unused
    vec4 u_Rain;   // lens wetness, pause-safe seconds, aspect ratio, reserved
};

vec2 bounded(vec2 uv) { return clamp(uv, u_Size.xy * 0.5, vec2(1.0) - u_Size.xy * 0.5); }
vec3 colorAt(vec2 uv) { return textureLod(sampler2D(u_Color, u_Linear), bounded(uv), 0.0).rgb; }
float depthAt(vec2 uv) {
    vec3 position = textureLod(sampler2D(u_Position, u_Nearest), bounded(uv), 0.0).xyz;
    return length(position) < 0.0001 ? 100000.0 : max(position.z, 0.001);
}

vec3 motionBlur(vec2 uv, vec3 center) {
    if (u_Blur.x <= 0.0) { return center; }
    vec2 velocity = textureLod(sampler2D(u_Motion, u_Linear), bounded(uv), 0.0).xy * u_Blur.x;
    float pixels = length(velocity / u_Size.xy);
    if (pixels < 0.5) { return center; }
    velocity *= min(1.0, u_Blur.y / max(pixels, 0.001));
    float depth = depthAt(uv);
    vec3 sum = center;
    float weights = 1.0;
    int count = int(u_Blur.z);
    for (int i = 0; i < 16; ++i) {
        if (i >= count) { break; }
        float t = (float(i) + 0.5) / float(count) - 0.5;
        vec2 at = uv + velocity * t;
        // Reject unrelated depth layers instead of bleeding the background over a nearby weapon.
        float difference = abs(depthAt(at) - depth);
        float weight = (1.0 - abs(t)) * (1.0 - smoothstep(max(0.15, depth * 0.08), max(0.3, depth * 0.2), difference));
        sum += colorAt(at) * weight;
        weights += weight;
    }
    return sum / weights;
}

float dropHash(vec2 p) { return fract(sin(dot(p,vec2(127.1,311.7))) * 43758.5453); }

// Finite neighbor search: persistent beads, fresh splashes and slow downward trails.
// Refraction samples the finished scene; overlays and UI are drawn afterwards.
vec3 rainOnLens(vec2 uv, vec3 original) {
    if (u_Rain.x <= 0.0001) { return original; }
    vec2 grid = vec2(12.0 * u_Rain.z,12.0);
    vec2 at = uv * grid;
    vec2 root = floor(at);
    vec2 normal = vec2(0.0);
    float bead = 0.0;
    float rim = 0.0;
    for (int y = -1; y <= 1; ++y) {
        for (int x = -1; x <= 1; ++x) {
            vec2 cell = root + vec2(float(x),float(y));
            float seed = dropHash(cell);
            if (seed > u_Rain.x * 0.82) { continue; }
            float phase = fract(u_Rain.y * (0.15 + seed*0.15) + dropHash(cell+17.0));
            vec2 center = cell + vec2(0.2+0.6*dropHash(cell+7.0),0.1+phase*0.85);
            vec2 d = at-center;
            float radius = 0.11+0.12*dropHash(cell+31.0);
            float r = length(d/vec2(1.0,1.3));
            float life = smoothstep(0.0,0.06,phase)*(1.0-smoothstep(0.85,1.0,phase));
            float mask = (1.0-smoothstep(radius*0.72,radius,r))*life;
            normal += d * mask / max(radius,0.01);
            bead = max(bead, mask);
            rim += exp(-abs(r-radius*0.8)*100.0) * life;
        }
    }
    vec3 refracted = colorAt(uv+normal/grid*0.16);
    vec3 water = refracted*(1.0-0.12*bead)+vec3(0.22,0.25,0.28)*min(rim,1.0)*0.4;
    return mix(original,water,clamp(bead+rim*0.3,0.0,1.0));
}

[[main]]
void camera_effects_fragment() {
    if (u_Blur.w > 0.5) {
        o_Color = vec4(colorAt(v_UV), 1.0);
        return;
    }
    vec2 p = v_UV * 2.0 - 1.0;
    float radius2 = dot(p, p);
    // Overscan keeps all samples inside the source image, including the four distorted corners.
    vec2 uv = 0.5 + p * (1.0 + u_Lens.x * radius2) / (1.0 + 2.0 * u_Lens.x) * 0.5;
    vec3 raw = colorAt(uv);
    vec3 color = motionBlur(uv, raw);
    float edge = smoothstep(0.3, 1.8, radius2);
    if (u_Lens.y > 0.0 && edge > 0.0) {
        vec2 shift = p * u_Size.xy * u_Lens.y * edge;
        color.r += colorAt(uv + shift).r - raw.r;
        color.b += colorAt(uv - shift).b - raw.b;
    }
    if (u_Lens.z > 0.0 && edge > 0.0) {
        vec2 stepUV = u_Size.xy * u_Lens.z * edge;
        vec3 soft = (colorAt(uv + vec2(stepUV.x,0.0)) + colorAt(uv - vec2(stepUV.x,0.0))
                   + colorAt(uv + vec2(0.0,stepUV.y)) + colorAt(uv - vec2(0.0,stepUV.y))) * 0.25;
        color = mix(color, soft, edge * 0.65);
    }
    if (u_Lens.w > 0.0) {
        float noise = fract(sin(dot(floor(gl_FragCoord.xy), vec2(12.9898,78.233)) + u_Size.z * 1.618) * 43758.5453) - 0.5;
        color += vec3(noise * u_Lens.w);
    }
    color = rainOnLens(v_UV, color);
    o_Color = vec4(clamp(color, 0.0, 1.0), 1.0);
}
