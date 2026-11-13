// WESL port of Public/Tonemapping.glsl. `mode` matches ToneMapper3D.shaderMode:
// 0 ACES filmic fit (Narkowicz), 1 Khronos PBR Neutral, 2 None (clip).

fn adaLinearToSrgb(input: vec3f) -> vec3f {
    let value = max(input, vec3f(0.0));
    return mix(value * 12.92, 1.055 * pow(value, vec3f(1.0 / 2.4)) - 0.055, step(vec3f(0.0031308), value));
}

fn adaAcesFit(value: vec3f) -> vec3f {
    let a = 2.51;
    let b = 0.03;
    let c = 2.43;
    let d = 0.59;
    let e = 0.14;
    return clamp((value * (a * value + b)) / (value * (c * value + d) + e), vec3f(0.0), vec3f(1.0));
}

// Khronos PBR Neutral Tone Mapper (https://github.com/KhronosGroup/ToneMapping), Apache-2.0.
fn adaNeutral(input: vec3f) -> vec3f {
    let startCompression = 0.8 - 0.04;
    let desaturation = 0.15;
    let x = min(input.r, min(input.g, input.b));
    let offset = select(0.04, x - 6.25 * x * x, x < 0.08);
    var color = input - vec3f(offset);
    let peak = max(color.r, max(color.g, color.b));
    if peak < startCompression {
        return color;
    }
    let d = 1.0 - startCompression;
    let newPeak = 1.0 - d * d / (peak + d - startCompression);
    color *= newPeak / peak;
    let g = 1.0 - 1.0 / (desaturation * (peak - newPeak) + 1.0);
    return mix(color, newPeak * vec3f(1.0), g);
}

fn adaToneMap(color: vec3f, mode: f32) -> vec3f {
    if mode > 1.5 {
        return clamp(color, vec3f(0.0), vec3f(1.0));
    }
    if mode > 0.5 {
        return clamp(adaNeutral(max(color, vec3f(0.0))), vec3f(0.0), vec3f(1.0));
    }
    return adaAcesFit(color);
}

fn adaOutputTransform(linearColor: vec3f, mode: f32) -> vec3f {
    return adaLinearToSrgb(adaToneMap(linearColor, mode));
}

// Stochastic rounding to 8-bit display codes with a screen-stable hash (no animated grain).
fn adaDitherDisplay(encodedColor: vec3f, pixel: vec2f) -> vec3f {
    let coordinate = vec2u(floor(pixel));
    var hash = (coordinate.x * 0x1f123bb5u) ^ (coordinate.y * 0x5f356495u);
    hash = (hash ^ (hash >> 16u)) * 0x7feb352du;
    hash = (hash ^ (hash >> 15u)) * 0x846ca68bu;
    hash ^= hash >> 16u;
    let threshold = (f32(hash & 65535u) + 0.5) / 65536.0;
    let codes = floor(clamp(encodedColor, vec3f(0.0), vec3f(1.0)) * 255.0 + vec3f(threshold));
    return clamp(codes, vec3f(0.0), vec3f(255.0)) / 255.0;
}
