import package::fullscreen::{FullscreenVertex, fullscreenVertex};
import package::atmosphere_common::{atmosphere, linearSampler, transmittanceToSun, skyViewDirectionToUv, hitsGround, distanceToGround};
import package::clouds_common::{
    clouds, skyViewImage, cloudDensity, cloudPhase, raySphere, bayer4, lightOpticalDepth, finishCloud, EXTINCTION, MAX_DISTANCE_FADE,
};

// Raymarches one slab of clouds between two concentric spheres around the planet. The pass runs at reduced resolution,
// offsets each ray by a per-frame Bayer value, and writes premultiplied radiance with the path transmittance in alpha.
@vertex
fn clouds_march_vertex(@builtin(vertex_index) index: u32) -> FullscreenVertex {
    return fullscreenVertex(index);
}

@fragment
fn clouds_march_fragment(input: FullscreenVertex) -> @location(0) vec4f {
    let ground = atmosphere.planet.x;
    let cameraRadius = ground + max(atmosphere.planet.w, 0.5);
    let origin = vec3f(0.0, cameraRadius, 0.0);
    let ndc = vec2f(input.uv.x * 2.0 - 1.0, 1.0 - input.uv.y * 2.0);
    let viewFar = atmosphere.inverseProjection * vec4f(ndc, 1.0, 1.0);
    let viewRay = normalize(viewFar.xyz / viewFar.w);
    let direction = normalize((atmosphere.inverseView * vec4f(viewRay, 0.0)).xyz);
    // A ray that would reach the ground first only sees clouds that lie in front of it, which is possible from inside or
    // above the layer.
    var groundLimit = 1.0e9;
    if hitsGround(cameraRadius, direction.y) {
        groundLimit = distanceToGround(cameraRadius, direction.y);
    }
    let innerRadius = ground + clouds.layer.x;
    let thickness = clouds.layer.y;
    let outerRadius = innerRadius + thickness;
    let outer = raySphere(origin, direction, outerRadius);
    let inner = raySphere(origin, direction, innerRadius);
    var enter = 0.0;
    var leave = 0.0;
    if cameraRadius < innerRadius {
        enter = inner.y;
        leave = outer.y;
    } else if cameraRadius < outerRadius {
        enter = 0.0;
        leave = select(outer.y, inner.x, inner.x > 0.0);
    } else {
        if outer.x < 0.0 { return vec4f(0.0, 0.0, 0.0, 1.0); }
        enter = outer.x;
        leave = select(outer.y, inner.x, inner.x > 0.0);
    }
    leave = min(leave, groundLimit);
    if leave <= enter || enter < 0.0 || enter > MAX_DISTANCE_FADE * 2.0 {
        return vec4f(0.0, 0.0, 0.0, 1.0);
    }
    leave = min(leave, enter + 30000.0);
    let steps = i32(clouds.wind.z);
    let stepLength = (leave - enter) / f32(steps);
    let jitter = fract(bayer4(input.position.xy) + clouds.frame.x * 0.61803398875);
    let sunDirection = atmosphere.sunDirection.xyz;
    let sunIlluminance = atmosphere.sunIlluminance.rgb;
    let cosine = dot(direction, sunDirection);
    let zenithUV = skyViewDirectionToUv(vec3f(0.0, 1.0, 0.0), cameraRadius);
    let skyAmbient = textureSampleLevel(skyViewImage, linearSampler, zenithUV, 0.0).rgb;
    var transmittance = 1.0;
    var radiance = vec3f(0.0);
    var weighted = 0.0;
    var weights = 0.0;
    for (var index = 0; index < 96; index++) {
        if index >= steps { break; }
        let distance = enter + (f32(index) + jitter) * stepLength;
        let point = origin + direction * distance;
        let radius = length(point);
        let h = (radius - innerRadius) / thickness;
        if h < 0.0 || h > 1.0 { continue; }
        let density = cloudDensity(point, h, true);
        if density <= 0.0 { continue; }
        let sigma = density * EXTINCTION * clouds.shape.y;
        let opticalDepth = lightOpticalDepth(point, sunDirection, i32(clouds.wind.w), innerRadius, thickness);
        var energy = 0.0;
        var attenuation = 1.0;
        var contribution = 1.0;
        var octave = 1.0;
        for (var scatter = 0; scatter < 3; scatter++) {
            energy += contribution * exp(-opticalDepth * attenuation) * cloudPhase(cosine, octave);
            attenuation *= 0.25;
            contribution *= 0.5;
            octave *= 0.5;
        }
        let powder = 1.0 - exp(-sigma * stepLength * 2.0);
        let sun = sunIlluminance * transmittanceToSun(radius, dot(point / radius, sunDirection));
        let direct = sun * (energy * 5.0 * clouds.layer.z * mix(1.0, powder, 0.5));
        let ambient = skyAmbient * (clouds.layer.w * mix(0.4, 0.9, h));
        let stepTransmittance = exp(-sigma * stepLength);
        let absorbed = 1.0 - stepTransmittance;
        radiance += transmittance * (direct + ambient) * absorbed;
        weighted += transmittance * absorbed * distance;
        weights += transmittance * absorbed;
        transmittance *= stepTransmittance;
        if transmittance < 0.01 {
            transmittance = 0.0;
            break;
        }
    }
    let opacity = 1.0 - transmittance;
    if opacity <= 0.0 {
        return vec4f(0.0, 0.0, 0.0, 1.0);
    }
    // Aerial perspective at the cloud's own distance, then a fade so the farthest clouds melt into the horizon.
    return finishCloud(radiance, opacity, weighted / max(weights, 0.000001), enter, input.uv);
}
