import package::tonemapping::{outputTransform, ditherDisplay};
import package::color_grading::{applyLut, gradeLinear};
import package::height_fog_3d::heightFogOpacity;

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
    atmosphere: vec4f,
    atmosphereSun: vec4f,
    atmospherePlanet: vec4f,
    atmosphereIlluminance: vec4f,
    clouds: vec4f,
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
@group(0) @binding(21) var skyViewImage: texture_2d<f32>;
@group(0) @binding(22) var aerialImage: texture_2d<f32>;
@group(0) @binding(23) var transmittanceImage: texture_2d<f32>;
@group(0) @binding(24) var aerialTransmittanceImage: texture_2d<f32>;
@group(0) @binding(25) var cloudImage: texture_2d<f32>;

const ATMOSPHERE_PI = 3.14159265359;

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
    let worldDirection = normalize((environment.inverseView * vec4f(viewPosition, 0.0)).xyz);
    let opacity = heightFogOpacity(environment.fogColor.w, environment.fogShape, environment.inverseView[3].y, worldDirection.y, length(viewPosition)) * skyAmount;
    let sunAlignment = pow(max(dot(worldDirection, environment.fogSun.xyz), 0.0), environment.fogRange.y);
    let scattered = srgbToLinear(environment.fogColor.rgb) + environment.fogSunColor.rgb * (environment.fogSun.w * sunAlignment);
    let volume = volumetricScatter(uv, select(viewPosition.z, 10000.0, isSky));
    let color = mix(linearColor, scattered, opacity);
    if environment.fogRange.w < 0.5 {
        return color + volume.rgb;
    }
    return color * (1.0 - volume.a * skyAmount) + volume.rgb * skyAmount;
}

// Physical atmosphere. Every function below is reached only when `environment.atmosphere.x` is set, so the
// disabled path executes exactly the code it did before. The table layouts mirror atmosphere_common.wgsl.
fn atmosphereActive() -> bool {
    return environment.atmosphere.x > 0.5;
}

fn atmosphereSubUv(unit: vec2f, size: vec2f) -> vec2f {
    return (unit * (size - 1.0) + 0.5) / size;
}

fn atmosphereSunHorizontal() -> vec2f {
    let horizontal = environment.atmosphereSun.xz;
    let length2 = dot(horizontal, horizontal);
    return select(vec2f(1.0, 0.0), horizontal * inverseSqrt(max(length2, 0.000001)), length2 > 0.000001);
}

fn atmosphereSkyViewUv(direction: vec3f) -> vec2f {
    let r = environment.atmospherePlanet.z;
    let ground = environment.atmospherePlanet.x;
    let beta = acos(clamp(sqrt(max(r * r - ground * ground, 0.0)) / r, 0.0, 1.0));
    let horizonZenith = ATMOSPHERE_PI - beta;
    let zenith = acos(clamp(direction.y, -1.0, 1.0));
    var y: f32;
    if zenith < horizonZenith {
        y = 0.5 * (1.0 - sqrt(max(1.0 - zenith / max(horizonZenith, 0.0001), 0.0)));
    } else {
        y = 0.5 + 0.5 * sqrt(max((zenith - horizonZenith) / max(beta, 0.0001), 0.0));
    }
    let horizontal = direction.xz;
    let length2 = dot(horizontal, horizontal);
    let planar = select(atmosphereSunHorizontal(), horizontal * inverseSqrt(max(length2, 0.000001)), length2 > 0.000001);
    let azimuth = acos(clamp(dot(planar, atmosphereSunHorizontal()), -1.0, 1.0));
    return atmosphereSubUv(vec2f(sqrt(azimuth / ATMOSPHERE_PI), clamp(y, 0.0, 1.0)), vec2f(textureDimensions(skyViewImage, 0)));
}

fn atmosphereTransmittanceToTop(r: f32, mu: f32) -> vec3f {
    let top = environment.atmospherePlanet.y;
    let ground = environment.atmospherePlanet.x;
    if mu < 0.0 && r * r * (mu * mu - 1.0) + ground * ground >= 0.0 {
        return vec3f(0.0);
    }
    let horizon = sqrt(max(top * top - ground * ground, 0.0));
    let rho = sqrt(max(r * r - ground * ground, 0.0));
    let d = max(0.0, -r * mu + sqrt(max(r * r * (mu * mu - 1.0) + top * top, 0.0)));
    let dMin = top - r;
    let dMax = rho + horizon;
    let unit = vec2f(clamp((d - dMin) / max(dMax - dMin, 0.001), 0.0, 1.0), clamp(rho / horizon, 0.0, 1.0));
    return textureSampleLevel(transmittanceImage, linearSampler, atmosphereSubUv(unit, vec2f(textureDimensions(transmittanceImage, 0))), 0.0).rgb;
}

