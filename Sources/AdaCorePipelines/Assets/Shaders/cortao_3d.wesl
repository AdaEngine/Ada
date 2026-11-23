// CORTAO: Circular Occluder Ray-Traced Ambient Occlusion.
//
// Adapted from https://github.com/theagentd/CORTAO
// Copyright (c) 2026 Daniel Isheden, MIT License. See CORTAO-LICENSE.txt.
//
// Differences from the reference implementation:
//  * The packed R32_UINT mip chain is replaced by an RGBA16F texture with four mips holding (view depth,
//    spheremap normal.xy), built by the compute shader in cortao_pyramid_3d. This pass is a fragment shader.
//  * The occluder look-up table is a 24 x 24 x 16 table generated at run time (CortaoOccluderTable.swift), stored as
//    an R32Float texture with the radius slices side by side.
//  * The bent normal (average unoccluded ray direction) is summed directly from the ray table instead of the
//    reference look-up table. The composite pass uses it for diffuse image-based light and specular occlusion.
//  * The random seed changes every frame when temporal accumulation is on (cortao_temporal_3d accumulates the result).
//  * The sampling disk is the screen projection of the AO sphere (no tangent-plane stretch).
import package::cortao_common::{cortaoDecodeNormal, cortaoHash, cortaoOctEncode, cortaoSeed};
import package::fullscreen::{FullscreenVertex, fullscreenVertex};

struct CortaoUniform {
    projection: mat4x4f,
    // radius, intensity, sampleCount, maxScreenspaceRadiusHeightRatio
    parameters: vec4f,
    // bias (world-space normal offset), frame seed, write bent normal (0 or 1), unused
    passParameters: vec4f,
}

// (view depth, spheremap normal.xy) with one mip per pyramid level, built by cortao_pyramid_3d.
@group(0) @binding(0) var pyramid: texture_2d<f32>;
// Ray hit masks addressed by occluder direction and radius.
@group(0) @binding(1) var occluderTable: texture_2d<f32>;
@group(0) @binding(4) var<uniform> cortao: CortaoUniform;

const RAY_COUNT: u32 = 16u;
const TABLE_DIRECTIONS: i32 = 24;
const TABLE_RADII: i32 = 16;
const MAX_SAMPLES: i32 = 32;
const MAX_LEVEL: i32 = 3;
const GOLDEN_ANGLE: f32 = 2.3999632;
const TWO_PI: f32 = 6.2831853;
const MIP_BIAS: f32 = -4.0;
const MAX_SLOPE_COMPENSATION: f32 = 4.0;
const BACKFACE_THRESHOLD: f32 = 0.5;

// Hemisphere ray directions in tangent space (golden-angle spiral, cosine weighted). They match
// CortaoOccluderTable.rayDirection, which the ray masks are generated from.
const RAY_DIRECTIONS = array<vec3f, 16>(
    vec3f(0.176777, 0.000000, 0.984251),
    vec3f(-0.225772, 0.206826, 0.951972),
    vec3f(0.034558, -0.393771, 0.918559),
    vec3f(0.284571, 0.371173, 0.883883),
    vec3f(-0.522223, -0.092374, 0.847791),
    vec3f(0.494695, -0.314685, 0.810093),
    vec3f(-0.165466, 0.615525, 0.770552),
    vec3f(-0.315562, -0.607594, 0.728869),
    vec3f(0.684642, 0.250030, 0.684653),
    vec3f(-0.712256, 0.294009, 0.637377),
    vec3f(0.343354, -0.733729, 0.586302),
    vec3f(0.253731, 0.808932, 0.530330),
    vec3f(-0.764746, -0.443186, 0.467707),
    vec3f(0.897134, -0.197233, 0.395285),
    vec3f(-0.547507, 0.778772, 0.306186),
    vec3f(-0.126487, -0.976090, 0.176777),
);
const NORMAL_OFFSET_RADIUS_FRACTION: f32 = 0.08;

@vertex
fn cortao_vertex(@builtin(vertex_index) index: u32) -> FullscreenVertex {
    return fullscreenVertex(index);
}

fn unproject(uv: vec2f, depth: f32) -> vec3f {
    let ndc = vec2f(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0);
    let p = cortao.projection;
    return vec3f(depth * (ndc.x - p[2][0]) / p[0][0], depth * (ndc.y - p[2][1]) / p[1][1], depth);
}

struct Texel {
    value: vec4f,
    // Centre of the full-resolution pixel the texel was taken from, in screen UV. Positions are unprojected from here,
    // not from the query point, so a sample never lands between pixels and flat surfaces do not occlude themselves.
    uv: vec2f,
}

