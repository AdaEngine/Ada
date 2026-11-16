import package::atmosphere_common::{atmosphere, linearSampler, PI};

// Shared cloud ABI and shading: the uniform, the noise bindings, the density function and the aerial-perspective finish.
struct Clouds3DUniform {
    // x: coverage, y: density, z: cloud type, w: detail scale.
    shape: vec4f,
    // x: base altitude, y: thickness, z: lighting scale, w: ambient scale (meters, meters, scales).
    layer: vec4f,
    // xy: wind drift in meters, z: view steps, w: light steps.
    wind: vec4f,
    // x: frame index, y: 1 on the first frame after a reset, zw: unused.
    frame: vec4f,
    previousViewProjection: mat4x4f,
}

@group(0) @binding(5) var<uniform> clouds: Clouds3DUniform;
@group(0) @binding(6) var shapeNoise: texture_2d<f32>;
@group(0) @binding(7) var detailNoise: texture_2d<f32>;
@group(0) @binding(8) var weatherMap: texture_2d<f32>;
@group(0) @binding(11) var skyViewImage: texture_2d<f32>;
@group(0) @binding(12) var aerialImage: texture_2d<f32>;
@group(0) @binding(13) var aerialTransmittanceImage: texture_2d<f32>;

const EXTINCTION = 0.04;
const WEATHER_SCALE = 40000.0;
const SHAPE_SCALE = 9000.0;
const DETAIL_SCALE = 1100.0;
const MAX_DISTANCE_FADE = 150000.0;

fn remap(value: f32, fromLow: f32, fromHigh: f32, toLow: f32, toHigh: f32) -> f32 {
    return toLow + (value - fromLow) / (fromHigh - fromLow) * (toHigh - toLow);
}

// 3D noise stored as a grid of slices, filtered trilinearly: the slices wrap, so z is periodic. Inside a slice the
// texel is clamped to the tile, so x and y have a half-texel step at the tile boundary (every 9 km for the shape noise
// and 1.1 km for the detail noise), which is invisible at the resolution the clouds are drawn.
fn sampleAtlas(image: texture_2d<f32>, position: vec3f) -> vec4f {
    let dimensions = vec2f(textureDimensions(image, 0));
    let tile = dimensions.x / 8.0;
    let columns = 8.0;
    let sliceCount = columns * (dimensions.y / tile);
    let q = fract(position);
    let z = q.z * sliceCount - 0.5;
    let z0 = floor(z);
    let blend = z - z0;
    let first = (z0 + sliceCount) % sliceCount;
    let second = (z0 + 1.0 + sliceCount) % sliceCount;
    let texel = clamp(q.xy * tile, vec2f(0.5), vec2f(tile - 0.5));
    let uv0 = (vec2f(first % columns, floor(first / columns)) * tile + texel) / dimensions;
    let uv1 = (vec2f(second % columns, floor(second / columns)) * tile + texel) / dimensions;
    return mix(textureSampleLevel(image, linearSampler, uv0, 0.0), textureSampleLevel(image, linearSampler, uv1, 0.0), blend);
}

fn raySphere(origin: vec3f, direction: vec3f, radius: f32) -> vec2f {
    let b = dot(origin, direction);
    let c = dot(origin, origin) - radius * radius;
    let discriminant = b * b - c;
    if discriminant < 0.0 {
        return vec2f(-1.0);
    }
    let root = sqrt(discriminant);
    return vec2f(-b - root, -b + root);
}

fn heightGradient(h: f32, kind: f32) -> f32 {
    let stratus = smoothstep(0.0, 0.1, h) * (1.0 - smoothstep(0.2, 0.35, h));
    let cumulus = smoothstep(0.0, 0.1, h) * (1.0 - smoothstep(0.6, 1.0, h));
    return mix(stratus, cumulus, kind);
}

// Cloud extinction factor in [0, 1] at a planet-frame position. `detailed` adds the fine erosion.
fn cloudDensity(position: vec3f, h: f32, detailed: bool) -> f32 {
    let ground = atmosphere.planet.x;
    let cameraXZ = atmosphere.inverseView[3].xz;
    // The pattern drifts toward the wind direction: a feature seen at `p` now was at `p - wind` before.
    let world = vec3f(position.x + cameraXZ.x - clouds.wind.x, length(position) - ground, position.z + cameraXZ.y - clouds.wind.y);
    let weather = textureSampleLevel(weatherMap, linearSampler, fract(world.xz / WEATHER_SCALE), 0.0);
    let coverage = clouds.shape.x;
    let mask = clamp((weather.r - (1.0 - coverage * 1.65)) / max(coverage * 1.65, 0.0001), 0.0, 1.0);
    let gradient = heightGradient(h, clouds.shape.z);
    if mask * gradient <= 0.001 {
        return 0.0;
    }
    let shape = sampleAtlas(shapeNoise, world / SHAPE_SCALE);
    let fbm = shape.g * 0.625 + shape.b * 0.25 + shape.a * 0.125;
    var cloud = clamp(remap(shape.r, fbm * 0.7, 1.0, 0.0, 1.0), 0.0, 1.0) * gradient * mask;
    if detailed && cloud > 0.0 {
        let detail = sampleAtlas(detailNoise, world * clouds.shape.w / DETAIL_SCALE);
        let erosion = detail.r * 0.625 + detail.g * 0.25 + detail.b * 0.125;
        cloud = clamp(remap(cloud, mix(erosion, 1.0 - erosion, clamp(h * 3.0, 0.0, 1.0)) * 0.5, 1.0, 0.0, 1.0), 0.0, 1.0);
    }
    return clamp(remap(cloud, 0.2, 0.7, 0.0, 1.0), 0.0, 1.0);
}