// Keep the sky-view and transmittance lookups below in step with atmosphere_common.wgsl, which writes the tables.
// The sun's disc, dimmed and reddened by the air between it and the camera, and darker toward its limb.
fn atmosphereSunDisc(direction: vec3f) -> vec3f {
    let sun = environment.atmosphereSun.xyz;
    let radius = environment.atmosphere.w;
    if radius <= 0.0 {
        return vec3f(0.0);
    }
    let cosine = dot(direction, sun);
    // Edges as cosines, increasing, so smoothstep is well defined and a pixel at the disc centre is not NaN.
    let coverage = smoothstep(cos(radius * 1.15), cos(radius * 0.85), cosine);
    let r = environment.atmospherePlanet.z;
    let ground = environment.atmospherePlanet.x;
    let horizonCosine = -sqrt(max(1.0 - ground * ground / (r * r), 0.0));
    if coverage <= 0.0 || direction.y <= horizonCosine {
        return vec3f(0.0);
    }
    // Linear limb darkening, I(mu) = 1 - u (1 - mu), scaled by 1 / (1 - u / 3) so the disc keeps its total energy.
    let distanceSquared = clamp(2.0 * (1.0 - cosine) / (radius * radius), 0.0, 1.0);
    let limb = (1.0 - 0.6 * (1.0 - sqrt(1.0 - distanceSquared))) / 0.8;
    return environment.atmosphereIlluminance.rgb * atmosphereTransmittanceToTop(r, sun.y) * (environment.atmosphere.z * coverage * limb);
}

// Sky radiance along a world-space direction: scattered light, the sun disc, and stars that fade in at night.
fn atmosphereSky(direction: vec3f, stars: vec3f, showsSun: bool) -> vec3f {
    let sample = textureSampleLevel(skyViewImage, linearSampler, atmosphereSkyViewUv(direction), 0.0);
    let night = 1.0 - smoothstep(-0.15, 0.1, environment.atmosphereSun.y);
    let disc = select(vec3f(0.0), atmosphereSunDisc(direction), showsSun);
    return sample.rgb + disc + stars * (night * sample.a);
}

fn atmosphereAerialSlice(slice: f32, uv: vec2f) -> vec4f {
    let slices = environment.atmosphereIlluminance.w;
    let tile = f32(textureDimensions(aerialImage, 0).y);
    let texel = clamp(uv * tile, vec2f(0.5), vec2f(tile - 0.5));
    return textureSampleLevel(aerialImage, linearSampler, vec2f((slice * tile + texel.x) / (tile * slices), texel.y / tile), 0.0);
}

fn atmosphereAerialTransmittance(slice: f32, uv: vec2f) -> vec3f {
    let slices = environment.atmosphereIlluminance.w;
    let tile = f32(textureDimensions(aerialTransmittanceImage, 0).y);
    let texel = clamp(uv * tile, vec2f(0.5), vec2f(tile - 0.5));
    return textureSampleLevel(aerialTransmittanceImage, linearSampler, vec2f((slice * tile + texel.x) / (tile * slices), texel.y / tile), 0.0).rgb;
}

// Light scattered into the view ray, and the light of the surface it dims, between the camera and a surface.
fn applyAerialPerspective(linearColor: vec3f, viewPosition: vec3f, uv: vec2f) -> vec3f {
    let slices = environment.atmosphereIlluminance.w;
    let maximum = environment.atmospherePlanet.w;
    let distance = length(viewPosition);
    let continuous = clamp(distance / maximum * slices - 1.0, 0.0, slices - 1.0);
    let lower = floor(continuous);
    let upper = min(lower + 1.0, slices - 1.0);
    let blend = continuous - lower;
    var scattered = mix(atmosphereAerialSlice(lower, uv).rgb, atmosphereAerialSlice(upper, uv).rgb, blend);
    var transmitted = mix(atmosphereAerialTransmittance(lower, uv), atmosphereAerialTransmittance(upper, uv), blend);
    // Closer than the first slice the effect grows from nothing.
    let near = clamp(distance / (maximum / slices), 0.0, 1.0);
    scattered *= near;
    transmitted = mix(vec3f(1.0), transmitted, near);
    let scale = environment.atmosphere.y;
    return linearColor * mix(vec3f(1.0), transmitted, clamp(scale, 0.0, 1.0)) + scattered * scale;
}

// The cloud layer over the sky. The texture holds premultiplied radiance and the transmittance of the clouds, at
// reduced resolution, so it is filtered bilinearly.
fn cloudsActive() -> bool {
    return environment.clouds.x > 0.5;
}

fn applyClouds(sky: vec3f, uv: vec2f) -> vec3f {
    let cloud = textureSampleLevel(cloudImage, linearSampler, uv, 0.0);
    return sky * cloud.a + cloud.rgb;
}
