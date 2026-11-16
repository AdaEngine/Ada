import package::fullscreen::{FullscreenVertex, fullscreenVertex};
import package::atmosphere_common::{atmosphere, sampleMedium, transmittanceToSun, hitsGround, distanceToGround, distanceToTop, PI, MULTI_SCATTER_SIZE, unitFromSubUv};

@vertex
fn atmosphere_multiscatter_vertex(@builtin(vertex_index) index: u32) -> FullscreenVertex {
    return fullscreenVertex(index);
}

fn sphereDirection(index: i32, count: f32) -> vec3f {
    let z = 1.0 - 2.0 * (f32(index) + 0.5) / count;
    let ring = sqrt(max(1.0 - z * z, 0.0));
    let phi = 2.39996323 * f32(index);
    return vec3f(ring * cos(phi), z, ring * sin(phi));
}

// Isotropic multiple-scattering transfer (Hillaire 2020): the geometric series of bounces sums to L / (1 - f).
@fragment
fn atmosphere_multiscatter_fragment(input: FullscreenVertex) -> @location(0) vec4f {
    let unit = unitFromSubUv(input.uv, MULTI_SCATTER_SIZE);
    let muSun = unit.x * 2.0 - 1.0;
    let ground = atmosphere.planet.x;
    let r = clamp(ground + unit.y * (atmosphere.planet.y - ground), ground + 0.01, atmosphere.planet.y - 0.01);
    let origin = vec3f(0.0, r, 0.0);
    let sunDirection = vec3f(sqrt(max(1.0 - muSun * muSun, 0.0)), muSun, 0.0);
    let stepCount = i32(atmosphere.steps.w);
    let rayCount = 64;
    let solidAngle = 4.0 * PI / f32(rayCount);
    let isotropic = 1.0 / (4.0 * PI);
    var radianceSum = vec3f(0.0);
    var transferSum = vec3f(0.0);
    for (var ray = 0; ray < rayCount; ray++) {
        let direction = sphereDirection(ray, f32(rayCount));
        let mu = direction.y;
        let touchesGround = hitsGround(r, mu);
        let maxDistance = select(distanceToTop(r, mu), distanceToGround(r, mu), touchesGround);
        let stepLength = maxDistance / f32(stepCount);
        var throughput = vec3f(1.0);
        var radiance = vec3f(0.0);
        var transfer = vec3f(0.0);
        for (var index = 0; index < 32; index++) {
            if index >= stepCount { break; }
            let travel = (f32(index) + 0.5) * stepLength;
            let position = origin + direction * travel;
            let radius = length(position);
            let medium = sampleMedium(radius - ground);
            let sunVisibility = transmittanceToSun(radius, dot(position / radius, sunDirection));
            let stepTransmittance = exp(-medium.extinction * stepLength);
            let extinction = max(medium.extinction, vec3f(0.000001));
            let source = sunVisibility * medium.scattering * isotropic;
            radiance += throughput * (source - source * stepTransmittance) / extinction;
            let scatterOnly = medium.scattering;
            transfer += throughput * (scatterOnly - scatterOnly * stepTransmittance) / extinction;
            throughput *= stepTransmittance;
        }
        if touchesGround {
            let hit = origin + direction * maxDistance;
            let normal = hit / length(hit);
            let muGround = dot(normal, sunDirection);
            radiance += throughput * transmittanceToSun(ground, muGround) * max(muGround, 0.0) * atmosphere.planet.z / PI;
        }
        radianceSum += radiance * solidAngle;
        transferSum += transfer * solidAngle * isotropic;
    }
    let series = 1.0 / (vec3f(1.0) - min(transferSum, vec3f(0.99)));
    return vec4f(radianceSum * series, 1.0);
}
