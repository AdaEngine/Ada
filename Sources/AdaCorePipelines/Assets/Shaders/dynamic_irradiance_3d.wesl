import package::fullscreen::{FullscreenVertex, fullscreenVertex};

struct IrradianceUniform {
    grid: vec4f,
    update: vec4f,
    blend: vec4f,
}
struct LocalLight {
    positionRange: vec4f,
    radianceIntensity: vec4f,
    directionOuter: vec4f,
    innerShadow: vec4f,
}
struct LightingUniform {
    counts: vec4f,
    additionalDirections: array<vec4f, 3>,
    additionalRadiance: array<vec4f, 3>,
    lights: array<LocalLight, 32>,
}
struct ShadowUniform {
    matrices: array<mat4x4f, 24>,
    atlas: vec4f,
}

@group(0) @binding(0) var positions: texture_2d<f32>;
@group(0) @binding(1) var normals: texture_2d<f32>;
@group(0) @binding(2) var albedoImage: texture_2d<f32>;
@group(0) @binding(3) var previousImage: texture_2d<f32>;
@group(0) @binding(4) var<uniform> irradiance: IrradianceUniform;
@group(0) @binding(6) var staticSH: texture_2d<f32>;
@group(0) @binding(25) var<uniform> lighting: LightingUniform;
@group(0) @binding(26) var shadowImage: texture_2d<f32>;
@group(0) @binding(28) var<uniform> shadows: ShadowUniform;

@vertex
fn dynamic_probe_vertex(@builtin(vertex_index) index: u32) -> FullscreenVertex {
    return fullscreenVertex(index);
}

fn pointFace(ray: vec3f) -> i32 {
    let axis = abs(ray);
    if axis.x >= axis.y && axis.x >= axis.z {
        return select(1, 0, ray.x >= 0.0);
    }
    if axis.y >= axis.z {
        return select(3, 2, ray.y >= 0.0);
    }
    return select(5, 4, ray.z >= 0.0);
}

fn localVisibility(light: LocalLight, world: vec3f) -> f32 {
    let slot = i32(light.innerShadow.w);
    if slot < 0 || slot >= 4 {
        return 1.0;
    }
    let face = select(0, pointFace(world - light.positionRange.xyz), light.directionOuter.w < 0.0);
    let clip = shadows.matrices[slot * 6 + face] * vec4f(world, 1.0);
    if clip.w <= 0.0 {
        return 1.0;
    }
    let ndc = clip.xyz / clip.w;
    if ndc.z < 0.0 || ndc.z > 1.0 || any(abs(ndc.xy) > vec2f(1.0)) {
        return 1.0;
    }
    let atlas = shadows.atlas;
    let origin = vec2f(f32(face), f32(slot)) * atlas.z;
    let uv = (origin + (ndc.xy * vec2f(0.5, -0.5) + 0.5) * atlas.z) * atlas.xy;
    let bounded = clamp(uv, (origin + 0.5) * atlas.xy, (origin + atlas.z - 0.5) * atlas.xy);
    let size = vec2i(textureDimensions(shadowImage, 0));
    let pixel = clamp(vec2i(bounded * vec2f(size)), vec2i(0), size - 1);
    let stored = textureLoad(shadowImage, pixel, 0).r;
    return select(0.0, 1.0, ndc.z - light.innerShadow.y <= stored);
}

fn incoming(world: vec3f, normal: vec3f) -> vec3f {
    var result = vec3f(0.0);
    for (var index = 0; index < min(4, i32(irradiance.update.w)); index++) {
        let light = lighting.lights[index];
        let delta = light.positionRange.xyz - world;
        let distanceToLight = length(delta);
        let range = light.positionRange.w;
        if distanceToLight >= range || range <= 0.0 {
            continue;
        }
        let direction = delta / max(distanceToLight, 0.0001);
        let cosine = max(dot(normal, direction), 0.0);
        if cosine <= 0.0 {
            continue;
        }
        let ratio = distanceToLight / range;
        let cutoff = max(1.0 - ratio * ratio * ratio * ratio, 0.0);
        var attenuation = cutoff * cutoff / max(distanceToLight * distanceToLight, 0.01);
        if light.directionOuter.w >= 0.0 {
            attenuation *= smoothstep(light.directionOuter.w, light.innerShadow.x, dot(-direction, light.directionOuter.xyz));
        }
        if attenuation > 0.0 {
            result += light.radianceIntensity.rgb * (light.radianceIntensity.w * attenuation * cosine
                * localVisibility(light, world + normal * 0.012) / 3.14159265359);
        }
    }
    return clamp(result, vec3f(0.0), vec3f(32.0));
}

@fragment
fn dynamic_probe_fragment(input: FullscreenVertex) -> @location(0) vec4f {
    let pixel = vec2i(input.position.xy);
    let grid = irradiance.grid;
    let update = irradiance.update;
    let count = i32(grid.x * grid.y * grid.z);
    let samples = i32(grid.w);
    let probe = pixel.y * i32(grid.x) + pixel.x / 9;
    let coefficient = pixel.x % 9;
    if update.w < 0.5 || textureLoad(staticSH, vec2i(pixel.x / 9 * 9, pixel.y), 0).a < 0.5 {
        return vec4f(0.0);
    }
    let previous = select(textureLoad(previousImage, pixel, 0), vec4f(0.0), update.z > 0.5);
    let age = (probe - i32(update.x) + count) % count;
    if age >= i32(update.y) {
        return previous;
    }
    var value = vec3f(0.0);
    for (var index = 0; index < min(256, samples); index++) {
        let address = vec2i(pixel.x / 9 * samples + index, pixel.y);
        let hit = textureLoad(positions, address, 0);
        if hit.a < 0.5 {
            continue;
        }
        let normal = normalize(textureLoad(normals, address, 0).xyz);
        let albedo = clamp(textureLoad(albedoImage, address, 0).rgb, vec3f(0.0), vec3f(0.96));
        let y = 1.0 - 2.0 * (f32(index) + 0.5) / f32(samples);
        let radius = sqrt(max(1.0 - y * y, 0.0));
        let phi = f32(index) * 2.399963229728653;
        let d = vec3f(radius * cos(phi), y, radius * sin(phi));
        let basis = array<f32, 9>(
            0.2820947918, 0.4886025119*d.y, 0.4886025119*d.z, 0.4886025119*d.x,
            1.0925484306*d.x*d.y, 1.0925484306*d.y*d.z, 0.3153915653*(3.0*d.z*d.z-1.0),
            1.0925484306*d.x*d.z, 0.5462742153*(d.x*d.x-d.y*d.y),
        );
        let convolution = select(select(0.25, 0.6666666667, coefficient < 4), 1.0, coefficient == 0);
        value += albedo * incoming(hit.xyz, normal) * (basis[coefficient] * convolution * 12.56637061436 / f32(samples));
    }
    return vec4f(mix(value * irradiance.blend.y, previous.rgb, select(irradiance.blend.x, 0.0, update.z > 0.5)), 1.0);
}