fn fetchLevel(level: i32, uv: vec2f) -> Texel {
    let size = vec2i(textureDimensions(pyramid, level));
    let pixel = clamp(vec2i(uv * vec2f(size)), vec2i(0), size - vec2i(1));
    let value = textureLoad(pyramid, pixel, level);
    // Level texels come from one pixel of a 16x16 tile (value.w); unproject from that exact pixel.
    let tileOrigin = ((pixel << vec2u(u32(level))) >> vec2u(4u)) << vec2u(4u);
    let index = u32(value.w);
    let source = tileOrigin + vec2i(i32(index & 15u), i32(index >> 4u));
    return Texel(value, (vec2f(source) + 0.5) / vec2f(textureDimensions(pyramid, 0)));
}

struct Frame {
    tangent: vec3f,
    bitangent: vec3f,
}

// Duff et al. orthonormal basis, rotated around the normal.
fn tangentFrame(n: vec3f, rotation: f32) -> Frame {
    let s = select(-1.0, 1.0, n.z >= 0.0);
    let a = -1.0 / (s + n.z);
    let b = n.x * n.y * a;
    let t = vec3f(1.0 + s * n.x * n.x * a, s * b, -s * n.x);
    let bt = vec3f(b, s + n.y * n.y * a, -n.y);
    let c = cos(rotation);
    let sn = sin(rotation);
    return Frame(t * c + bt * sn, bt * c - t * sn);
}

// Bits of the rays an occluder blocks, from the pre-tabulated cones.
fn occluderMask(hemisphere: vec3f, occluderRadius: f32) -> u32 {
    let spheremap = hemisphere.xy * inverseSqrt(hemisphere.z * 8.0 + 8.0) + vec2f(0.5);
    let x = clamp(i32(spheremap.x * f32(TABLE_DIRECTIONS)), 0, TABLE_DIRECTIONS - 1);
    let y = clamp(i32(spheremap.y * f32(TABLE_DIRECTIONS)), 0, TABLE_DIRECTIONS - 1);
    let slice = clamp(i32(occluderRadius * 0.70710678 * f32(TABLE_RADII)), 0, TABLE_RADII - 1);
    return u32(textureLoad(occluderTable, vec2i(x + TABLE_DIRECTIONS * slice, y), 0).x);
}

