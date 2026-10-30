// Requires u_DirectionalShadowTexture and its nearest sampler. Filter comparison results,
// never depths: interpolating depths invents surfaces between unrelated occluders.
// Reconstruct a 3x3 PCF kernel continuously across texels with 4x4 weighted comparisons.
float adaDirectionalShadowPCF(vec2 uv, vec2 texelSize, vec2 minimum, vec2 maximum, float receiverDepth) {
    vec2 texelPosition = uv / texelSize - 0.5;
    vec2 base = floor(texelPosition);
    vec2 fraction = fract(texelPosition);
    float visibility = 0.0;
    for (int y = -1; y <= 2; ++y) {
        float wy = y == -1 ? 1.0 - fraction.y : (y == 2 ? fraction.y : 1.0);
        for (int x = -1; x <= 2; ++x) {
            float wx = x == -1 ? 1.0 - fraction.x : (x == 2 ? fraction.x : 1.0);
            // Keep every comparison inside this cascade, including its filter footprint.
            vec2 sampleUV = clamp((base + vec2(float(x), float(y)) + 0.5) * texelSize, minimum, maximum);
            float storedDepth = texture(sampler2D(u_DirectionalShadowTexture, u_DirectionalShadowSampler), sampleUV).r;
            visibility += wx * wy * (receiverDepth <= storedDepth ? 1.0 : 0.0);
        }
    }
    return visibility / 9.0;
}

// Bounded PCSS: search for blockers, then grow the comparison footprint with
// receiver/blocker separation. Clamp every tap to its own cascade atlas tile.
float adaDirectionalShadowPCSS(vec2 uv, vec2 texel, vec2 minimum, vec2 maximum,
    float receiverDepth, mat4 shadowMatrix, vec4 settings, float cascadeCount) {
    float blockers = 0.0, depthSum = 0.0;
    for (int i = 0; i < 16; ++i) {
        float angle = float(i) * 2.39996323;
        vec2 disk = vec2(cos(angle), sin(angle)) * sqrt((float(i) + 0.5) / 16.0);
        vec2 sampleUV = clamp(uv + disk * texel * settings.w, minimum, maximum);
        float depth = texture(sampler2D(u_DirectionalShadowTexture, u_DirectionalShadowSampler), sampleUV).r;
        if (depth < receiverDepth) { blockers += 1.0; depthSum += depth; }
    }
    if (blockers < 0.5) { return 1.0; }
    vec3 depthRow = vec3(shadowMatrix[0].z, shadowMatrix[1].z, shadowMatrix[2].z);
    float separation = max(receiverDepth - depthSum / blockers, 0.0) / max(length(depthRow), 0.000001);
    vec2 worldToUV = 0.5 * vec2(length(vec3(shadowMatrix[0].x,shadowMatrix[1].x,shadowMatrix[2].x)) / cascadeCount,
        length(vec3(shadowMatrix[0].y,shadowMatrix[1].y,shadowMatrix[2].y)));
    vec2 radius = clamp(separation * settings.y * worldToUV, texel, texel * settings.z);
    float visibility = 0.0;
    for (int i = 0; i < 24; ++i) {
        float angle = float(i) * 2.39996323;
        vec2 disk = vec2(cos(angle), sin(angle)) * sqrt((float(i) + 0.5) / 24.0);
        float depth = texture(sampler2D(u_DirectionalShadowTexture, u_DirectionalShadowSampler), clamp(uv + disk * radius, minimum, maximum)).r;
        visibility += receiverDepth <= depth ? 1.0 : 0.0;
    }
    return visibility / 24.0;
}
