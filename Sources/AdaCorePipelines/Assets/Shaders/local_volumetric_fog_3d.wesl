import package::fullscreen::{FullscreenVertex, fullscreenVertex};
import package::volumetric_fog_common::{loadNearestShadow, fog, positionImage, nearestSampler, henyeyGreenstein, sunVisibility, sunShadowGap};

struct LocalLight3D {
    positionRange: vec4f,
    radianceIntensity: vec4f,
    directionOuter: vec4f,
    innerShadow: vec4f,
}
struct LocalLighting3DUniform {
    lightCounts: vec4f,
    additionalDirections: array<vec4f, 3>,
    additionalRadiance: array<vec4f, 3>,
    localLights: array<LocalLight3D, 32>,
}
struct LocalShadow3DUniform {
    matrices: array<mat4x4f, 24>,
    atlas: vec4f,
}
struct LocalFogVolumes3DUniform {
    ambientCount: vec4f,
    volumes: array<vec4f, 24>,
}
@group(0) @binding(25) var<uniform> lighting: LocalLighting3DUniform;
@group(0) @binding(28) var<uniform> localShadow: LocalShadow3DUniform;
@group(0) @binding(26) var localShadowImage: texture_2d<f32>;
@group(0) @binding(5) var<uniform> localFog: LocalFogVolumes3DUniform;

@vertex
fn volumetric_fog_vertex(@builtin(vertex_index) index: u32) -> FullscreenVertex {
    return fullscreenVertex(index);
}

// Beer-Lambert scattering over the lit part of a constant-density segment.
// Refinement handles discontinuous atlas silhouettes before the planar-gap interpolation.
fn litSegmentWeight(origin: vec3f, direction: vec3f, viewRayZ: f32, startTravel: f32, stepLength: f32,
    startGap: f32, endGap: f32, opticalDepth: f32, wholeSegment: f32) -> f32 {
    if startGap >= 0.0 && endGap >= 0.0 { return wholeSegment; }
    if startGap < 0.0 && endGap < 0.0 { return 0.0; }
    var lower = 0.0;
    var upper = 1.0;
    var lowerGap = startGap;
    var upperGap = endGap;
    for (var refine = 0; refine < 5; refine++) {
        let middle = (lower + upper) * 0.5;
        let travel = startTravel + middle * stepLength;
        let gap = sunShadowGap(origin + direction * travel, travel * viewRayZ);
        if (gap >= 0.0) == (lowerGap >= 0.0) {
            lower = middle;
            lowerGap = gap;
        } else {
            upper = middle;
            upperGap = gap;
        }
    }
    let crossing = mix(lower, upper, clamp(lowerGap / (lowerGap - upperGap), 0.0, 1.0));
    if startGap >= 0.0 { return 1.0 - exp(-opticalDepth * crossing); }
    return exp(-opticalDepth * crossing) * (1.0 - exp(-opticalDepth * (1.0 - crossing)));
}

fn localVisibility(light: LocalLight3D, world: vec3f) -> f32 {
    let slot = i32(light.innerShadow.w);
    if slot < 0 || slot >= 4 { return 1.0; }
    let ray = world - light.positionRange.xyz;
    let a = abs(ray);
    var face = 0;
    if light.directionOuter.w < 0.0 {
        if a.x >= a.y && a.x >= a.z { face = select(1, 0, ray.x >= 0.0); }
        else if a.y >= a.z { face = select(3, 2, ray.y >= 0.0); }
        else { face = select(5, 4, ray.z >= 0.0); }
    }
    let clip = localShadow.matrices[slot * 6 + face] * vec4f(world, 1.0);
    if clip.w <= 0.0 { return 1.0; }
    let ndc = clip.xyz / clip.w;
    if ndc.z < 0.0 || ndc.z > 1.0 || any(abs(ndc.xy) > vec2f(1.0)) { return 1.0; }
    let origin = vec2f(f32(face), f32(slot)) * localShadow.atlas.z;
    var uv = (origin + (ndc.xy * vec2f(0.5, -0.5) + 0.5) * localShadow.atlas.z) * localShadow.atlas.xy;
    uv = clamp(uv, (origin + 0.5) * localShadow.atlas.xy, (origin + localShadow.atlas.z - 0.5) * localShadow.atlas.xy);
    let stored = loadNearestShadow(localShadowImage, uv);
    return select(0.0, 1.0, ndc.z - light.innerShadow.y <= stored);
}

