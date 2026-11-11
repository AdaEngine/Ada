// Shared ABI of the global and bounded/local volumetric passes.
struct VolumetricFog3DUniform {
    inverseView: mat4x4f,
    inverseProjection: mat4x4f,
    shadowViewProjection0: mat4x4f,
    shadowViewProjection1: mat4x4f,
    shadowViewProjection2: mat4x4f,
    cascadeSplits: vec4f,
    shadowAtlas: vec4f,
    sunDirection: vec4f,
    sunRadiance: vec4f,
    medium: vec4f,
    march: vec4f,
}

@group(0) @binding(0) var positionImage: texture_2d<f32>;
@group(0) @binding(1) var directionalShadowImage: texture_2d<f32>;
@group(0) @binding(2) var nearestSampler: sampler;
@group(0) @binding(4) var<uniform> fog: VolumetricFog3DUniform;

const PI = 3.14159265359;

fn henyeyGreenstein(cosine: f32, g: f32) -> f32 {
    let denominator = 1.0 + g * g - 2.0 * g * cosine;
    return (1.0 - g * g) / (4.0 * PI * pow(max(denominator, 0.0001), 1.5));
}

fn cascadeIndex(viewDepth: f32) -> i32 {
    let candidate = select(select(2, 1, viewDepth <= fog.cascadeSplits.y), 0, viewDepth <= fog.cascadeSplits.x);
    return min(candidate, i32(fog.cascadeSplits.w) - 1);
}

fn cascadeTransform(cascade: i32) -> mat4x4f {
    if cascade == 0 { return fog.shadowViewProjection0; }
    if cascade == 1 { return fog.shadowViewProjection1; }
    return fog.shadowViewProjection2;
}

fn shadowDepth(localUV: vec2f, cascade: i32) -> f32 {
    let count = max(fog.cascadeSplits.w, 1.0);
    let uv = vec2f((localUV.x + f32(cascade)) / count, localUV.y);
    let minimum = vec2f(f32(cascade) / count, 0.0) + fog.shadowAtlas.xy * 0.5;
    let maximum = vec2f(f32(cascade + 1) / count, 1.0) - fog.shadowAtlas.xy * 0.5;
    return textureSampleLevel(directionalShadowImage, nearestSampler, clamp(uv, minimum, maximum), 0.0).r;
}

fn outsideShadow(projected: vec3f, localUV: vec2f) -> bool {
    return projected.z < 0.0 || projected.z > 1.0 || any(localUV < vec2f(0.0)) || any(localUV > vec2f(1.0));
}

fn sunVisibility(world: vec3f, viewDepth: f32) -> f32 {
    if fog.shadowAtlas.w < 0.5 || viewDepth > fog.cascadeSplits.z { return 1.0; }
    let cascade = cascadeIndex(viewDepth);
    let position = cascadeTransform(cascade) * vec4f(world, 1.0);
    let projected = position.xyz / position.w;
    let localUV = projected.xy * vec2f(0.5, -0.5) + 0.5;
    if outsideShadow(projected, localUV) { return 1.0; }
    let stored = shadowDepth(localUV, cascade);
    return select(0.0, 1.0, projected.z - fog.shadowAtlas.z <= stored);
}

// Signed world-depth separation, including orthographic depth-row scaling.
fn sunShadowGap(world: vec3f, viewDepth: f32) -> f32 {
    if fog.shadowAtlas.w < 0.5 || viewDepth > fog.cascadeSplits.z { return 10000.0; }
    let cascade = cascadeIndex(viewDepth);
    let transform = cascadeTransform(cascade);
    let position = transform * vec4f(world, 1.0);
    let projected = position.xyz / position.w;
    let localUV = projected.xy * vec2f(0.5, -0.5) + 0.5;
    if outsideShadow(projected, localUV) { return 10000.0; }
    let stored = shadowDepth(localUV, cascade);
    let depthRow = vec3f(transform[0][2], transform[1][2], transform[2][2]);
    return (stored + fog.shadowAtlas.z - projected.z) / max(length(depthRow), 0.00000001);
}