fn henyeyGreenstein(cosine: f32, g: f32) -> f32 {
    let denominator = 1.0 + g * g - 2.0 * g * cosine;
    return (1.0 - g * g) / (4.0 * PI * pow(max(denominator, 0.0001), 1.5));
}

// Two lobes, forward and back, whose eccentricity falls with each scattering octave.
fn cloudPhase(cosine: f32, octave: f32) -> f32 {
    return mix(henyeyGreenstein(cosine, -0.3 * octave), henyeyGreenstein(cosine, 0.75 * octave), 0.6);
}

fn lightOpticalDepth(position: vec3f, sunDirection: vec3f, steps: i32, innerRadius: f32, thickness: f32) -> f32 {
    var depth = 0.0;
    var previous = 0.0;
    for (var index = 1; index <= 8; index++) {
        if index > steps { break; }
        let distance = f32(index * index) * 60.0;
        let point = position + sunDirection * distance;
        let h = (length(point) - innerRadius) / thickness;
        if h > 1.0 || h < 0.0 { break; }
        depth += cloudDensity(point, h, false) * EXTINCTION * clouds.shape.y * (distance - previous);
        previous = distance;
    }
    return depth;
}

fn bayer4(pixel: vec2f) -> f32 {
    let x = i32(pixel.x) & 3;
    let y = i32(pixel.y) & 3;
    var pattern = array<f32, 16>(0.0, 8.0, 2.0, 10.0, 12.0, 4.0, 14.0, 6.0, 3.0, 11.0, 1.0, 9.0, 15.0, 7.0, 13.0, 5.0);
    return (pattern[y * 4 + x] + 0.5) / 16.0;
}

fn aerialSlice(slice: f32, uv: vec2f) -> vec4f {
    let slices = atmosphere.aerial.z;
    let tile = f32(textureDimensions(aerialImage, 0).y);
    let texel = clamp(uv * tile, vec2f(0.5), vec2f(tile - 0.5));
    return textureSampleLevel(aerialImage, linearSampler, vec2f((slice * tile + texel.x) / (tile * slices), texel.y / tile), 0.0);
}

fn aerialTransmittance(slice: f32, uv: vec2f) -> vec3f {
    let slices = atmosphere.aerial.z;
    let tile = f32(textureDimensions(aerialTransmittanceImage, 0).y);
    let texel = clamp(uv * tile, vec2f(0.5), vec2f(tile - 0.5));
    return textureSampleLevel(aerialTransmittanceImage, linearSampler, vec2f((slice * tile + texel.x) / (tile * slices), texel.y / tile), 0.0).rgb;
}


// Applies aerial perspective at `distance`, then fades the farthest clouds into the horizon. `radiance` is premultiplied
// by `opacity`; the result is premultiplied radiance in rgb and the transmittance in alpha.
fn finishCloud(radiance: vec3f, opacity: f32, distance: f32, enter: f32, uv: vec2f) -> vec4f {
    let slices = atmosphere.aerial.z;
    let continuous = clamp(distance / atmosphere.aerial.x * slices - 1.0, 0.0, slices - 1.0);
    let lower = floor(continuous);
    let upper = min(lower + 1.0, slices - 1.0);
    let blend = continuous - lower;
    let scatter = mix(aerialSlice(lower, uv).rgb, aerialSlice(upper, uv).rgb, blend);
    let through = mix(aerialTransmittance(lower, uv), aerialTransmittance(upper, uv), blend);
    let near = clamp(distance / (atmosphere.aerial.x / slices), 0.0, 1.0);
    let haze = atmosphere.aerial.y;
    var color = radiance * mix(vec3f(1.0), mix(vec3f(1.0), through, near), clamp(haze, 0.0, 1.0)) + scatter * near * haze * opacity;
    let fade = exp(-enter / MAX_DISTANCE_FADE);
    color *= fade;
    return vec4f(color, 1.0 - opacity * fade);
}
