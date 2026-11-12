import ada_engine::view::projectPosition;

// WESL port of mobile_voice_orb.glsl, itself ported from Sloppy Desktop Companion's DesktopOrb.metal.
// Keep the volume, ribbons, palette, bloom and edge fade identical to the companion Bubble.

struct MobileVoiceOrbMaterial {
    u_Geometry: vec4f,
    u_Style: vec4f,
}

struct OrbVertex {
    @builtin(position) position: vec4f,
    @location(0) color: vec4f,
    @location(1) uv: vec2f,
}

@group(0) @binding(0) var<uniform> material: MobileVoiceOrbMaterial;

@vertex
fn mobile_voice_orb_vertex(@location(0) position: vec4f, @location(1) color: vec4f, @location(2) uv: vec2f) -> OrbVertex {
    return OrbVertex(projectPosition(position), color, uv);
}

fn orbHash(point: vec3f) -> f32 {
    var p = fract(point * 0.3183099 + vec3f(0.17, 0.31, 0.53));
    p = p * 17.0;
    return fract(p.x * p.y * p.z * (p.x + p.y + p.z));
}

fn orbNoise(p: vec3f) -> f32 {
    let i = floor(p);
    var f = fract(p);
    f = f * f * (vec3f(3.0) - 2.0 * f);
    return mix(
        mix(
            mix(orbHash(i), orbHash(i + vec3f(1.0, 0.0, 0.0)), f.x),
            mix(orbHash(i + vec3f(0.0, 1.0, 0.0)), orbHash(i + vec3f(1.0, 1.0, 0.0)), f.x),
            f.y
        ),
        mix(
            mix(orbHash(i + vec3f(0.0, 0.0, 1.0)), orbHash(i + vec3f(1.0, 0.0, 1.0)), f.x),
            mix(orbHash(i + vec3f(0.0, 1.0, 1.0)), orbHash(i + vec3f(1.0, 1.0, 1.0)), f.x),
            f.y
        ),
        f.z
    );
}

fn orbRotate(p: vec2f, a: f32) -> vec2f {
    let c = cos(a);
    let s = sin(a);
    return vec2f(c * p.x + s * p.y, -s * p.x + c * p.y);
}

fn mobileVoiceOrb(coordinates: vec2f, resolution: vec2f, time: f32, level: f32) -> vec4f {
    let uv = (coordinates - 0.5 * resolution) / min(resolution.x, resolution.y) * 2.0;
    let t = time * 0.23;
    let breath = 1.0 + 0.025 * sin(time * 0.8) + level * 0.105 + level * 0.045;
    let q = uv / (0.70 * breath);
    let r = length(q);
    var light = vec3f(0.0);
    let a = atan2(q.y, q.x);
    let haloOuter = (r - 0.94) / 0.24;
    let halo = exp(-pow(r / 1.03, 4.0)) * 0.09 + exp(-(haloOuter * haloOuter)) * 0.13;
    let haloColor = mix(vec3f(0.20, 0.35, 0.75), vec3f(0.64, 0.54, 0.77), 0.5 + 0.5 * sin(a * 2.0 - t));
    light = light + haloColor * halo;
    // Integrate luminous flowing ribbons through a soft spherical volume.
    let depth = sqrt(max(0.0, 1.12 - r * r));
    for (var i = 0; i < 20; i++) {
        let z = (-1.0 + 2.0 * (f32(i) + 0.5) / 20.0) * depth;
        var p = vec3f(q, z);
        let rotatedXZ = orbRotate(vec2f(p.x, p.z), t * 0.37);
        p = vec3f(rotatedXZ.x, p.y, rotatedXZ.y);
        let rotatedXY = orbRotate(vec2f(p.x, p.y), t * 0.20);
        p = vec3f(rotatedXY.x, rotatedXY.y, p.z);
        let radius = length(p);
        let n = orbNoise(p * 2.9 + vec3f(t * 0.55, -t * 0.38, t * 0.25));
        let n2 = orbNoise(p * 5.6 - vec3f(t * 0.2, t * 0.45, 0.0));
        let angle = atan2(p.y, p.x);
        let flow = angle * 4.0 + p.z * 3.2 + radius * 2.8 - t * 1.35 + (n - 0.5) * 4.2;
        let ribbon = pow(0.5 + 0.5 * sin(flow), 5.0);
        let secondary = pow(0.5 + 0.5 * sin(angle * 3.0 - p.z * 4.5 - t * 0.8 + n2 * 3.0), 9.0);
        let envelope = 1.0 - smoothstep(0.72, 1.08 + (n - 0.5) * 0.09, radius);
        let cloud = 0.22 + 0.78 * n;
        let density = (ribbon * 0.92 + secondary * 0.32 + 0.12) * envelope * cloud;
        let hue = 0.5 + 0.5 * sin(flow * 0.45 + p.z * 2.0 + t * 0.7 + n * 3.0);
        let blue = vec3f(0.055, 0.25, 0.96);
        let cyan = vec3f(0.16, 0.88, 1.02);
        let pearl = vec3f(0.87, 0.77, 0.96);
        var color = mix(blue, cyan, smoothstep(0.15, 0.76, hue));
        color = mix(color, pearl, pow(0.5 + 0.5 * sin(p.y * 3.0 + p.z * 2.0 + t * 0.9 + n2 * 2.0), 6.0) * 0.75);
        color = mix(color, vec3f(0.58, 0.38, 1.0), level * 0.23);
        light = light + color * density * depth * 0.13 * (1.0 + level * 0.95 + level * 0.35);
    }
    // A diffuse luminous core and optical bloom, without a hard silhouette.
    let core = exp(-r * r * 15.0) * (0.27 + 0.09 * sin(t * 2.0) + level * 0.2);
    light = light + vec3f(0.39, 0.75, 1.0) * core;
    let veil = exp(-pow(r / 0.86, 6.0)) * 0.12;
    light = light + vec3f(0.10, 0.24, 0.72) * veil;
    let beamAngle = a + t * 0.6 + 0.45 * sin(r * 3.0 - t) + 0.22 * sin(a * 3.0 + t);
    let beams = pow(0.5 + 0.5 * sin(beamAngle * 5.0), 4.0);
    light = light + vec3f(0.18, 0.66, 0.91) * beams * exp(-r * r * 2.8) * (1.0 - smoothstep(0.8, 1.1, r)) * 0.31;
    light = vec3f(1.0) - exp(-light * 3.4);
    let grain = (orbHash(vec3f(coordinates, 7.0)) - 0.5) * 0.018;
    light = max(vec3f(0.0), light + vec3f(grain * min(1.0, halo * 3.0 + length(light))));
    let alpha = clamp(max(max(light.r, light.g), light.b) * 1.3, 0.0, 1.0);
    // Fade both premultiplied color and alpha before reaching the canvas/ring edge.
    let edgeFade = 1.0 - smoothstep(0.68, 1.0, length(uv));
    return vec4f(light, alpha) * edgeFade;
}

@fragment
fn mobile_voice_orb_fragment(input: OrbVertex) -> @location(0) vec4f {
    let size = material.u_Geometry.xy;
    return mobileVoiceOrb(
        vec2f(input.uv.x, 1.0 - input.uv.y) * size,
        size, material.u_Geometry.z, material.u_Geometry.w
    ) * material.u_Style.x;
}