fn localRadiance(world: vec3f, worldDirection: vec3f) -> vec3f {
    var result = vec3f(0.0);
    let count = min(i32(lighting.lightCounts.y), i32(fog.march.z));
    for (var i = 0; i < 8; i++) {
        if i >= count { break; }
        let light = lighting.localLights[i];
        let delta = light.positionRange.xyz - world;
        let distance = length(delta);
        let range = light.positionRange.w;
        if distance >= range || range <= 0.0 { continue; }
        let direction = delta / max(distance, 0.0001);
        let cutoff = max(0.0, 1.0 - pow(distance / range, 4.0));
        var attenuation = cutoff * cutoff / max(distance * distance, 0.04);
        if light.directionOuter.w >= 0.0 {
            attenuation *= smoothstep(light.directionOuter.w, light.innerShadow.x, dot(normalize(light.directionOuter.xyz), -direction));
        }
        if attenuation <= 0.0 { continue; }
        result += light.radianceIntensity.rgb * max(light.radianceIntensity.w, 0.0) * attenuation
            * henyeyGreenstein(dot(worldDirection, direction), fog.sunDirection.w) * localVisibility(light, world);
    }
    return result * fog.sunRadiance.w;
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
    let boundedMedium = localFog.ambientCount.w > 0.0;
    var previousSunGap = 0.0;
    if boundedMedium {
        previousSunGap = sunShadowGap(origin + worldDirection * rangeStart, rangeStart * viewRay.z);
    }
    var transmittance = 1.0;
    var scattered = vec3f(0.0);
    var scatteredSun = 0.0;
    var localOpticalDepth = 0.0;
    for (var index = 0; index < 64; index++) {
        if index >= steps { break; }
        let travel = rangeStart + (f32(index) + 0.5) * stepLength;
        let world = origin + worldDirection * travel;
        let density = fog.medium.x * exp(clamp(-fog.medium.y * (world.y - fog.medium.z), -60.0, 60.0));
        var scatteringDensity = vec3f(density);
        var localDensity = 0.0;
        for (var v = 0; v < 8; v++) {
            if v >= i32(localFog.ambientCount.w) { break; }
            let lo = localFog.volumes[v * 3];
            let hi = localFog.volumes[v * 3 + 1];
            let edge = min(world - lo.xyz, hi.xyz - world);
            let fade = clamp(min(edge.x, min(edge.y, edge.z)) / hi.w, 0.0, 1.0);
            let d = lo.w * fade;
            localDensity += d;
            scatteringDensity += d * localFog.volumes[v * 3 + 2].rgb;
        }
        let total = density + localDensity;
        let opticalDepth = total * stepLength;
        let segment = 1.0 - exp(-opticalDepth);
        var sunVisible = 0.0;
        if boundedMedium {
            // Reuse one new endpoint lookup as the next segment's start.
            let endTravel = rangeStart + f32(index + 1) * stepLength;
            let nextSunGap = sunShadowGap(origin + worldDirection * endTravel, endTravel * viewRay.z);
            let litWeight = litSegmentWeight(origin, worldDirection, viewRay.z,
                rangeStart + f32(index) * stepLength, stepLength, previousSunGap, nextSunGap, opticalDepth, segment);
            previousSunGap = nextSunGap;
            let source = segment * (localRadiance(world, worldDirection) * scatteringDensity
                + localDensity * localFog.ambientCount.rgb)
                + litWeight * fog.sunRadiance.rgb * phase * scatteringDensity;
            scattered += transmittance * source / max(total, 0.000001);
        } else {
            // Preserve the established global height-fog integrator and references.
            sunVisible = sunVisibility(world, travel * viewRay.z);
            let sun = fog.sunRadiance.rgb * (phase * sunVisible);
            scattered += transmittance * segment * (localRadiance(world, worldDirection) * scatteringDensity
                + sun * (scatteringDensity - vec3f(density)) + localDensity * localFog.ambientCount.rgb) / max(total, 0.000001);
        }
        transmittance *= exp(-total * stepLength);
        if !boundedMedium { scatteredSun += density * stepLength * transmittance * sunVisible; }
        localOpticalDepth += localDensity * stepLength;
    }
    return vec4f(scattered + fog.sunRadiance.rgb * (scatteredSun * phase), min(1.0 - exp(-localOpticalDepth), fog.march.w));
}
