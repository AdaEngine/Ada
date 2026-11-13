fn linearToSrgb(value: vec3f) -> vec3f {
    let color = max(value, vec3f(0.0));
    return mix(color * 12.92, 1.055 * pow(color, vec3f(1.0 / 2.4)) - 0.055, step(vec3f(0.0031308), color));
}

fn acesFit(color: vec3f) -> vec3f {
    return clamp((color * (2.51 * color + 0.03)) / (color * (2.43 * color + 0.59) + 0.14), vec3f(0.0), vec3f(1.0));
}

// Khronos PBR Neutral Tone Mapper (https://github.com/KhronosGroup/ToneMapping), Apache-2.0.
fn neutralToneMap(color: vec3f) -> vec3f {
    let startCompression = 0.8 - 0.04;
    let desaturation = 0.15;
    let x = min(color.r, min(color.g, color.b));
    let offset = select(0.04, x - 6.25 * x * x, x < 0.08);
    let shifted = color - offset;
    let peak = max(shifted.r, max(shifted.g, shifted.b));
    if peak < startCompression {
        return shifted;
    }
    let d = 1.0 - startCompression;
    let newPeak = 1.0 - d * d / (peak + d - startCompression);
    let scaled = shifted * (newPeak / peak);
    let gray = 1.0 - 1.0 / (desaturation * (peak - newPeak) + 1.0);
    return mix(scaled, vec3f(newPeak), gray);
}

// Matches ToneMapper3D.shaderMode: ACES, PBR Neutral, or clamped linear.
fn toneMap(color: vec3f, mode: f32) -> vec3f {
    if mode > 1.5 {
        return clamp(color, vec3f(0.0), vec3f(1.0));
    }
    if mode > 0.5 {
        return clamp(neutralToneMap(max(color, vec3f(0.0))), vec3f(0.0), vec3f(1.0));
    }
    return acesFit(color);
}

fn outputTransform(color: vec3f, mode: f32) -> vec3f {
    return linearToSrgb(toneMap(color, mode));
}

// Use a screen-stable RGB threshold and emit exact 8-bit display codes.
fn ditherDisplay(color: vec3f, pixel: vec2f) -> vec3f {
    let coordinate = vec2u(floor(pixel));
    var hash = (coordinate.x * 0x1f123bb5u) ^ (coordinate.y * 0x5f356495u);
    hash = (hash ^ (hash >> 16u)) * 0x7feb352du;
    hash = (hash ^ (hash >> 15u)) * 0x846ca68bu;
    hash ^= hash >> 16u;
    let threshold = (f32(hash & 65535u) + 0.5) / 65536.0;
    let codes = floor(clamp(color, vec3f(0.0), vec3f(1.0)) * 255.0 + vec3f(threshold));
    return clamp(codes, vec3f(0.0), vec3f(255.0)) / 255.0;
}
