// Output transform shared by every pass that writes display-referred color: tone map linear HDR, then
// encode to sRGB. Include with `#include <AdaEngine/Tonemapping.glsl>` inside a fragment stage.
//
// `mode` selects the operator and matches ToneMapper3D.shaderMode on the Swift side:
//   0  ACES filmic fit (Narkowicz). The default and the original behavior.
//   1  Khronos PBR Neutral. Keeps base colors close to authored values until highlights compress.
//   2  None: values above 1 clip to white.

vec3 adaLinearToSrgb(vec3 value) {
    value = max(value, vec3(0.0));
    return mix(value * 12.92, 1.055 * pow(value, vec3(1.0 / 2.4)) - 0.055, step(vec3(0.0031308), value));
}

vec3 adaAcesFit(vec3 value) {
    const float a = 2.51;
    const float b = 0.03;
    const float c = 2.43;
    const float d = 0.59;
    const float e = 0.14;
    return clamp((value * (a * value + b)) / (value * (c * value + d) + e), 0.0, 1.0);
}

// Khronos PBR Neutral Tone Mapper (https://github.com/KhronosGroup/ToneMapping), Apache-2.0.
vec3 adaNeutral(vec3 color) {
    const float startCompression = 0.8 - 0.04;
    const float desaturation = 0.15;
    float x = min(color.r, min(color.g, color.b));
    float offset = x < 0.08 ? x - 6.25 * x * x : 0.04;
    color -= offset;
    float peak = max(color.r, max(color.g, color.b));
    if (peak < startCompression) {
        return color;
    }
    float d = 1.0 - startCompression;
    float newPeak = 1.0 - d * d / (peak + d - startCompression);
    color *= newPeak / peak;
    float g = 1.0 - 1.0 / (desaturation * (peak - newPeak) + 1.0);
    return mix(color, newPeak * vec3(1.0), g);
}

vec3 adaToneMap(vec3 color, float mode) {
    if (mode > 1.5) {
        return clamp(color, vec3(0.0), vec3(1.0));
    }
    if (mode > 0.5) {
        return clamp(adaNeutral(max(color, vec3(0.0))), vec3(0.0), vec3(1.0));
    }
    return adaAcesFit(color);
}

vec3 adaOutputTransform(vec3 linearColor, float mode) {
    return adaLinearToSrgb(adaToneMap(linearColor, mode));
}

// Explicit stochastic rounding to 8-bit display codes. A common RGB threshold
// preserves channel ordering instead of adding colored noise to warm shadows.
// Returning exact normalized codes avoids hardware UNORM rounding near half-code
// boundaries changing their mean or turning a few white pixels into code 254.
// Exact black/white stay 0/255. Screen-stable hashing avoids animated film grain
// and the diagonal lattice of an ordered interleaved-gradient pattern.
vec3 adaDitherDisplay(vec3 encodedColor, vec2 pixel) {
    uvec2 coordinate = uvec2(floor(pixel));
    uint hash = coordinate.x * 0x1f123bb5u ^ coordinate.y * 0x5f356495u;
    hash = (hash ^ (hash >> 16u)) * 0x7feb352du;
    hash = (hash ^ (hash >> 15u)) * 0x846ca68bu;
    hash ^= hash >> 16u;
    float threshold = (float(hash & 65535u) + 0.5) / 65536.0;
    vec3 codes = floor(clamp(encodedColor, vec3(0.0), vec3(1.0)) * 255.0 + vec3(threshold));
    return clamp(codes, vec3(0.0), vec3(255.0)) / 255.0;
}
