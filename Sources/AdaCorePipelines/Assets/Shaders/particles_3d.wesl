import ada_engine::view::view;

// WESL port of particles_3d.glsl. Features: PARTICLE_INDIRECT adds the indirect coverage target (location 1) and
// PARTICLE_REFLECTION_RESPONSE adds the reflection-response target (location 2).

struct SmokeLight {
    positionRange: vec4f,
    radianceIntensity: vec4f,
    directionOuter: vec4f,
    innerShadow: vec4f,
}

struct ParticleLighting {
    u_AmbientCount: vec4f,
    u_SunDirectionIntensity: vec4f,
    u_SunRadiance: vec4f,
    u_SmokeLights: array<SmokeLight, 8>,
    u_ParticleInverseView: mat4x4f,
}

struct ParticleShadowMatrices {
    u_ParticleShadowMatrices: array<mat4x4f, 24>,
    u_ParticleAtlas: vec4f,
}

@group(0) @binding(0) var u_Position: texture_2d<f32>;
@group(0) @binding(1) var u_Sampler: sampler;
@group(0) @binding(4) var<uniform> lighting: ParticleLighting;
@group(0) @binding(5) var<uniform> shadowMatrices: ParticleShadowMatrices;
@group(0) @binding(6) var u_ParticleShadows: texture_2d<f32>;
@group(0) @binding(7) var u_ShadowSampler: sampler;

struct ParticleVertex {
    @builtin(position) position: vec4f,
    @location(0) uv: vec2f,
    @location(1) color: vec4f,
    @location(2) clip: vec4f,
    @location(3) particle: vec3f,
    @location(4) @interpolate(flat) style: f32,
    @location(5) viewPosition: vec3f,
    @location(6) @interpolate(flat) centerSize: vec4f,
}

@vertex
fn particles_vertex(
    @builtin(vertex_index) vertexIndex: u32,
    @location(0) centerSize: vec4f,
    @location(1) color: vec4f,
    @location(2) parameters: vec4f
) -> ParticleVertex {
    var corners = array<vec2f, 6>(
        vec2f(-1.0, -1.0), vec2f(1.0, -1.0), vec2f(1.0, 1.0),
        vec2f(-1.0, -1.0), vec2f(1.0, 1.0), vec2f(-1.0, 1.0)
    );
    let corner = corners[vertexIndex];
    let c = cos(parameters.x);
    let s = sin(parameters.x);
    let shaped = corner * vec2f(parameters.z, 1.0);
    let rotated = vec2f(c * shaped.x - s * shaped.y, s * shaped.x + c * shaped.y);
    let position = centerSize.xyz + vec3f(rotated * centerSize.w * 0.5, 0.0);
    let clip = view.projection * vec4f(position, 1.0);
    return ParticleVertex(
        clip, corner, color, clip, vec3f(centerSize.z, parameters.y, parameters.x), parameters.w, position, centerSize
    );
}

struct ParticleOutput {
    @location(0) color: vec4f,
    @if(PARTICLE_INDIRECT) @location(1) indirect: vec4f,
    @if(PARTICLE_REFLECTION_RESPONSE) @location(2) reflectionResponse: vec4f,
}

fn smokePointFace(ray: vec3f) -> i32 {
    let a = abs(ray);
    if a.x >= a.y && a.x >= a.z {
        return select(1, 0, ray.x >= 0.0);
    }
    if a.y >= a.z {
        return select(3, 2, ray.y >= 0.0);
    }
    return select(5, 4, ray.z >= 0.0);
}

fn smokeShadow(light: SmokeLight, position: vec3f) -> f32 {
    let slot = i32(light.innerShadow.w);
    if slot < 0 || slot >= 4 {
        return 1.0;
    }
    let inverseView = lighting.u_ParticleInverseView;
    let worldRay = mat3x3f(inverseView[0].xyz, inverseView[1].xyz, inverseView[2].xyz) * (position - light.positionRange.xyz);
    var face = 0;
    if light.directionOuter.w < 0.0 {
        face = smokePointFace(worldRay);
    }
    let worldPosition = (inverseView * vec4f(position, 1.0)).xyz;
    let clip = shadowMatrices.u_ParticleShadowMatrices[slot * 6 + face] * vec4f(worldPosition, 1.0);
    if clip.w <= 0.0 {
        return 1.0;
    }
    let ndc = clip.xyz / clip.w;
    if ndc.z < 0.0 || ndc.z > 1.0 || any(abs(ndc.xy) > vec2f(1.0)) {
        return 1.0;
    }
    let atlas = shadowMatrices.u_ParticleAtlas;
    let origin = vec2f(f32(face), f32(slot)) * atlas.z;
    let lo = (origin + vec2f(0.5)) * atlas.xy;
    let hi = (origin + vec2f(atlas.z - 0.5)) * atlas.xy;
    let uv = (origin + (ndc.xy * vec2f(0.5, -0.5) + vec2f(0.5)) * atlas.z) * atlas.xy;
    var visibility = 0.0;
    for (var y = 0; y < 2; y++) {
        for (var x = 0; x < 2; x++) {
            let offset = (vec2f(f32(x), f32(y)) - vec2f(0.5)) * atlas.xy;
            let depth = textureSampleLevel(u_ParticleShadows, u_ShadowSampler, clamp(uv + offset, lo, hi), 0.0).r;
            visibility += select(0.0, 1.0, ndc.z - light.innerShadow.y <= depth);
        }
    }
    return visibility * 0.25;
}

