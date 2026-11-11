import package::tonemapping::{outputTransform, ditherDisplay};
import package::color_grading::{applyLut, gradeLinear};

struct EnvironmentUniform {
    projection: mat4x4f,
    inverseProjection: mat4x4f,
    inverseView: mat4x4f,
    zenithColor: vec4f,
    horizonColor: vec4f,
    groundColor: vec4f,
    clearColor: vec4f,
    reflection: vec4f,
    reflectionQuality: vec4f,
    environmentFlags: vec4f,
    starfield: vec4f,
    ibl: vec4f,
    quality: vec4f,
    postProcess: vec4f,
    grading: vec4f,
    vignette: vec4f,
    fogColor: vec4f,
    fogShape: vec4f,
    fogRange: vec4f,
    fogSun: vec4f,
    fogSunColor: vec4f,
    probePosition: vec4f,
    probeMinimum: vec4f,
    probeMaximum: vec4f,
    diffuseGI: vec4f,
}

@group(0) @binding(0) var sceneColor: texture_2d<f32>;
@group(0) @binding(1) var normalRoughness: texture_2d<f32>;
@group(0) @binding(2) var viewPositionMetallic: texture_2d<f32>;
@group(0) @binding(3) var linearSampler: sampler;
@group(0) @binding(4) var<uniform> environment: EnvironmentUniform;
@group(0) @binding(11) var gBufferSampler: sampler;
@group(0) @binding(12) var bloomImage: texture_2d<f32>;
@group(0) @binding(13) var gradingLut: texture_2d<f32>;
@group(0) @binding(14) var gradingSampler: sampler;
@group(0) @binding(15) var exposureImage: texture_2d<f32>;
@group(0) @binding(16) var volumetricImage: texture_2d<f32>;

fn srgbToLinear(value: vec3f) -> vec3f {
    return mix(value / 12.92, pow((value + 0.055) / 1.055, vec3f(2.4)), step(vec3f(0.04045), value));
}

fn presentColor(linearColor: vec3f, uv: vec2f, pixel: vec2f) -> vec3f {
    var exposureState = vec2f(0.0);
    if environment.vignette.y > 0.5 {
        exposureState = textureSampleLevel(exposureImage, gradingSampler, vec2f(0.5), 0.0).rg;
    }
    let automatic = exp2(exposureState.x + exposureState.y);
    let exposed = linearColor * (environment.postProcess.x * automatic)
        + textureSampleLevel(bloomImage, linearSampler, uv, 0.0).rgb * environment.postProcess.y;
    let graded = gradeLinear(exposed, environment.grading, environment.vignette, uv);
    if environment.quality.z > 0.5 {
        return graded;
    }
    let display = applyLut(gradingLut, gradingSampler, outputTransform(graded, environment.postProcess.z), environment.postProcess.w);
    return ditherDisplay(display, pixel);
}

fn volumetricDepthAt(uv: vec2f) -> f32 {
    let position = textureSampleLevel(viewPositionMetallic, gBufferSampler, uv, 0.0).xyz;
    return select(10000.0, position.z, length(position) > 0.0001);
}

// Weight neighboring volumetric texels by depth to avoid scattering across silhouettes.
fn volumetricScatter(uv: vec2f, depth: f32) -> vec4f {
    if environment.fogRange.z < 0.5 {
        return vec4f(0.0);
    }
    let size = vec2f(textureDimensions(volumetricImage, 0));
    let base = floor(uv * size - 0.5);
    let fraction = fract(uv * size - 0.5);
    var sum = vec4f(0.0);
    var plain = vec4f(0.0);
    var weights = 0.0;
    for (var y = 0; y < 2; y++) {
        for (var x = 0; x < 2; x++) {
            let sampleUV = clamp((base + vec2f(f32(x), f32(y)) + 0.5) / size, 0.5 / size, vec2f(1.0) - 0.5 / size);
            let bilinear = select(fraction.x, 1.0 - fraction.x, x == 0) * select(fraction.y, 1.0 - fraction.y, y == 0);
            let value = textureSampleLevel(volumetricImage, gBufferSampler, sampleUV, 0.0);
            let weight = bilinear * exp(-abs(volumetricDepthAt(sampleUV) - depth) / max(0.1 * depth, 0.05));
            sum += value * weight;
            plain += value * bilinear;
            weights += weight;
        }
    }
    if weights > 0.001 {
        return sum / weights;
    }
    return plain;
}

fn applyFog(linearColor: vec3f, viewPosition: vec3f, skyAmount: f32, isSky: bool, uv: vec2f) -> vec3f {
    if environment.fogColor.w <= 0.0 && environment.fogRange.z < 0.5 {
        return linearColor;
    }
    let travel = max(length(viewPosition) - environment.fogShape.z, 0.0);
    let worldDirection = normalize((environment.inverseView * vec4f(viewPosition, 0.0)).xyz);
    let falloff = environment.fogShape.x;
    let cameraHeight = environment.inverseView[3].y;
    let rise = falloff * worldDirection.y;
    let exponent = clamp(rise * travel, -60.0, 60.0);
    var pathFactor = travel;
    if abs(rise * travel) > 0.0001 {
        pathFactor = (1.0 - exp(-exponent)) / rise;
    }
    let baseDensity = environment.fogColor.w * exp(clamp(-falloff * (cameraHeight - environment.fogShape.y), -60.0, 60.0));
    let opacity = min(1.0 - exp(-baseDensity * pathFactor), environment.fogShape.w) * skyAmount;
    let sunAlignment = pow(max(dot(worldDirection, environment.fogSun.xyz), 0.0), environment.fogRange.y);
    let scattered = srgbToLinear(environment.fogColor.rgb) + environment.fogSunColor.rgb * (environment.fogSun.w * sunAlignment);
    let volume = volumetricScatter(uv, select(viewPosition.z, 10000.0, isSky));
    let color = mix(linearColor, scattered, opacity);
    if environment.fogRange.w < 0.5 {
        return color + volume.rgb;
    }
    return color * (1.0 - volume.a * skyAmount) + volume.rgb * skyAmount;
}