// x = visibility, yzw = bent normal in view space.
fn occlusion(uv: vec2f, pixel: vec2u) -> vec4f {
    let maxLevel = min(i32(textureNumLevels(pyramid)) - 1, MAX_LEVEL);
    let centerTexel = fetchLevel(0, uv);
    let center = centerTexel.value;
    let depth = center.x;
    if depth <= 0.0 {
        return vec4f(1.0, 0.0, 0.0, -1.0);
    }
    let p = cortao.projection;
    let fullSize = vec2f(textureDimensions(pyramid, 0));
    let normal = cortaoDecodeNormal(center.yz);
    var viewPosition = unproject(centerTexel.uv, depth);

    // World radius, clamped so the sampling disk never exceeds a fraction of the screen height.
    let m = cortao.parameters.w * 2.0 / p[1][1];
    let coefficient = m / sqrt(m * m + 1.0);
    let clampedRadius = min(cortao.parameters.x, depth * coefficient);
    let apparentRadius = clampedRadius / sqrt(depth * depth - clampedRadius * clampedRadius);
    let maxRadius = apparentRadius * depth;
    let viewDirection = -normalize(viewPosition);
    let stretchFactor = inverseSqrt(max(abs(viewDirection.z), 0.05));
    let baseMip = log2(max(apparentRadius * stretchFactor, 0.00001)) + log2(p[1][1] * fullSize.y * 0.5) + MIP_BIAS;

    // Lifting the centre along its normal keeps flat and tessellated surfaces from occluding themselves: tessellation
    // makes neighbouring facets rise above the plane of an interpolated normal. The offset is one pixel plus the user
    // bias plus a fraction of the radius.
    let pixelSize = 2.0 / (p[0][0] * fullSize.x) * 1.4142135 * depth;
    viewPosition += normal * (pixelSize + cortao.passParameters.x + NORMAL_OFFSET_RADIUS_FRACTION * maxRadius);

    let frameSeed = u32(cortao.passParameters.y) * 0x9E3779B1u;
    let random = cortaoHash(cortaoSeed(pixel) + frameSeed);
    let sampleRotation = f32(random & 0xFFFFu) / 65535.0 * TWO_PI;
    let offsetDither = f32((random >> 16u) & 0xFFFFu) / 65535.0;
    let random2 = cortaoHash(random + 0x9E3779B9u);
    let frame = tangentFrame(normal, f32(random2 & 0xFFFFu) / 65535.0 * TWO_PI);
    let mirror = select(1.0, -1.0, ((random2 >> 16u) & 1u) == 1u);

    let sampleCount = clamp(i32(cortao.parameters.z), 4, MAX_SAMPLES);
    let inverseCount = 1.0 / f32(sampleCount);
    let uvScale = apparentRadius * vec2f(p[0][0], p[1][1]) * 0.5;
    var rayBits = 0u;
    for (var i = 0; i < MAX_SAMPLES; i++) {
        if i >= sampleCount {
            break;
        }
        let angle = f32(i) * GOLDEN_ANGLE + sampleRotation;
        let spiral = vec2f(cos(angle), sin(angle) * mirror);
        let innerRadius = pow(f32(i) * inverseCount, 1.75);
        let outerRadius = pow((f32(i) + 1.0) * inverseCount, 1.75);
        let sampleWeight = sqrt(outerRadius * outerRadius - innerRadius * innerRadius);
        let radial = mix(innerRadius, outerRadius, offsetDither);
        let sampleUV = uv + spiral * radial * uvScale;
        if any(sampleUV < vec2f(0.0)) || any(sampleUV >= vec2f(1.0)) {
            continue;
        }
        let level = clamp(i32(floor(baseMip + log2(max(outerRadius, 0.00001)) + 0.5)), 0, maxLevel);
        let occluder = fetchLevel(level, sampleUV);
        let occluderTexel = occluder.value;
        if occluderTexel.x <= 0.0 {
            continue;
        }
        let delta = unproject(occluder.uv, occluderTexel.x) - viewPosition;
        let lengthSquared = dot(delta, delta);
        if lengthSquared >= maxRadius * maxRadius || dot(delta, normal) <= 0.0 {
            continue;
        }
        let inverseLength = inverseSqrt(lengthSquared);
        var direction = delta * inverseLength;
        let sampleNormal = cortaoDecodeNormal(occluderTexel.yz);
        let slope = inverseSqrt(max(dot(sampleNormal, viewDirection), 1.0 / MAX_SLOPE_COMPENSATION));
        let occluderRadius = maxRadius * sampleWeight * slope * inverseLength;
        if dot(sampleNormal, direction) < BACKFACE_THRESHOLD {
            let offset = -occluderRadius / max(1.0 - occluderRadius * occluderRadius * 0.5, 0.000001);
            direction = normalize(sampleNormal * offset + direction);
        }
        let hemisphere = vec3f(dot(direction, frame.tangent), dot(direction, frame.bitangent), dot(direction, normal));
        if hemisphere.z <= -0.99 {
            continue;
        }
        rayBits |= occluderMask(hemisphere, occluderRadius);
    }
    let visibility = 1.0 - f32(countOneBits(rayBits)) / f32(RAY_COUNT);

    // Average direction of the rays that reach open space. Fully blocked pixels keep the surface normal, and the
    // result is kept above the surface so silhouettes cannot bend it below the horizon.
    var directions = RAY_DIRECTIONS;
    var open = vec3f(0.0);
    for (var j = 0u; j < RAY_COUNT; j++) {
        if ((rayBits >> j) & 1u) == 0u {
            open += directions[j];
        }
    }
    var bent = vec3f(0.0, 0.0, 1.0);
    if dot(open, open) > 0.0001 {
        bent = normalize(open);
        bent.z = max(bent.z, 0.05);
        bent = normalize(bent);
    }
    return vec4f(visibility, frame.tangent * bent.x + frame.bitangent * bent.y + normal * bent.z);
}

@fragment
fn cortao_fragment(input: FullscreenVertex) -> @location(0) vec4f {
    let result = occlusion(input.uv, vec2u(input.position.xy));
    let visibility = clamp(1.0 - (1.0 - result.x) * cortao.parameters.y, 0.1, 1.0);
    if cortao.passParameters.z > 0.5 {
        // r = visibility, gb = bent normal (octahedral, 0...1). Consumers know from the environment uniform that it is there.
        return vec4f(visibility, cortaoOctEncode(result.yzw) * 0.5 + vec2f(0.5), 1.0);
    }
    return vec4f(vec3f(visibility), 1.0);
}
