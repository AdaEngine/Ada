// WESL port of Public/ShadowPCF.glsl. Filter comparison results, never depths.
// The shadow atlas and its nearest sampler are parameters instead of includer globals.

// 3x3 PCF reconstructed continuously across texels with 4x4 weighted comparisons.
fn adaDirectionalShadowPCF(
    shadowTexture: texture_2d<f32>, shadowSampler: sampler,
    uv: vec2f, texelSize: vec2f, minimum: vec2f, maximum: vec2f, receiverDepth: f32
) -> f32 {
    let texelPosition = uv / texelSize - vec2f(0.5);
    let base = floor(texelPosition);
    let fraction = fract(texelPosition);
    var visibility = 0.0;
    for (var y = -1; y <= 2; y++) {
        let wy = select(select(1.0, fraction.y, y == 2), 1.0 - fraction.y, y == -1);
        for (var x = -1; x <= 2; x++) {
            let wx = select(select(1.0, fraction.x, x == 2), 1.0 - fraction.x, x == -1);
            let sampleUV = clamp((base + vec2f(f32(x), f32(y)) + vec2f(0.5)) * texelSize, minimum, maximum);
            let storedDepth = textureSampleLevel(shadowTexture, shadowSampler, sampleUV, 0.0).r;
            visibility += wx * wy * select(0.0, 1.0, receiverDepth <= storedDepth);
        }
    }
    return visibility / 9.0;
}

// Bounded PCSS: blocker search, then a footprint that grows with receiver/blocker separation.
fn adaDirectionalShadowPCSS(
    shadowTexture: texture_2d<f32>, shadowSampler: sampler,
    uv: vec2f, texel: vec2f, minimum: vec2f, maximum: vec2f,
    receiverDepth: f32, shadowMatrix: mat4x4f, settings: vec4f, cascadeCount: f32
) -> f32 {
    var blockers = 0.0;
    var depthSum = 0.0;
    for (var i = 0; i < 16; i++) {
        let angle = f32(i) * 2.39996323;
        let disk = vec2f(cos(angle), sin(angle)) * sqrt((f32(i) + 0.5) / 16.0);
        let sampleUV = clamp(uv + disk * texel * settings.w, minimum, maximum);
        let depth = textureSampleLevel(shadowTexture, shadowSampler, sampleUV, 0.0).r;
        if depth < receiverDepth {
            blockers += 1.0;
            depthSum += depth;
        }
    }
    if blockers < 0.5 {
        return 1.0;
    }
    let depthRow = vec3f(shadowMatrix[0].z, shadowMatrix[1].z, shadowMatrix[2].z);
    let separation = max(receiverDepth - depthSum / blockers, 0.0) / max(length(depthRow), 0.000001);
    let worldToUV = 0.5 * vec2f(
        length(vec3f(shadowMatrix[0].x, shadowMatrix[1].x, shadowMatrix[2].x)) / cascadeCount,
        length(vec3f(shadowMatrix[0].y, shadowMatrix[1].y, shadowMatrix[2].y))
    );
    let radius = clamp(separation * settings.y * worldToUV, texel, texel * settings.z);
    var visibility = 0.0;
    for (var i = 0; i < 24; i++) {
        let angle = f32(i) * 2.39996323;
        let disk = vec2f(cos(angle), sin(angle)) * sqrt((f32(i) + 0.5) / 24.0);
        let depth = textureSampleLevel(shadowTexture, shadowSampler, clamp(uv + disk * radius, minimum, maximum), 0.0).r;
        visibility += select(0.0, 1.0, receiverDepth <= depth);
    }
    return visibility / 24.0;
}
