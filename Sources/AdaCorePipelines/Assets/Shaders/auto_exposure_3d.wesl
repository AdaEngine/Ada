import package::fullscreen::{FullscreenVertex, fullscreenVertex};

struct AutoExposureUniform {
    // Mode, delta time, and adaptation speeds.
    parameters: vec4f,
    // Minimum EV, maximum EV, and reset.
    limits: vec4f,
}

@group(0) @binding(0) var sourceImage: texture_2d<f32>;
@group(0) @binding(1) var auxiliaryImage: texture_2d<f32>;
@group(0) @binding(2) var nearestSampler: sampler;
@group(0) @binding(3) var linearSampler: sampler;
@group(0) @binding(4) var<uniform> exposure: AutoExposureUniform;

const METER_SIZE: f32 = 64.0;

@vertex
fn auto_exposure_vertex(@builtin(vertex_index) index: u32) -> FullscreenVertex {
    return fullscreenVertex(index);
}

// Accumulate coverage-weighted log luminance over a 4 × 4 grid.
fn meter(uv: vec2f) -> vec4f {
    let origin = uv - vec2f(0.5 / METER_SIZE);
    var sum = vec2f(0.0);
    for (var y = 0; y < 4; y++) {
        for (var x = 0; x < 4; x++) {
            let sampleUV = origin + (vec2f(f32(x), f32(y)) + 0.5) / 4.0 / METER_SIZE;
            let normal = textureSampleLevel(auxiliaryImage, nearestSampler, sampleUV, 0.0).xyz;
            let color = max(textureSampleLevel(sourceImage, nearestSampler, sampleUV, 0.0).rgb, vec3f(0.0));
            let luminance = clamp(dot(color, vec3f(0.2126, 0.7152, 0.0722)), 0.0, 65000.0);
            // Exclude pixels without geometry and exact black, keeping genuinely dim surfaces.
            let metered = select(0.0, 1.0, length(normal) > 0.1 && luminance > 0.0);
            sum += vec2f(log2(max(luminance, 0.000001)), 1.0) * metered;
        }
    }
    return vec4f(sum / 16.0, 0.0, 1.0);
}

fn adapt() -> vec4f {
    let sums = textureSampleLevel(sourceImage, linearSampler, vec2f(0.5), 0.0);
    let previous = textureSampleLevel(auxiliaryImage, nearestSampler, vec2f(0.5), 0.0);
    let coverage = sums.y;
    let averageLog = sums.x / max(coverage, 0.0005);
    let desired = clamp(log2(0.18) - averageLog, exposure.limits.x, exposure.limits.y);
    let initialized = previous.w > 0.5 && exposure.limits.z < 0.5;
    // Start neutral and keep the previous state inside the active limits.
    let base = clamp(select(0.0, previous.x + previous.y, initialized), exposure.limits.x, exposure.limits.y);
    var ev = base;
    if coverage > 0.0005 {
        let speed = select(exposure.parameters.w, exposure.parameters.z, desired > base);
        let blend = select(1.0 - exp(-exposure.parameters.y * speed), 1.0, speed >= 1000000.0);
        ev = mix(base, desired, blend);
    }
    // Store the half-precision rounding residual so small adaptation steps accumulate.
    let high = unpack2x16float(pack2x16float(vec2f(ev, 0.0))).x;
    return vec4f(high, ev - high, coverage, 1.0);
}

@fragment
fn auto_exposure_fragment(input: FullscreenVertex) -> @location(0) vec4f {
    if exposure.parameters.x < 0.5 {
        return meter(input.uv);
    }
    if exposure.parameters.x < 1.5 {
        return textureSampleLevel(sourceImage, linearSampler, input.uv, 0.0);
    }
    return adapt();
}
