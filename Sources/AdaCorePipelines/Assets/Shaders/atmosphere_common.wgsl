// Shared ABI and math of the procedural atmosphere passes (Hillaire 2020). Lengths are meters; the planet
// centre sits at the origin and the camera at (0, groundRadius + altitude, 0), so world +Y is "up".
struct Atmosphere3DUniform {
    inverseView: mat4x4f,
    inverseProjection: mat4x4f,
    // xyz: unit vector toward the sun.
    sunDirection: vec4f,
    // rgb: sun illuminance, already multiplied by the atmosphere intensity.
    sunIlluminance: vec4f,
    // rgb: Rayleigh scattering per meter; w: scale height.
    rayleigh: vec4f,
    // x: Mie scattering, y: Mie extinction, z: scale height, w: phase anisotropy.
    mie: vec4f,
    // rgb: ozone absorption per meter.
    ozone: vec4f,
    // x: ground radius, y: top radius, z: ground albedo, w: camera altitude.
    planet: vec4f,
    // x: aerial-perspective range, y: scale, z: depth slice count, w: slice width and height in texels.
    aerial: vec4f,
    // x: transmittance steps, y: sky-view steps, z: aerial steps, w: multiple-scattering steps.
    steps: vec4f,
    // xy: sky-view table size, zw: transmittance table size, in texels.
    tables: vec4f,
}

@group(0) @binding(0) var transmittanceImage: texture_2d<f32>;
@group(0) @binding(1) var multiScatterImage: texture_2d<f32>;
@group(0) @binding(2) var linearSampler: sampler;
@group(0) @binding(4) var<uniform> atmosphere: Atmosphere3DUniform;

const PI = 3.14159265359;
const MULTI_SCATTER_SIZE = vec2f(32.0, 32.0);

fn skyViewSize() -> vec2f {
    return atmosphere.tables.xy;
}

fn transmittanceSize() -> vec2f {
    return atmosphere.tables.zw;
}

struct Medium {
    scattering: vec3f,
    extinction: vec3f,
    rayleighScattering: vec3f,
    mieScattering: f32,
}

fn sampleMedium(height: f32) -> Medium {
    let rayleighDensity = exp(-max(height, 0.0) / atmosphere.rayleigh.w);
    let mieDensity = exp(-max(height, 0.0) / atmosphere.mie.z);
    let ozoneDensity = max(0.0, 1.0 - abs(height - 25000.0) / 15000.0);
    let rayleighScattering = atmosphere.rayleigh.rgb * rayleighDensity;
    let mieScattering = atmosphere.mie.x * mieDensity;
    let extinction = rayleighScattering + vec3f(atmosphere.mie.y * mieDensity) + atmosphere.ozone.rgb * ozoneDensity;
    return Medium(rayleighScattering + vec3f(mieScattering), extinction, rayleighScattering, mieScattering);
}

fn rayleighPhase(cosine: f32) -> f32 {
    return 3.0 / (16.0 * PI) * (1.0 + cosine * cosine);
}

fn miePhase(cosine: f32) -> f32 {
    let g = atmosphere.mie.w;
    let denominator = 1.0 + g * g - 2.0 * g * cosine;
    return (1.0 - g * g) / (4.0 * PI * pow(max(denominator, 0.0001), 1.5));
}

// Discriminant of a ray from radius `r` with zenith cosine `mu` against the sphere of radius `radius`.
fn rayDiscriminant(r: f32, mu: f32, radius: f32) -> f32 {
    return r * r * (mu * mu - 1.0) + radius * radius;
}

fn distanceToTop(r: f32, mu: f32) -> f32 {
    let top = atmosphere.planet.y;
    return max(0.0, -r * mu + sqrt(max(rayDiscriminant(r, mu, top), 0.0)));
}

fn hitsGround(r: f32, mu: f32) -> bool {
    return mu < 0.0 && rayDiscriminant(r, mu, atmosphere.planet.x) >= 0.0;
}

