// WESL port of Public/ColorGrading.glsl. The LUT texture and sampler are parameters instead of includer globals.
// The LUT is a strip of N tiles (N x N pixels each): red along x, green down rows, blue selects the tile.

// grading: x saturation, y contrast, z vignette intensity, w vignette radius; vignette.x is smoothness.
fn adaGradeLinear(input: vec3f, grading: vec4f, vignette: vec4f, uv: vec2f) -> vec3f {
    var color = input;
    if grading.y != 1.0 {
        let pivot = 0.18;
        color = pivot * pow(max(color, vec3f(0.0)) / pivot, vec3f(grading.y));
    }
    if grading.x != 1.0 {
        let luma = dot(color, vec3f(0.2126, 0.7152, 0.0722));
        color = max(mix(vec3f(luma), color, grading.x), vec3f(0.0));
    }
    if grading.z > 0.0 {
        let corner = length((uv - vec2f(0.5)) * 2.0) / 1.41421356;
        color *= 1.0 - grading.z * smoothstep(grading.w, grading.w + max(vignette.x, 0.01), corner);
    }
    return color;
}

fn adaSampleLutTile(lut: texture_2d<f32>, lutSampler: sampler, color: vec3f, tile: f32, size: f32) -> vec3f {
    let texel = vec2f(1.0 / (size * size), 1.0 / size);
    let inTile = color.rg * (size - 1.0) + vec2f(0.5);
    return textureSampleLevel(lut, lutSampler, vec2f(tile * size + inTile.x, inTile.y) * texel, 0.0).rgb;
}

// Display-referred color through the LUT, blended by `intensity` (0 returns the input unchanged).
fn adaApplyLut(lut: texture_2d<f32>, lutSampler: sampler, color: vec3f, intensity: f32) -> vec3f {
    if intensity <= 0.0 {
        return color;
    }
    let size = f32(textureDimensions(lut, 0).y);
    let clamped = clamp(color, vec3f(0.0), vec3f(1.0));
    let blue = clamped.b * (size - 1.0);
    let lower = floor(blue);
    let upper = min(lower + 1.0, size - 1.0);
    let graded = mix(
        adaSampleLutTile(lut, lutSampler, clamped, lower, size),
        adaSampleLutTile(lut, lutSampler, clamped, upper, size),
        blue - lower
    );
    return mix(color, graded, intensity);
}
