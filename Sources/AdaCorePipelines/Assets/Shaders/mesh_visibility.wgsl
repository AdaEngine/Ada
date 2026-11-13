struct SurfaceUniform {
    emissiveFactor: vec4f,
    surfaceProperties: vec4f,
    surfaceFlags: vec4f,
    uvSets: vec4f,
    emission: vec4f,
    parallax: vec4f,
    textureTransforms: array<vec4f, 10>,
    dielectric: vec4f,
}

@group(0) @binding(4) var baseColorImage: texture_2d<f32>;
@group(0) @binding(7) var baseColorSampler: sampler;
@group(0) @binding(15) var<uniform> surface: SurfaceUniform;

fn meshOrientation(model: mat4x4f) -> f32 {
    let basis = mat3x3f(model[0].xyz, model[1].xyz, model[2].xyz);
    return select(1.0, -1.0, determinant(basis) < 0.0);
}

fn isVisibleFace(frontFacing: bool, orientation: f32) -> bool {
    return surface.surfaceFlags.x >= 0.5 || select(frontFacing, !frontFacing, orientation < 0.0);
}

fn isVisibleFade(pixel: vec2f, fade: f32) -> bool {
    if fade <= 0.0 {
        return true;
    }
    let at = vec2u(floor(pixel)) % vec2u(4u);
    let values = array<f32, 16>(0.0, 8.0, 2.0, 10.0, 12.0, 4.0, 14.0, 6.0, 3.0, 11.0, 1.0, 9.0, 15.0, 7.0, 13.0, 5.0);
    return (values[at.y * 4u + at.x] + 0.5) / 16.0 >= fade;
}

// The base color may have mip levels and the alpha test runs after per-pixel clipping.
@diagnostic(off, derivative_uniformity)
fn baseColorAlpha(uv0: vec2f, uv1: vec2f) -> f32 {
    let uv = select(uv0, uv1, surface.uvSets.x > 0.5);
    let transform = surface.textureTransforms[0];
    let at = vec2f(dot(transform.xy, uv), dot(transform.zw, uv)) + surface.textureTransforms[1].xy;
    return textureSample(baseColorImage, baseColorSampler, at).a;
}