fn distanceToGround(r: f32, mu: f32) -> f32 {
    return max(0.0, -r * mu - sqrt(max(rayDiscriminant(r, mu, atmosphere.planet.x), 0.0)));
}

fn subUv(unit: vec2f, size: vec2f) -> vec2f {
    return (unit * (size - 1.0) + 0.5) / size;
}

fn unitFromSubUv(uv: vec2f, size: vec2f) -> vec2f {
    return clamp((uv - 0.5 / size) * size / (size - 1.0), vec2f(0.0), vec2f(1.0));
}

// Transmittance table: x spans the distance to the top of the atmosphere, y the radius.
fn transmittanceUvToParams(uv: vec2f) -> vec2f {
    let unit = unitFromSubUv(uv, transmittanceSize());
    let top = atmosphere.planet.y;
    let ground = atmosphere.planet.x;
    let horizon = sqrt(max(top * top - ground * ground, 0.0));
    let rho = horizon * unit.y;
    let r = sqrt(rho * rho + ground * ground);
    let dMin = top - r;
    let dMax = rho + horizon;
    let d = dMin + unit.x * (dMax - dMin);
    let mu = select((horizon * horizon - rho * rho - d * d) / (2.0 * r * d), 1.0, d < 0.001);
    return vec2f(r, clamp(mu, -1.0, 1.0));
}

fn transmittanceParamsToUv(r: f32, mu: f32) -> vec2f {
    let top = atmosphere.planet.y;
    let ground = atmosphere.planet.x;
    let horizon = sqrt(max(top * top - ground * ground, 0.0));
    let rho = sqrt(max(r * r - ground * ground, 0.0));
    let d = distanceToTop(r, mu);
    let dMin = top - r;
    let dMax = rho + horizon;
    return subUv(vec2f(clamp((d - dMin) / max(dMax - dMin, 0.001), 0.0, 1.0), clamp(rho / horizon, 0.0, 1.0)), transmittanceSize());
}

fn transmittanceToTop(r: f32, mu: f32) -> vec3f {
    return textureSampleLevel(transmittanceImage, linearSampler, transmittanceParamsToUv(r, mu), 0.0).rgb;
}

fn transmittanceToSun(r: f32, muSun: f32) -> vec3f {
    return select(transmittanceToTop(r, muSun), vec3f(0.0), hitsGround(r, muSun));
}

fn multiScatterUv(r: f32, muSun: f32) -> vec2f {
    let height = clamp((r - atmosphere.planet.x) / (atmosphere.planet.y - atmosphere.planet.x), 0.0, 1.0);
    return subUv(vec2f(clamp(muSun * 0.5 + 0.5, 0.0, 1.0), height), MULTI_SCATTER_SIZE);
}

fn multiScatter(r: f32, muSun: f32) -> vec3f {
    return textureSampleLevel(multiScatterImage, linearSampler, multiScatterUv(r, muSun), 0.0).rgb;
}

// The sun's horizontal direction; sky-view azimuth is measured from it.
fn sunHorizontal() -> vec2f {
    let horizontal = atmosphere.sunDirection.xz;
    let length2 = dot(horizontal, horizontal);
    return select(vec2f(1.0, 0.0), horizontal * inverseSqrt(max(length2, 0.000001)), length2 > 0.000001);
}

// x: zenith angle of the horizon, y: angle between the horizon and straight down.
fn skyViewHorizonAngles(r: f32) -> vec2f {
    let ground = atmosphere.planet.x;
    let beta = acos(clamp(sqrt(max(r * r - ground * ground, 0.0)) / r, 0.0, 1.0));
    return vec2f(PI - beta, beta);
}