// Three fixed density layers approximate a small cloud. Its shape changes continuously
// with the particle's phase; no texture fetches, per-puff materials or simulation entities.
fn smokeDensity(uv: vec2f, chord: f32, phase: f32) -> f32 {
    var density = 0.0;
    for (var layer = 0; layer < 3; layer++) {
        let p = vec3f(uv, (f32(layer) - 1.0) * chord * 0.66);
        let warped = p + 0.14 * sin(p.yzx * 5.1 + vec3f(phase, 2.1, 4.3));
        let body = max(0.0, 1.0 - dot(warped, warped));
        let lobe = 0.62 + 0.38 * sin(warped.x * 7.0 + phase) * sin(warped.y * 6.0 - phase) * cos(warped.z * 6.0);
        density += body * body * lobe;
    }
    return density * chord;
}

fn smokeLighting(normal: vec3f, position: vec3f) -> vec3f {
    var result = lighting.u_AmbientCount.rgb;
    let sun = lighting.u_SunDirectionIntensity.xyz;
    result += max(lighting.u_SunRadiance.rgb, vec3f(0.0)) * max(0.0, lighting.u_SunDirectionIntensity.w) * 0.12
        * (0.5 + 0.5 * dot(normal, sun));
    for (var i = 0; i < 8; i++) {
        if i >= i32(lighting.u_AmbientCount.w) {
            break;
        }
        let light = lighting.u_SmokeLights[i];
        let delta = light.positionRange.xyz - position;
        let distance = length(delta);
        let range = light.positionRange.w;
        if distance >= range || range <= 0.0 {
            continue;
        }
        let direction = delta / max(distance, 0.0001);
        let ratio = distance / range;
        let cutoff = max(0.0, 1.0 - ratio * ratio * ratio * ratio);
        var attenuation = cutoff * cutoff / max(distance * distance, 0.04);
        if light.directionOuter.w >= 0.0 {
            attenuation *= smoothstep(light.directionOuter.w, light.innerShadow.x, dot(normalize(light.directionOuter.xyz), -direction));
        }
        if attenuation <= 0.0 {
            continue;
        }
        let wrap = 0.4 + 0.6 * max(0.0, dot(normal, direction));
        let forwardScatter = pow(max(0.0, dot(-direction, normalize(-position))), 4.0);
        result += max(light.radianceIntensity.rgb, vec3f(0.0)) * max(0.0, light.radianceIntensity.w) * attenuation
            * 0.08 * (wrap + forwardScatter) * smokeShadow(light, position);
    }
    return result;
}

// Reflections are composed later. Their opaque contribution must obey the same
// transmittance as sceneColor or it would shine through a dense cloud.
fn particleOutput(color: vec4f, alpha: f32) -> ParticleOutput {
    var result: ParticleOutput;
    result.color = color;
    @if(PARTICLE_INDIRECT) result.indirect = vec4f(0.0, 0.0, 0.0, alpha);
    @if(PARTICLE_REFLECTION_RESPONSE) result.reflectionResponse = vec4f(0.0, 0.0, 0.0, alpha);
    return result;
}

@fragment
fn particles_fragment(input: ParticleVertex) -> ParticleOutput {
    let radius = dot(input.uv, input.uv);
    if radius >= 1.0 {
        discard;
    }
    let screenUV = input.clip.xy / input.clip.w * vec2f(0.5, -0.5) + vec2f(0.5);
    let scene = textureSampleLevel(u_Position, u_Sampler, screenUV, 0.0).xyz;
    let sceneDepth = select(scene.z, 100000.0, length(scene) < 0.0001);
    let intersection = clamp((sceneDepth - input.particle.x) / input.particle.y, 0.0, 1.0);
    let nearFade = smoothstep(0.05, 0.3, input.particle.x);
    if input.style > 2.5 {
        let chord = sqrt(max(0.0, 1.0 - radius));
        let density = smokeDensity(input.uv, chord, input.particle.z);
        let alpha = (1.0 - exp(-density * input.color.a * 2.0)) * intersection * nearFade;
        if alpha < 0.0001 {
            discard;
        }
        // A rounded view-space normal gives each density lobe a lit and an extinct side.
        let normal = normalize(vec3f(
            (input.viewPosition.xy - input.centerSize.xy) / max(input.centerSize.w * 0.5, 0.0001),
            -chord
        ));
        let position = input.viewPosition + vec3f(0.0, 0.0, -chord * input.centerSize.w * 0.25);
        return particleOutput(vec4f(input.color.rgb * smokeLighting(normal, position), alpha), alpha);
    }
    // Smooth procedural lobes keep smoke soft and remove the need for a texture asset.
    let detail = select(
        0.78 + 0.22 * sin(input.uv.x * 6.0 + input.particle.z) * cos(input.uv.y * 5.0 - input.particle.z),
        1.0,
        input.style > 0.5
    );
    let alpha = input.color.a * (1.0 - radius) * (1.0 - radius) * detail * intersection * nearFade;
    return particleOutput(vec4f(input.color.rgb, alpha), alpha);
}
