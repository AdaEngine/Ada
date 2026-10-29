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
