import package::fullscreen::{FullscreenVertex, fullscreenVertex};
import package::volumetric_fog_common::{fog, positionImage, nearestSampler, henyeyGreenstein, sunVisibility};

@vertex
fn volumetric_fog_vertex(@builtin(vertex_index) index: u32) -> FullscreenVertex {
    return fullscreenVertex(index);
}

fn interleavedGradientNoise(pixel: vec2f) -> f32 {
    return fract(52.9829189 * fract(dot(pixel, vec2f(0.06711056, 0.00583715))));
}

@fragment
fn volumetric_fog_fragment(input: FullscreenVertex) -> @location(0) vec4f {
    let positionMetallic = textureSampleLevel(positionImage, nearestSampler, input.uv, 0.0);
    let ndc = vec2f(input.uv.x * 2.0 - 1.0, 1.0 - input.uv.y * 2.0);
    let viewFar = fog.inverseProjection * vec4f(ndc, 1.0, 1.0);
    let viewRay = normalize(viewFar.xyz / viewFar.w);
    let hasSurface = length(positionMetallic.xyz) > 0.0001;
    let surfaceDistance = select(fog.march.y, length(positionMetallic.xyz), hasSurface);
    let rangeEnd = min(surfaceDistance, fog.march.y);
    let rangeStart = min(fog.medium.w, rangeEnd);
    let steps = i32(fog.march.x);
    let stepLength = (rangeEnd - rangeStart) / f32(steps);
    if stepLength <= 0.0 { return vec4f(0.0); }
    let worldDirection = normalize((fog.inverseView * vec4f(viewRay, 0.0)).xyz);
    let origin = fog.inverseView[3].xyz;
    let phase = henyeyGreenstein(dot(worldDirection, fog.sunDirection.xyz), fog.sunDirection.w);
    let jitter = fract(interleavedGradientNoise(input.position.xy) + fog.march.z);
    var transmittance = 1.0;
    var scattered = 0.0;
    for (var index = 0; index < 64; index++) {
        if index >= steps { break; }
        let travel = rangeStart + (f32(index) + jitter) * stepLength;
        let world = origin + worldDirection * travel;
        let density = fog.medium.x * exp(clamp(-fog.medium.y * (world.y - fog.medium.z), -60.0, 60.0));
        let opticalStep = density * stepLength;
        transmittance *= exp(-opticalStep);
        scattered += opticalStep * transmittance * sunVisibility(world, travel * viewRay.z);
    }
    return vec4f(fog.sunRadiance.rgb * (scattered * phase), 1.0);
}
