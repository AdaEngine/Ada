// Portable GLSL effect body. Coordinates, size, radius and width are in logical pixels.
// Returns PREMULTIPLIED RGBA; blend with ONE, ONE_MINUS_SRC_ALPHA.
// accent is an RGB color in [0, 1]. No secondary color is hard-coded.
// time is seconds already multiplied by playback speed. activity is [0, 1].
// Freeze time for reduced motion; the host controls completion lifetime and fading.
// Host resolves status to accent; hueSpread = 0.012 keeps semantic colors recognizable.

vec3 agentRGBToHSV(vec3 c) {
    vec4 k = vec4(0.0, -1.0 / 3.0, 2.0 / 3.0, -1.0);
    vec4 p = mix(vec4(c.bg, k.wz), vec4(c.gb, k.xy), step(c.b, c.g));
    vec4 q = mix(vec4(p.xyw, c.r), vec4(c.r, p.yzx), step(p.x, c.r));
    float d = q.x - min(q.w, q.y);
    return vec3(abs(q.z + (q.w - q.y) / (6.0 * d + 0.00001)),
                d / (q.x + 0.00001), q.x);
}

vec3 agentHSVToRGB(vec3 c) {
    vec3 p = abs(fract(c.xxx + vec3(0.0, 2.0 / 3.0, 1.0 / 3.0)) * 6.0 - 3.0);
    return c.z * mix(vec3(1.0), clamp(p - 1.0, 0.0, 1.0), c.y);
}

float agentRoundedBox(vec2 p, vec2 halfSize, float radius) {
    vec2 q = abs(p) - halfSize + radius;
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - radius;
}

vec4 agentActivityGlow(vec2 position, vec2 size, float time, vec3 accent,
                       float activity, float intensity, float width, float radius, float hueSpread) {
    vec2 halfSize = max(size * 0.5, vec2(1.0));
    vec2 p = position - halfSize;
    float corner = clamp(radius, 0.0, min(halfSize.x, halfSize.y));
    float sdf = agentRoundedBox(p, halfSize - 1.0, corner);
    float inside = 1.0 - smoothstep(-0.65, 0.65, sdf);
    float distanceToEdge = max(-sdf, 0.0);
    vec2 direction = p / halfSize;
    // All angular frequencies are integers, so the atan seam remains continuous.
    float angle = length(direction) < 0.0001 ? 0.0 : atan(direction.y, direction.x);
    float phase = angle - time * 0.38;
    float wave = 0.5 + 0.5 * sin(phase * 3.0 + 0.8 * sin(angle * 2.0 + time * 0.31));
    float swell = pow(0.5 + 0.5 * sin(phase * 2.0 - 0.65), 2.0);
    float band = max(width, 1.0) * (0.38 + 0.62 * wave);
    float halo = exp(-distanceToEdge / band) * (0.15 + 0.26 * swell);
    // A broad, blurred crest rather than a sharp second outline.
    float crestDistance = distanceToEdge - band * (0.24 + 0.30 * swell);
    float crest = exp(-pow(crestDistance / (band * 0.48 + 1.0), 2.0));
    crest *= (0.06 + 0.13 * swell) * exp(-distanceToEdge / (band * 1.8));
    float rim = exp(-distanceToEdge / 1.15) * (0.28 + 0.56 * swell);
    float nearRim = exp(-distanceToEdge / 5.0) * (0.07 + 0.13 * wave);
    // The center is strictly transparent, even for oversized width settings.
    float edgeMask = 1.0 - smoothstep(min(width * 1.9, min(halfSize.x, halfSize.y) * 0.45),
                                    min(width * 3.0, min(halfSize.x, halfSize.y) * 0.8), distanceToEdge);
    vec3 hsv = agentRGBToHSV(clamp(accent, 0.0, 1.0));
    float shift = hueSpread * sin(phase + 0.7 * sin(angle * 2.0 + time * 0.2));
    vec3 tint = agentHSVToRGB(vec3(fract(hsv.x + shift), hsv.y, hsv.z));
    vec3 color = mix(tint, vec3(1.0), clamp(rim * 0.50, 0.0, 0.45));
    float alpha = clamp((halo + crest + rim + nearRim) * intensity, 0.0, 0.94);
    alpha *= inside * edgeMask * clamp(activity, 0.0, 1.0);
    return vec4(color * alpha, alpha);
}

// Original sample call remains available for the working state.
vec4 agentActivityGlow(vec2 position, vec2 size, float time, vec3 accent,
                       float activity, float intensity, float width, float radius) {
    return agentActivityGlow(position, size, time, accent, activity, intensity, width, radius, 0.065);
}