fn skyViewUvToDirection(uv: vec2f, r: f32) -> vec3f {
    let unit = unitFromSubUv(uv, skyViewSize());
    let angles = skyViewHorizonAngles(r);
    var mu: f32;
    if unit.y < 0.5 {
        let mirrored = 1.0 - 2.0 * unit.y;
        mu = cos(angles.x * (1.0 - mirrored * mirrored));
    } else {
        let coord = unit.y * 2.0 - 1.0;
        mu = cos(angles.x + angles.y * coord * coord);
    }
    let azimuth = PI * unit.x * unit.x;
    let sunH = sunHorizontal();
    let side = vec2f(-sunH.y, sunH.x);
    let sine = sqrt(max(1.0 - mu * mu, 0.0));
    let horizontal = sine * (cos(azimuth) * sunH + sin(azimuth) * side);
    return vec3f(horizontal.x, mu, horizontal.y);
}

fn skyViewDirectionToUv(direction: vec3f, r: f32) -> vec2f {
    let angles = skyViewHorizonAngles(r);
    let zenith = acos(clamp(direction.y, -1.0, 1.0));
    var y: f32;
    if zenith < angles.x {
        y = 0.5 * (1.0 - sqrt(max(1.0 - zenith / max(angles.x, 0.0001), 0.0)));
    } else {
        y = 0.5 + 0.5 * sqrt(max((zenith - angles.x) / max(angles.y, 0.0001), 0.0));
    }
    let horizontal = direction.xz;
    let length2 = dot(horizontal, horizontal);
    let planar = select(sunHorizontal(), horizontal * inverseSqrt(max(length2, 0.000001)), length2 > 0.000001);
    let azimuth = acos(clamp(dot(planar, sunHorizontal()), -1.0, 1.0));
    return subUv(vec2f(sqrt(azimuth / PI), clamp(y, 0.0, 1.0)), skyViewSize());
}

struct Scattering {
    luminance: vec3f,
    throughput: vec3f,
}

// Single scattering plus the multiple-scattering approximation along a ray: the luminance that reaches the origin
// and the per-channel transmittance of the path. `groundBounce` adds the lit planet when the ray ends on it.
fn integrateScattering(origin: vec3f, direction: vec3f, maxDistance: f32, stepCount: i32, groundBounce: bool) -> Scattering {
    let sunDirection = atmosphere.sunDirection.xyz;
    let sunIlluminance = atmosphere.sunIlluminance.rgb;
    let phaseCosine = dot(direction, sunDirection);
    let rayleighPhaseValue = rayleighPhase(phaseCosine);
    let miePhaseValue = miePhase(phaseCosine);
    let stepLength = maxDistance / f32(stepCount);
    var luminance = vec3f(0.0);
    var throughput = vec3f(1.0);
    for (var index = 0; index < 64; index++) {
        if index >= stepCount { break; }
        let travel = (f32(index) + 0.5) * stepLength;
        let position = origin + direction * travel;
        let r = length(position);
        let medium = sampleMedium(r - atmosphere.planet.x);
        let muSun = dot(position / r, sunDirection);
        let sunVisibility = transmittanceToSun(r, muSun);
        let scattered = sunVisibility * (medium.rayleighScattering * rayleighPhaseValue + vec3f(medium.mieScattering * miePhaseValue))
            + multiScatter(r, muSun) * medium.scattering;
        let source = sunIlluminance * scattered;
        let stepTransmittance = exp(-medium.extinction * stepLength);
        luminance += throughput * (source - source * stepTransmittance) / max(medium.extinction, vec3f(0.000001));
        throughput *= stepTransmittance;
    }
    if groundBounce {
        let hit = origin + direction * maxDistance;
        let normal = hit / length(hit);
        let muSun = dot(normal, sunDirection);
        let sunVisibility = transmittanceToSun(atmosphere.planet.x, muSun);
        luminance += throughput * sunIlluminance * sunVisibility * max(muSun, 0.0) * atmosphere.planet.z / PI;
    }
    return Scattering(luminance, throughput);
}
