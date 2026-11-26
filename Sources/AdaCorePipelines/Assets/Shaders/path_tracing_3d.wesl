// WESL port of path_tracing_3d.glsl. One fullscreen pass selected by `pu.u_Frame.y`:
// 0 trace, 1 temporal, 2 guide, 3 wavelet denoise, 4 reconstruct, 5 Ray Reconstruction guides.

@if(ADA_PATH_TRACING_RAY_QUERY) import package::path_tracing_terrain::traceTerrainMaterial;
import package::height_fog_3d::heightFogOpacity;
@if(ADA_PATH_TRACING_CACHE) import package::path_tracing_radiance_cache::{CACHE_CELLS, CACHE_DEPTHS, CACHE_MAX_AGE, CACHE_MIN_SAMPLES, CACHE_PROBES};
@if(ADA_PATH_TRACING_CACHE) import package::path_tracing_radiance_cache::{RadianceCacheCell, RadianceCacheEstimate, RadianceCacheRequest};
@if(ADA_PATH_TRACING_CACHE) import package::path_tracing_radiance_cache::{radianceCacheCellIsFresh, radianceCacheCellMatches, radianceCacheCellSize, radianceCacheIndex, radianceCacheKey, radianceCacheLevel};

@if(ADA_PATH_TRACING_RAY_QUERY) enable wgpu_ray_query;

struct PathVertex {
    @builtin(position) position: vec4f,
    @location(0) uv: vec2f,
}

@vertex
fn path_vertex(@builtin(vertex_index) vertexIndex: u32) -> PathVertex {
    let uv = vec2f(f32(vertexIndex >> 1u), f32(vertexIndex & 1u)) * 2.0;
    return PathVertex(vec4f(uv * vec2f(2.0, -2.0) + vec2f(-1.0, 1.0), 0.0, 1.0), uv);
}

struct PathUniform {
    u_InverseProjection: mat4x4f,
    u_InverseView: mat4x4f,
    u_Counts: vec4f, // nodes, lights, spp, surface interactions
    u_Trace: vec4f, // distance, bias, radiance clamp, history frames
    u_Frame: vec4f, // frame seed, pass (0 trace/1 filter/2 reconstruct), atlas rows, linear environment texture
    u_Zenith: vec4f,
    u_Horizon: vec4f,
    u_Ground: vec4f,
    u_Sky: vec4f, // environment texture enabled, intensity, rotation, procedural enabled
    u_Hybrid: vec4f, // x: raster first hit, y: denoiser strength, z: collect RR specular hit distance
    u_PreviousViewProjection: mat4x4f, // unjittered, previous frame of this view
    u_PreviousView: mat4x4f,
    u_Denoise: vec4f, // x: wavelet step, y: minimum history weight, z: trace writes demodulated light, w: final remodulates
    u_FogColor: vec4f, // sRGB color, extinction at the base height
    u_FogShape: vec4f, // height falloff, base height, start distance, opacity limit
    u_FogSun: vec4f, // direction, sun inscattering strength
    u_FogRadiance: vec4f, // sun radiance, sun exponent
    u_FogSky: vec4f, // x: influence on the sky
    u_Transport: vec4f, // x: bounded selection, y: emissive count, z: reset (+1) or relight (-1) cache, w: diagnostics
}

@group(0) @binding(0) var u_Nodes: texture_2d<f32>;
@group(0) @binding(1) var u_Triangles: texture_2d<f32>;
@group(0) @binding(2) var u_Materials: texture_2d<f32>;
@group(0) @binding(3) var u_Atlas: texture_2d<f32>;
@group(0) @binding(4) var<uniform> pu: PathUniform;
@group(0) @binding(5) var u_Lights: texture_2d<f32>;
@group(0) @binding(6) var u_History: texture_2d<f32>;
@group(0) @binding(7) var u_Environment: texture_2d<f32>;
@group(0) @binding(8) var u_Nearest: sampler;
@group(0) @binding(9) var u_Linear: sampler;
@group(0) @binding(10) var u_Normal: texture_2d<f32>;
@group(0) @binding(11) var u_Position: texture_2d<f32>;
@group(0) @binding(12) var u_Albedo: texture_2d<f32>;   // G-buffer base colour (path-tracing surface outputs)
@group(0) @binding(13) var u_Emission: texture_2d<f32>; // G-buffer emission
@group(0) @binding(14) var u_InputB: texture_2d<f32>;   // pass-specific second input
@group(0) @binding(15) var u_InputC: texture_2d<f32>;   // pass-specific third input
// The ray-query variant traces this top-level structure instead of walking the BVH textures.
@if(ADA_PATH_TRACING_RAY_QUERY) @group(0) @binding(16) var u_Scene: acceleration_structure;
@if(ADA_PATH_TRACING_CACHE) @group(0) @binding(18) var<storage, read> u_CacheRead: array<RadianceCacheCell>;
@if(ADA_PATH_TRACING_CACHE_UPDATE) @group(0) @binding(19) var<storage, read_write> u_CacheWrite: array<RadianceCacheCell>;
@if(ADA_PATH_TRACING_CACHE_UPDATE) @group(0) @binding(20) var<storage, read_write> u_CacheRequests: array<RadianceCacheRequest>;
@if(ADA_PATH_TRACING_CACHE_UPDATE) @group(0) @binding(21) var<storage, read_write> u_CacheDiagnostics: array<atomic<u32>, 3>;

const PI: f32 = 3.141592653589793;

var<private> randomState: u32;
var<private> scatteredSpecular: bool;
var<private> rrSpecularHitDistance: f32;

fn randomValue() -> f32 {
    randomState = randomState * 747796405u + 2891336453u;
    let word = ((randomState >> ((randomState >> 28u) + 4u)) ^ randomState) * 277803737u;
    return f32((word >> 22u) ^ word) / 4294967296.0;
}

fn texelCoordinate(index: i32) -> vec2i {
    return vec2i(index % 2048, index / 2048);
}
fn localTri(index: i32) -> vec4f { return textureLoad(u_Triangles, texelCoordinate(index), 0); }
@if(!ADA_PATH_TRACING_RAY_QUERY)
fn tri(index: i32) -> vec4f { return localTri(index); }
@if(ADA_PATH_TRACING_RAY_QUERY) var<private> hitObjectToWorld: mat4x3f;
@if(ADA_PATH_TRACING_RAY_QUERY) var<private> hitNormalToWorld: mat3x3f;
@if(ADA_PATH_TRACING_RAY_QUERY) var<private> hitMetadata: vec4f;
@if(ADA_PATH_TRACING_RAY_QUERY)
fn tri(index: i32) -> vec4f {
    let word = index % 12;
    let value = localTri(index);
    if word < 3 {
        let tag = select(select(0.0, hitMetadata.z, word == 1), hitMetadata.y, word == 0);
        return vec4f(hitObjectToWorld * vec4f(value.xyz, 1.0), tag);
    }
    if word < 6 { return vec4f(hitNormalToWorld * value.xyz, 0.0); }
    return value;
}
fn node(index: i32) -> vec4f { return textureLoad(u_Nodes, texelCoordinate(index), 0); }
fn material(index: i32) -> vec4f { return textureLoad(u_Materials, texelCoordinate(index), 0); }
fn light(index: i32) -> vec4f { return textureLoad(u_Lights, texelCoordinate(index), 0); }

fn atlas(tile: f32, uv: vec2f) -> vec4f {
    if tile < 0.0 {
        return vec4f(1.0);
    }
    // Half texel inset prevents adjacent materials bleeding into a repeated tile.
    let size = vec2f(textureDimensions(u_Atlas, 0));
    let tileSize = size.x / 16.0;
    let pixel = clamp(fract(uv) * tileSize, vec2f(0.5), vec2f(tileSize - 0.5));
    let origin = vec2f(tile - 16.0 * floor(tile / 16.0), floor(tile / 16.0)) * tileSize;
    return textureSampleLevel(u_Atlas, u_Linear, (origin + pixel) / size, 0.0);
}

fn srgb(color: vec3f) -> vec3f {
    return select(color / 12.92, pow((color + vec3f(0.055)) / 1.055, vec3f(2.4)), color > vec3f(0.04045));
}

fn sky(directionIn: vec3f) -> vec3f {
    var direction = directionIn;
    let angle = pu.u_Sky.z;
    let rotated = mat2x2f(cos(angle), -sin(angle), sin(angle), cos(angle)) * vec2f(direction.x, direction.z);
    direction = vec3f(rotated.x, direction.y, rotated.y);
    if pu.u_Sky.x > 0.5 {
        let uv = vec2f(atan2(direction.z, direction.x) / (2.0 * PI) + 0.5, asin(clamp(direction.y, -1.0, 1.0)) / PI + 0.5);
        let value = max(textureSampleLevel(u_Environment, u_Linear, uv, 0.0).rgb, vec3f(0.0));
        return select(srgb(value), value, pu.u_Frame.w > 0.5) * pu.u_Sky.y;
    }
    if pu.u_Sky.w < 0.5 {
        return vec3f(0.0);
    }
    let pole = select(pu.u_Ground.rgb, pu.u_Zenith.rgb, direction.y >= 0.0);
    return srgb(mix(pu.u_Horizon.rgb, pole, pow(abs(direction.y), 0.6))) * pu.u_Sky.y;
}

fn basis(normal: vec3f) -> mat3x3f {
    let t = normalize(select(cross(vec3f(0.0, 1.0, 0.0), normal), cross(vec3f(0.0, 0.0, 1.0), normal), abs(normal.z) < 0.9));
    return mat3x3f(t, cross(normal, t), normal);
}

fn boxHit(origin: vec3f, direction: vec3f, lo: vec3f, hi: vec3f, distance: f32) -> bool {
    // Parallel slabs need an explicit containment test; 0 * infinity is undefined.
    var nearT = 0.0;
    var farT = distance;
    for (var axis = 0; axis < 3; axis++) {
        if abs(direction[axis]) < 1e-9 {
            if origin[axis] < lo[axis] || origin[axis] > hi[axis] {
                return false;
            }
        } else {
            let a = (lo[axis] - origin[axis]) / direction[axis];
            let b = (hi[axis] - origin[axis]) / direction[axis];
            nearT = max(nearT, min(a, b));
            farT = min(farT, max(a, b));
            if farT < nearT {
                return false;
            }
        }
    }
    return true;
}

fn acceptsAlphaMode(materialWord: i32, uv: vec2f, mode: i32) -> bool {
    if mode == 0 { return true; }
    let alpha = material(materialWord).w * atlas(material(materialWord + 3).x, uv).a;
    if mode == 1 { return alpha >= material(materialWord + 2).z; }
    if mode == 2 { return randomValue() <= alpha; }
    return true;
}

fn acceptsAlpha(materialWord: i32, uv: vec2f) -> bool {
    return acceptsAlphaMode(materialWord, uv, i32(material(materialWord + 4).x));
}

fn acceptsTriangleAlpha(triangle: i32, materialWord: i32, weights: vec3f, mode: i32) -> bool {
    let uv = localTri(triangle + 6).xy * weights.x + localTri(triangle + 7).xy * weights.y + localTri(triangle + 8).xy * weights.z;
    return acceptsAlphaMode(materialWord, uv, mode);
}

// Each Vulkan instance addresses a compact record. Its geometry offset is shared by all copies of the mesh.
// Candidates are accepted with the same rules as the BVH variant: single-sided materials reject back faces, alpha-test and
// stochastic coverage reject by alpha. Shadow rays see only shadow-casting instances (mask bit 0) and stop at the first hit.
@if(ADA_PATH_TRACING_RAY_QUERY)
fn intersectScene(origin: vec3f, direction: vec3f, distance: ptr<function, f32>, bary: ptr<function, vec3f>, shadowRay: bool) -> i32 {
    var hit = -1;
    *bary = vec3f(0.0);
    var query: ray_query;
    let rayFlags = select(0u, 4u, shadowRay) | select(0u, RAY_FLAG_FORCE_OPAQUE, pu.u_Counts.x > 0.5);
    rayQueryInitialize(&query, u_Scene, RayDesc(rayFlags, select(255u, 1u, shadowRay), pu.u_Trace.y, *distance, origin, direction));
    while rayQueryProceed(&query) {
        let candidate = rayQueryGetCandidateIntersection(&query);
        let metadata = node(i32(candidate.instance_custom_data));
        if metadata.w > 0.0 {
            let fromCamera = origin + direction * candidate.t - pu.u_InverseView[3].xyz;
            if dot(fromCamera, fromCamera) > metadata.w * metadata.w { continue; }
        }
        let index = (i32(metadata.x) + i32(candidate.primitive_index)) * 12;
        let m = i32(metadata.y) * 5;
        let flags = u32(metadata.z);
        let mode = i32(flags >> 3u);
        let doubleSided = (flags & 4u) != 0u;
        // Opaque double-sided surfaces, the common case, need no further checks.
        if mode == 0 && doubleSided {
            rayQueryConfirmIntersection(&query);
            continue;
        }
        if !doubleSided {
            let a = localTri(index).xyz;
            let edge1 = candidate.object_to_world * vec4f(localTri(index + 1).xyz - a, 0.0);
            let edge2 = candidate.object_to_world * vec4f(localTri(index + 2).xyz - a, 0.0);
            if dot(edge1, cross(direction, edge2)) < 0.0 { continue; }
        }
        let weights = vec3f(1.0 - candidate.barycentrics.x - candidate.barycentrics.y, candidate.barycentrics.x, candidate.barycentrics.y);
        if mode == 0 || acceptsTriangleAlpha(index, m, weights, mode) {
            rayQueryConfirmIntersection(&query);
        }
    }
    let committed = rayQueryGetCommittedIntersection(&query);
    if committed.kind != 0u {
        if shadowRay { return 0; }
        let metadata = node(i32(committed.instance_custom_data));
        hitMetadata = metadata;
        hitObjectToWorld = committed.object_to_world;
        let inverse = committed.world_to_object;
        hitNormalToWorld = transpose(mat3x3f(inverse[0], inverse[1], inverse[2]));
        hit = (i32(metadata.x) + i32(committed.primitive_index)) * 12;
        *bary = vec3f(1.0 - committed.barycentrics.x - committed.barycentrics.y, committed.barycentrics.x, committed.barycentrics.y);
        *distance = committed.t;
    }
    return hit;
}

@if(!ADA_PATH_TRACING_RAY_QUERY)
// Returns the closest actual world triangle, with optional cast-shadow filtering.
fn intersectScene(origin: vec3f, direction: vec3f, distance: ptr<function, f32>, bary: ptr<function, vec3f>, shadowRay: bool) -> i32 {
    var hit = -1;
    *bary = vec3f(0.0);
    var cursor = 0;
    while cursor < i32(pu.u_Counts.x) {
        let lo = node(cursor * 3);
        let hi = node(cursor * 3 + 1);
        let info = node(cursor * 3 + 2);
        if !boxHit(origin, direction, lo.xyz, hi.xyz, *distance) {
            cursor = i32(lo.w);
            continue;
        }
        let count = i32(info.x);
        for (var i = 0; i < 4; i++) {
            if i >= count {
                break;
            }
            let index = (i32(hi.w) + i) * 12;
            let a = tri(index);
            let b = tri(index + 1);
            let c = tri(index + 2);
            if shadowRay && (i32(b.w) & 1) == 0 {
                continue;
            }
            let e1 = b.xyz - a.xyz;
            let e2 = c.xyz - a.xyz;
            let p = cross(direction, e2);
            let determinant = dot(e1, p);
            if abs(determinant) < 1e-10 {
                continue;
            }
            let m = i32(a.w) * 5;
            if material(m + 2).w < 0.5 && determinant < 0.0 {
                continue;
            }
            let t = origin - a.xyz;
            let u = dot(t, p) / determinant;
            let q = cross(t, e1);
            let v = dot(direction, q) / determinant;
            let travel = dot(e2, q) / determinant;
            if u < 0.0 || v < 0.0 || u + v > 1.0 || travel <= pu.u_Trace.y || travel >= *distance {
                continue;
            }
            let weights = vec3f(1.0 - u - v, u, v);
            if !acceptsTriangleAlpha(index, m, weights, i32(material(m + 4).x)) { continue; }
            hit = index;
            *bary = weights;
            *distance = travel;
            if shadowRay {
                return hit;
            }
        }
        cursor += 1;
    }
    return hit;
}

struct RayHit {
    triangle: i32,
    distance: f32,
    barycentrics: vec3f,
}

fn closestHit(origin: vec3f, direction: vec3f) -> RayHit {
    var distance = pu.u_Trace.x;
    var barycentrics: vec3f;
    let triangle = intersectScene(origin, direction, &distance, &barycentrics, false);
    return RayHit(triangle, distance, barycentrics);
}

fn isBlocked(origin: vec3f, direction: vec3f, maximumDistance: f32) -> bool {
    if maximumDistance <= pu.u_Trace.y { return false; }
    var distance = maximumDistance;
    var barycentrics: vec3f;
    return intersectScene(origin, direction, &distance, &barycentrics, true) >= 0;
}

struct Surface {
    position: vec3f,
    normal: vec3f,
    geometric: vec3f,
    color: vec3f,
    emission: vec3f,
    roughness: f32,
    metal: f32,
    receives: bool,
}

fn surfaceAt(hit: i32, bary: vec3f, origin: vec3f, direction: vec3f, distance: f32) -> Surface {
    var s: Surface;
    let m = i32(tri(hit).w) * 5;
    let factor = material(m);
    let parameters = material(m + 2);
    let tiles = material(m + 3);
    let uv = tri(hit + 6) * bary.x + tri(hit + 7) * bary.y + tri(hit + 8) * bary.z;
    let other = tri(hit + 9) * bary.x + tri(hit + 10) * bary.y + tri(hit + 11) * bary.z;
    s.position = origin + direction * distance;
    s.geometric = normalize(cross(tri(hit + 1).xyz - tri(hit).xyz, tri(hit + 2).xyz - tri(hit).xyz));
    let n = tri(hit + 3).xyz * bary.x + tri(hit + 4).xyz * bary.y + tri(hit + 5).xyz * bary.z;
    s.normal = select(s.geometric, normalize(n), dot(n, n) > 0.00001);
    if dot(s.geometric, direction) > 0.0 {
        s.geometric = -s.geometric;
    }
    if dot(s.normal, direction) > 0.0 {
        s.normal = -s.normal;
    }
    s.receives = (i32(tri(hit + 1).w) & 2) != 0;
    @if(ADA_PATH_TRACING_RAY_QUERY) {
        let header = i32(material(m + 4).z);
        if header > 0 {
            let a = localTri(hit).xyz;
            let b = localTri(hit + 1).xyz;
            let c = localTri(hit + 2).xyz;
            let plane = normalize(cross(b - a, c - a));
            let localN = localTri(hit + 3).xyz * bary.x + localTri(hit + 4).xyz * bary.y + localTri(hit + 5).xyz * bary.z;
            let localNormal = select(plane, normalize(localN), dot(localN, localN) > 0.00001);
            let edge1 = b - a;
            let edge2 = c - a;
            let d2 = cross(edge2, localNormal);
            let d1 = cross(localNormal, edge1);
            let tangent = d2 * edge1.x + d1 * edge2.x;
            let bitangent = d2 * edge1.z + d1 * edge2.z;
            let frameScale = sign(dot(plane, localNormal)) * inverseSqrt(max(max(dot(tangent, tangent), dot(bitangent, bitangent)), 0.000001));
            let frame = mat3x3f(tangent * frameScale, bitangent * frameScale, localNormal);
            let fieldUV = localTri(hit + 6).zw * bary.x + localTri(hit + 7).zw * bary.y + localTri(hit + 8).zw * bary.z;
            let sampled = traceTerrainMaterial(u_Materials, u_Atlas, u_Linear, header, a * bary.x + b * bary.y + c * bary.z, fieldUV, localNormal, frame);
            let mapped = normalize(hitNormalToWorld * sampled.normal);
            let faced = select(mapped, -mapped, dot(mapped, s.normal) < 0.0);
            if dot(faced, s.geometric) > 0.0 { s.normal = faced; }
            s.color = clamp(factor.rgb * sampled.color, vec3f(0.0), vec3f(1.0));
            s.roughness = sampled.roughness;
            s.metal = sampled.metal;
            s.emission = vec3f(0.0);
            return s;
        }
    }
    if tiles.w >= 0.0 {
        let du = tri(hit + 10).zw - tri(hit + 9).zw;
        let dv = tri(hit + 11).zw - tri(hit + 9).zw;
        let det = du.x * dv.y - du.y * dv.x;
        if abs(det) > 0.000001 {
            let e1 = tri(hit + 1).xyz - tri(hit).xyz;
            let e2 = tri(hit + 2).xyz - tri(hit).xyz;
            var t = (e1 * dv.y - e2 * du.y) / det;
            t = normalize(t - s.normal * dot(s.normal, t));
            let b = cross(s.normal, t) * sign(det);
            var mapped = atlas(tiles.w, other.zw).xyz * 2.0 - vec3f(1.0);
            mapped = vec3f(mapped.xy * material(m + 4).y, mapped.z);
            let mappedNormal = normalize(mat3x3f(t, b, s.normal) * mapped);
            if dot(mappedNormal, s.geometric) > 0.0 {
                s.normal = mappedNormal;
            }
        }
    }
    s.color = clamp(factor.rgb * select(vec3f(1.0), srgb(atlas(tiles.x, uv.xy).rgb), tiles.x >= 0.0), vec3f(0.0), vec3f(1.0));
    let mr = atlas(tiles.y, uv.zw);
    s.metal = clamp(parameters.x * mr.b, 0.0, 1.0);
    s.roughness = clamp(parameters.y * mr.g, 0.04, 1.0);
    s.emission = max(material(m + 1).rgb, vec3f(0.0)) * select(vec3f(1.0), srgb(atlas(tiles.z, other.xy).rgb), tiles.z >= 0.0);
    return s;
}

fn fresnel(f0: vec3f, cosine: f32) -> vec3f {
    return f0 + (vec3f(1.0) - f0) * pow(1.0 - clamp(cosine, 0.0, 1.0), 5.0);
}

fn brdf(s: Surface, view: vec3f, direction: vec3f, specularOnly: bool) -> vec3f {
    let nv = max(dot(s.normal, view), 0.0001);
    let nl = max(dot(s.normal, direction), 0.0);
    if nl <= 0.0 {
        return vec3f(0.0);
    }
    let halfVector = normalize(view + direction);
    let nh = max(dot(s.normal, halfVector), 0.0);
    let vh = max(dot(view, halfVector), 0.0);
    let a = s.roughness * s.roughness;
    let a2 = a * a;
    let denominator = nh * nh * (a2 - 1.0) + 1.0;
    let d = a2 / max(PI * denominator * denominator, 1e-10);
    let gv = 2.0 * nv / (nv + sqrt(a2 + (1.0 - a2) * nv * nv));
    let gl = 2.0 * nl / (nl + sqrt(a2 + (1.0 - a2) * nl * nl));
    let f = fresnel(mix(vec3f(0.04), s.color, s.metal), vh);
    let diffuse = select((vec3f(1.0) - f) * (1.0 - s.metal) * s.color / PI, vec3f(0.0), specularOnly);
    return (diffuse + f * d * gv * gl / max(4.0 * nv * nl, 0.0001)) * nl;
}

struct LightCandidate {
    direction: vec3f,
    distance: f32,
    incident: vec3f,
    shadows: bool,
    // Zero for analytic lights, which a continuation ray cannot hit.
    emissivePdf: f32,
}

fn analyticLight(s: Surface, selectedIndex: i32) -> LightCandidate {
    let selected = selectedIndex * 4;
    let a = light(selected);
    let b = light(selected + 1);
    let c = light(selected + 2);
    let d = light(selected + 3);
    var direction: vec3f;
    var distance = pu.u_Trace.x;
    var attenuation = 1.0;
    if a.w < 0.5 {
        direction = normalize(a.xyz);
        if d.z > 0.0 {
            let r = sqrt(randomValue()) * d.z;
            let phi = 2.0 * PI * randomValue();
            direction = normalize(direction + basis(direction) * vec3f(r * cos(phi), r * sin(phi), 0.0));
        }
    } else {
        let delta = a.xyz - s.position;
        distance = length(delta);
        if distance >= b.w || distance < 0.00001 {
            return LightCandidate();
        }
        direction = delta / distance;
        let cutoff = max(0.0, 1.0 - pow(distance / b.w, 4.0));
        attenuation = cutoff * cutoff / max(distance * distance, 0.01);
        if a.w > 1.5 {
            attenuation *= smoothstep(d.y, d.x, dot(-direction, normalize(c.xyz)));
        }
    }
    return LightCandidate(direction, distance, max(b.rgb, vec3f(0.0)) * attenuation, c.w > 0.5, 0.0);
}

fn emissionProbability() -> f32 {
    return select(1.0, 0.5, pu.u_Counts.y > 0.0);
}

fn solidAnglePdf(distance: f32, areaTwice: f32, cosine: f32) -> f32 {
    return 2.0 * distance * distance / (areaTwice * cosine);
}

fn emissiveLight(s: Surface, selectedIndex: i32, probability: f32) -> LightCandidate {
    let offset = i32(pu.u_Counts.y) * 4 + selectedIndex * 6;
    let a = light(offset);
    let b = light(offset + 1);
    let c = light(offset + 2);
    let root = sqrt(randomValue());
    let second = randomValue() * root;
    let weights = vec3f(1.0 - root, root - second, second);
    let point = a.xyz * weights.x + b.xyz * weights.y + c.xyz * weights.z;
    let delta = point - s.position;
    let distance = length(delta);
    if distance <= pu.u_Trace.y * 3.0 || distance >= pu.u_Trace.x { return LightCandidate(); }
    if b.w > 0.0 {
        let fromCamera = point - pu.u_InverseView[3].xyz;
        if dot(fromCamera, fromCamera) > b.w * b.w { return LightCandidate(); }
    }
    let direction = delta / distance;
    let crossEdge = cross(b.xyz - a.xyz, c.xyz - a.xyz);
    let areaTwice = length(crossEdge);
    let m = i32(a.w) * 5;
    let facing = dot(crossEdge / areaTwice, -direction);
    let cosine = select(facing, abs(facing), material(m + 2).w >= 0.5);
    if cosine <= 0.000001 { return LightCandidate(); }
    let uv = light(offset + 3) * weights.x + light(offset + 4) * weights.y + light(offset + 5) * weights.z;
    if !acceptsAlpha(m, uv.xy) { return LightCandidate(); }
    let tile = material(m + 3).z;
    let intensity = max(material(m + 1).rgb, vec3f(0.0)) * select(vec3f(1.0), srgb(atlas(tile, uv.zw).rgb), tile >= 0.0);
    let pdf = solidAnglePdf(distance, areaTwice, cosine);
    return LightCandidate(direction, distance, intensity / pdf, true, probability * pdf);
}

fn sampleIsVisible(s: Surface, candidate: LightCandidate) -> bool {
    if !s.receives || !candidate.shadows { return true; }
    let bias = pu.u_Trace.y * 2.0;
    let offset = s.geometric * bias;
    let origin = s.position + offset;
    if candidate.emissivePdf > 0.0 {
        // Aim at the sampled point from the biased origin so the emitter cannot shadow itself.
        let toEmitter = candidate.direction * candidate.distance - offset;
        let distance = length(toEmitter);
        return !isBlocked(origin, toEmitter / distance, distance - bias);
    }
    return !isBlocked(origin, candidate.direction, candidate.distance - bias);
}

fn sampleWeight(s: Surface, view: vec3f, candidate: LightCandidate, specularOnly: bool) -> vec3f {
    if dot(s.normal, candidate.direction) <= 0.0 || dot(s.geometric, candidate.direction) <= 0.0 {
        return vec3f(0.0);
    }
    return brdf(s, view, candidate.direction, specularOnly) * candidate.incident;
}

fn powerWeight(sampled: f32, alternative: f32) -> f32 {
    let ratio = alternative / max(sampled, 1e-20);
    return 1.0 / (1.0 + ratio * ratio);
}

fn indirectEmissionWeight(hit: RayHit, direction: vec3f, previousPdf: f32) -> f32 {
    if pu.u_Transport.y <= 0.0 || previousPdf <= 0.0 || hit.distance <= pu.u_Trace.y * 3.0 { return 1.0; }
    let a = tri(hit.triangle).xyz;
    let crossEdge = cross(tri(hit.triangle + 1).xyz - a, tri(hit.triangle + 2).xyz - a);
    let areaTwice = length(crossEdge);
    if areaTwice <= 1e-8 { return 1.0; }
    let cosine = abs(dot(crossEdge / areaTwice, direction));
    if cosine <= 0.000001 { return 1.0; }
    let emitterPdf = emissionProbability() * solidAnglePdf(hit.distance, areaTwice, cosine) / pu.u_Transport.y;
    return powerWeight(previousPdf, emitterPdf);
}

struct DirectLightEstimate {
    radiance: vec3f,
    continued: vec3f,
}

fn sampleDirectLight(
    s: Surface, view: vec3f, bounce: i32, hasContinuation: bool, diffuseIrradiance: bool, specularOnly: bool
) -> DirectLightEstimate {
    let analyticCount = i32(pu.u_Counts.y);
    let emissiveCount = i32(pu.u_Transport.y);
    if analyticCount + emissiveCount == 0 { return DirectLightEstimate(); }
    let pEmissive = select(0.0, emissionProbability(), emissiveCount > 0);
    // With one analytic light, stratify the two equally weighted proposal families.
    // A smaller budget still tests both the analytic light and an emitter on every response.
    let stratified = analyticCount == 1 && emissiveCount > 0;
    let samples = select(select(4, 8, bounce == 0), select(2, 4, bounce == 0), stratified);
    var chosen: LightCandidate;
    var chosenContribution = vec3f(0.0);
    var chosenTarget = 0.0;
    var chosenContinuationWeight = 1.0;
    var totalWeight = 0.0;
    for (var i = 0; i < samples; i++) {
        var candidate: LightCandidate;
        var probability: f32;
        var chooseEmitter = pEmissive >= 1.0;
        if stratified {
            chooseEmitter = (i & 1) == 0;
        } else if pEmissive > 0.0 && pEmissive < 1.0 {
            chooseEmitter = randomValue() < pEmissive;
        }
        if chooseEmitter {
            probability = pEmissive / pu.u_Transport.y;
            let index = min(emissiveCount - 1, i32(randomValue() * pu.u_Transport.y));
            candidate = emissiveLight(s, index, probability);
        } else {
            probability = (1.0 - pEmissive) / pu.u_Counts.y;
            let index = min(analyticCount - 1, i32(randomValue() * pu.u_Counts.y));
            candidate = analyticLight(s, index);
        }
        var contribution: vec3f;
        var bsdfPdf: f32;
        if diffuseIrradiance {
            let cosine = select(0.0, max(dot(s.normal, candidate.direction), 0.0), dot(s.geometric, candidate.direction) > 0.0);
            contribution = candidate.incident * cosine;
            bsdfPdf = cosine / PI;
        } else {
            contribution = sampleWeight(s, view, candidate, specularOnly);
            if hasContinuation && candidate.emissivePdf > 0.0 {
                bsdfPdf = scatterPdf(s, view, candidate.direction);
            }
        }
        var continuationWeight = 1.0;
        if hasContinuation && candidate.emissivePdf > 0.0 {
            continuationWeight = powerWeight(candidate.emissivePdf, bsdfPdf);
        }
        if !diffuseIrradiance { contribution *= continuationWeight; }
        let target = dot(contribution, vec3f(0.2126, 0.7152, 0.0722));
        if target <= 0.0 { continue; }
        let weight = target / probability;
        totalWeight += weight;
        if chosenTarget == 0.0 || randomValue() * totalWeight < weight {
            chosen = candidate;
            chosenContribution = contribution;
            chosenTarget = target;
            chosenContinuationWeight = select(1.0, continuationWeight, diffuseIrradiance);
        }
    }
    if chosenTarget <= 0.0 || !sampleIsVisible(s, chosen) { return DirectLightEstimate(); }
    let radiance = chosenContribution * (totalWeight / (f32(samples) * chosenTarget));
    // The diffuse cache needs the terminal and continuing estimates from one visibility query.
    return DirectLightEstimate(radiance, radiance * chosenContinuationWeight);
}

fn directLight(s: Surface, view: vec3f, bounce: i32, specularOnly: bool) -> vec3f {
    if pu.u_Transport.x > 0.5 {
        return sampleDirectLight(s, view, bounce, bounce + 1 < i32(pu.u_Counts.w), false, specularOnly).radiance;
    }
    // Deterministic enumeration removes light-selection noise from the small authored game light set.
    var result = vec3f(0.0);
    for (var index = 0; index < i32(pu.u_Counts.y); index++) {
        let candidate = analyticLight(s, index);
        if dot(s.normal, candidate.direction) > 0.0 && dot(s.geometric, candidate.direction) > 0.0 && sampleIsVisible(s, candidate) {
            result += sampleWeight(s, view, candidate, specularOnly);
        }
    }
    return result;
}

fn specularProbability(s: Surface) -> f32 {
    let f0 = mix(vec3f(0.04), s.color, s.metal);
    return clamp(max(f0.r, max(f0.g, f0.b)), 0.1, 0.9);
}

fn scatterPdf(s: Surface, view: vec3f, direction: vec3f) -> f32 {
    let nl = dot(s.normal, direction);
    let h = normalize(view + direction);
    let nh = max(dot(s.normal, h), 0.0);
    let a = s.roughness * s.roughness;
    let a2 = a * a;
    let denominator = nh * nh * (a2 - 1.0) + 1.0;
    let d = a2 / max(PI * denominator * denominator, 1e-10);
    let chance = specularProbability(s);
    return (1.0 - chance) * nl / PI + chance * d * nh / max(4.0 * abs(dot(view, h)), 0.00001);
}

// Samples the next direction from a diffuse/GGX mixture. A zero PDF ends the path.
fn scatter(s: Surface, view: vec3f, throughput: ptr<function, vec3f>, nextDirection: ptr<function, vec3f>, specularOnly: bool) -> f32 {
    let chance = specularProbability(s);
    scatteredSpecular = randomValue() < chance;
    if scatteredSpecular {
        let u = randomValue();
        let phi = 2.0 * PI * randomValue();
        let a = s.roughness * s.roughness;
        let cosine = sqrt((1.0 - u) / max(1.0 + (a * a - 1.0) * u, 0.000001));
        let halfVector = normalize(basis(s.normal) * vec3f(sqrt(max(0.0, 1.0 - cosine * cosine)) * vec2f(cos(phi), sin(phi)), cosine));
        *nextDirection = reflect(-view, halfVector);
    } else {
        let r = sqrt(randomValue());
        let phi = 2.0 * PI * randomValue();
        *nextDirection = normalize(basis(s.normal) * vec3f(r * cos(phi), r * sin(phi), sqrt(max(0.0, 1.0 - r * r))));
    }
    if dot(s.normal, *nextDirection) <= 0.0 || dot(s.geometric, *nextDirection) <= 0.0 { return 0.0; }
    let pdf = scatterPdf(s, view, *nextDirection);
    *throughput = *throughput * (brdf(s, view, *nextDirection, specularOnly) / max(pdf, 1e-8));
    return pdf;
}

// Traces from `origin`; `firstBounce` counts interactions already shaded by the caller.
fn path(originIn: vec3f, directionIn: vec3f, firstBounce: i32, firstPdf: f32) -> vec3f {
    var previousPdf = firstPdf;
    let recordFirstReflection = pu.u_Hybrid.z > 0.5 && firstBounce == 1 && scatteredSpecular && rrSpecularHitDistance == 0.0;
    var origin = originIn;
    var direction = directionIn;
    var throughput = vec3f(1.0);
    var radiance = vec3f(0.0);
    for (var bounce = firstBounce; bounce < 8; bounce++) {
        if bounce >= i32(pu.u_Counts.w) {
            break;
        }
        let hit = closestHit(origin, direction);
        let distance = hit.distance;
        if recordFirstReflection && bounce == firstBounce {
            rrSpecularHitDistance = distance;
        }
        if bounce == 0 && pu.u_FogColor.w > 0.0 {
            let camera = pu.u_InverseView[3].xyz;
            let ray = origin + direction * distance - camera;
            let skyRay = hit.triangle < 0;
            let fogDirection = select(normalize(ray), direction, skyRay);
            let fogDistance = select(length(ray), 1000.0, skyRay);
            let opacity = heightFogOpacity(pu.u_FogColor.w, pu.u_FogShape, camera.y, fogDirection.y, fogDistance)
                * select(1.0, pu.u_FogSky.x, skyRay);
            let sun = pow(max(dot(fogDirection, pu.u_FogSun.xyz), 0.0), pu.u_FogRadiance.w);
            radiance += opacity * (srgb(pu.u_FogColor.rgb) + pu.u_FogRadiance.rgb * (pu.u_FogSun.w * sun));
            throughput *= 1.0 - opacity;
        }
        if hit.triangle < 0 {
            radiance += throughput * sky(direction);
            break;
        }
        let s = surfaceAt(hit.triangle, hit.barycentrics, origin, direction, distance);
        var emission = s.emission;
        if pu.u_Transport.x > 0.5 && any(emission > vec3f(0.0)) {
            emission *= indirectEmissionWeight(hit, direction, previousPdf);
        }
        var cachedDiffuse = false;
        @if(ADA_PATH_TRACING_CACHE) {
            let remaining = i32(pu.u_Counts.w) - bounce;
            let cacheDepth = i32(CACHE_DEPTHS);
            if bounce > 0 && remaining >= 1 && remaining <= cacheDepth + 1 && useCachedBounce(s, distance, previousPdf) {
                let cell = lookupRadianceCell(s.position, s.geometric, CACHE_MIN_SAMPLES);
                let incoming = cell.irradiance[u32(min(remaining, cacheDepth) - 1)];
                // A relighting cell can stand in for one more interaction until its old light has faded.
                let coversBounce = remaining <= cacheDepth || cell.normal.w < 0.0;
                if incoming.w > 0.0 && coversBounce {
                    let diffuse = s.color * ((1.0 - s.metal) * 0.96 / PI);
                    radiance += throughput * (emission + diffuse * incoming.rgb);
                    // Preserve the existing rough-dielectric shortcut on nonterminal hits.
                    if remaining > 1 && s.roughness >= 0.5 && s.metal <= 0.08 { break; }
                    cachedDiffuse = true;
                    emission = vec3f(0.0);
                }
            }
        }
        radiance += throughput * (emission + directLight(s, -direction, bounce, cachedDiffuse));
        if bounce + 1 >= i32(pu.u_Counts.w) { break; }
        var nextDirection: vec3f;
        previousPdf = scatter(s, -direction, &throughput, &nextDirection, cachedDiffuse);
        if previousPdf <= 0.0 {
            break;
        }
        if bounce >= 2 {
            let survive = clamp(max(throughput.r, max(throughput.g, throughput.b)), 0.05, 0.95);
            if randomValue() > survive {
                break;
            }
            throughput = throughput / survive;
        }
        origin = s.position + s.geometric * pu.u_Trace.y * 2.0;
        direction = nextDirection;
    }
    return radiance;
}

struct GBufferHit {
    valid: bool,
    surface: Surface,
    view: vec3f,
}

// The raster G-buffer's surface at `uv`: full model detail, independent of the traced LOD geometry.
fn gbufferSurface(uv: vec2f) -> GBufferHit {
    var result: GBufferHit;
    result.valid = false;
    if pu.u_Hybrid.x < 0.5 {
        return result;
    }
    let normalRoughness = textureSampleLevel(u_Normal, u_Nearest, uv, 0.0);
    if dot(normalRoughness.xyz, normalRoughness.xyz) < 0.01 {
        return result;
    }
    let positionMetallic = textureSampleLevel(u_Position, u_Nearest, uv, 0.0);
    let inverseView = pu.u_InverseView;
    var s: Surface;
    s.position = (inverseView * vec4f(positionMetallic.xyz, 1.0)).xyz;
    s.normal = normalize(mat3x3f(inverseView[0].xyz, inverseView[1].xyz, inverseView[2].xyz) * normalRoughness.xyz);
    let view = normalize(inverseView[3].xyz - s.position);
    if dot(s.normal, view) < 0.0 {
        s.normal = -s.normal;
    }
    // The G-buffer has no geometric normal; the shading normal also offsets continuation rays.
    s.geometric = s.normal;
    s.color = textureSampleLevel(u_Albedo, u_Nearest, uv, 0.0).rgb;
    s.emission = max(textureSampleLevel(u_Emission, u_Nearest, uv, 0.0).rgb, vec3f(0.0));
    s.roughness = clamp(normalRoughness.w, 0.04, 1.0);
    s.metal = clamp(positionMetallic.w, 0.0, 1.0);
    s.receives = true;
    result.valid = true;
    result.surface = s;
    result.view = view;
    return result;
}

fn hasSurface(uv: vec2f) -> bool {
    let n = textureSampleLevel(u_Normal, u_Nearest, uv, 0.0).xyz;
    return dot(n, n) > 0.01;
}

// Base colour that divides lighting before filtering, so texture detail is never blurred. 1 off surfaces.
fn demodulation(uv: vec2f) -> vec3f {
    if pu.u_Hybrid.x < 0.5 || !hasSurface(uv) {
        return vec3f(1.0);
    }
    return max(textureSampleLevel(u_Albedo, u_Nearest, uv, 0.0).rgb, vec3f(0.03));
}

fn emissionAt(uv: vec2f) -> vec3f {
    if pu.u_Hybrid.x < 0.5 || !hasSurface(uv) {
        return vec3f(0.0);
    }
    return max(textureSampleLevel(u_Emission, u_Nearest, uv, 0.0).rgb, vec3f(0.0));
}

fn luminance(c: vec3f) -> f32 {
    return dot(c, vec3f(0.2126, 0.7152, 0.0722));
}

fn viewRotation() -> mat3x3f {
    let inverseView = pu.u_InverseView;
    return mat3x3f(inverseView[0].xyz, inverseView[1].xyz, inverseView[2].xyz);
}

// Pass 1: reproject the previous frame's accumulated light (input B) through this pixel's world position, reject it
// where the previous guide (input C: world normal and camera distance) disagrees, and blend the new sample (input A).
fn temporalPass(vUV: vec2f) -> vec4f {
    let current = textureSampleLevel(u_History, u_Nearest, vUV, 0.0).rgb;
    let normal = textureSampleLevel(u_Normal, u_Nearest, vUV, 0.0);
    if dot(normal.xyz, normal.xyz) < 0.01 || pu.u_Trace.w < 0.5 {
        return vec4f(current, 1.0);
    }
    let viewPosition = textureSampleLevel(u_Position, u_Nearest, vUV, 0.0).xyz;
    let world = (pu.u_InverseView * vec4f(viewPosition, 1.0)).xyz;
    let worldNormal = normalize(viewRotation() * normal.xyz);
    let clip = pu.u_PreviousViewProjection * vec4f(world, 1.0);
    var history = vec4f(0.0);
    if clip.w > 0.0001 {
        let uv = clip.xy / clip.w * vec2f(0.5, -0.5) + vec2f(0.5);
        if all(uv >= vec2f(0.0)) && all(uv <= vec2f(1.0)) {
            let guide = textureSampleLevel(u_InputC, u_Nearest, uv, 0.0);
            let expected = length((pu.u_PreviousView * vec4f(world, 1.0)).xyz);
            if dot(guide.xyz, worldNormal) > 0.9 && abs(guide.w - expected) < 0.05 * expected + 0.02 {
                history = textureSampleLevel(u_InputB, u_Linear, uv, 0.0);
            }
        }
    }
    if history.a > 0.0 {
        // Clamp history to the current neighbourhood (mean +- 2 sigma per channel): a light that switches off or
        // turns away is followed at once, while ordinary sample noise keeps the range wide enough to converge.
        let texel = vec2f(1.0) / vec2f(textureDimensions(u_History, 0));
        var mean = vec3f(0.0);
        var square = vec3f(0.0);
        for (var y = -1; y <= 1; y++) {
            for (var x = -1; x <= 1; x++) {
                let value = textureSampleLevel(u_History, u_Nearest, clamp(vUV + vec2f(f32(x), f32(y)) * texel, vec2f(0.0), vec2f(1.0)), 0.0).rgb;
                mean += value;
                square += value * value;
            }
        }
        mean = mean / 9.0;
        let sigma = sqrt(max(square / 9.0 - mean * mean, vec3f(0.0)));
        history = vec4f(clamp(history.rgb, mean - 2.0 * sigma, mean + 2.0 * sigma), history.a);
    }
    let frames = min(history.a + 1.0, 1024.0);
    return vec4f(mix(history.rgb, current, max(1.0 / frames, pu.u_Denoise.y)), frames);
}

// Pass 2: this frame's guide for the next frame's reprojection.
fn guidePass(vUV: vec2f) -> vec4f {
    let normal = textureSampleLevel(u_Normal, u_Nearest, vUV, 0.0);
    if dot(normal.xyz, normal.xyz) < 0.01 {
        return vec4f(0.0);
    }
    let viewPosition = textureSampleLevel(u_Position, u_Nearest, vUV, 0.0).xyz;
    return vec4f(normalize(viewRotation() * normal.xyz), length(viewPosition));
}

// Pass 3: one edge-aware a-trous wavelet iteration with spacing u_Denoise.x, guided by normal, depth and the
// local luminance variance, so flat noisy regions smooth while edges and texture-independent detail stay.
fn waveletPass(vUV: vec2f) -> vec4f {
    let center = textureSampleLevel(u_History, u_Nearest, vUV, 0.0);
    let normal = textureSampleLevel(u_Normal, u_Nearest, vUV, 0.0);
    if dot(normal.xyz, normal.xyz) < 0.01 {
        return center;
    }
    let texel = vec2f(1.0) / vec2f(textureDimensions(u_History, 0));
    var mean = 0.0;
    var square = 0.0;
    for (var y = -1; y <= 1; y++) {
        for (var x = -1; x <= 1; x++) {
            let l = luminance(textureSampleLevel(u_History, u_Nearest, clamp(vUV + vec2f(f32(x), f32(y)) * texel, vec2f(0.0), vec2f(1.0)), 0.0).rgb);
            mean += l;
            square += l * l;
        }
    }
    mean = mean / 9.0;
    // Strength above 1 widens the tolerance, most of all where the temporal history is short (just-moved or newly visible
    // pixels, stored in alpha), so noisy fresh pixels are smoothed hard while converged ones keep their detail.
    let strength = max(pu.u_Hybrid.y, 1.0);
    let tolerance = strength + (strength - 1.0) * 6.0 / max(center.a, 1.0);
    let sigma = 4.0 * tolerance * sqrt(max(square / 9.0 - mean * mean, 0.0)) + 0.0001;
    let depth = length(textureSampleLevel(u_Position, u_Nearest, vUV, 0.0).xyz);
    let centerLuminance = luminance(center.rgb);
    var kernel = array<f32, 3>(0.375, 0.25, 0.0625);
    var sum = vec3f(0.0);
    var weights = 0.0;
    for (var y = -2; y <= 2; y++) {
        for (var x = -2; x <= 2; x++) {
            let uv = vUV + vec2f(f32(x), f32(y)) * texel * pu.u_Denoise.x;
            if any(uv < vec2f(0.0)) || any(uv > vec2f(1.0)) {
                continue;
            }
            let otherNormal = textureSampleLevel(u_Normal, u_Nearest, uv, 0.0);
            if dot(otherNormal.xyz, otherNormal.xyz) < 0.01 {
                continue;
            }
            let value = textureSampleLevel(u_History, u_Nearest, uv, 0.0).rgb;
            let otherDepth = length(textureSampleLevel(u_Position, u_Nearest, uv, 0.0).xyz);
            var weight = kernel[abs(x)] * kernel[abs(y)];
            weight = weight * pow(max(dot(normalize(normal.xyz), normalize(otherNormal.xyz)), 0.0), 128.0);
            weight = weight * exp(-abs(depth - otherDepth) / (0.01 * depth * pu.u_Denoise.x + 0.001));
            weight = weight * exp(-abs(centerLuminance - luminance(value)) / sigma);
            sum += value * weight;
            weights += weight;
        }
    }
    return vec4f(select(center.rgb, sum / weights, weights > 0.00001), center.a);
}

// Pass 4: geometry-aware reconstruction at output resolution, then remodulation with the full-resolution surface.
fn finalPass(vUV: vec2f) -> vec4f {
    let n = textureSampleLevel(u_Normal, u_Nearest, vUV, 0.0).xyz;
    let p = textureSampleLevel(u_Position, u_Nearest, vUV, 0.0).xyz;
    let size = vec2f(textureDimensions(u_History, 0));
    let center = floor(vUV * size - vec2f(0.5));
    let fraction = fract(vUV * size - vec2f(0.5));
    var sum = vec3f(0.0);
    var weightSum = 0.0;
    for (var y = 0; y < 2; y++) {
        for (var x = 0; x < 2; x++) {
            let uv = clamp((center + vec2f(f32(x), f32(y)) + vec2f(0.5)) / size, vec2f(0.0), vec2f(1.0));
            let otherN = textureSampleLevel(u_Normal, u_Nearest, uv, 0.0).xyz;
            let otherP = textureSampleLevel(u_Position, u_Nearest, uv, 0.0).xyz;
            var weight = select(fraction.x, 1.0 - fraction.x, x == 0) * select(fraction.y, 1.0 - fraction.y, y == 0);
            let surface = dot(n, n) > 0.01;
            let otherSurface = dot(otherN, otherN) > 0.01;
            if surface != otherSurface {
                weight = 0.0;
            }
            if surface && otherSurface {
                weight = weight * pow(max(dot(normalize(n), normalize(otherN)), 0.0), 16.0) * exp(-abs(p.z - otherP.z) / max(0.02, p.z * 0.01));
            }
            sum += textureSampleLevel(u_History, u_Nearest, uv, 0.0).rgb * weight;
            weightSum += weight;
        }
    }
    var result = select(textureSampleLevel(u_History, u_Nearest, vUV, 0.0).rgb, sum / weightSum, weightSum > 0.00001);
    if pu.u_Denoise.w > 0.5 {
        result = result * demodulation(vUV) + emissionAt(vUV);
    }
    return vec4f(result, 1.0);
}

// Pass 5: Ray Reconstruction guides; u_Denoise.x selects diffuse albedo (0), specular albedo (1) or world normal
// with roughness (2).
fn rayReconstructionGuidePass(vUV: vec2f) -> vec4f {
    let hit = gbufferSurface(vUV);
    if !hit.valid {
        return select(vec4f(0.0), vec4f(0.5, 0.5, 0.5, 1.0), pu.u_Denoise.x < 0.5);
    }
    let surface = hit.surface;
    if pu.u_Denoise.x > 1.5 {
        return vec4f(surface.normal, surface.roughness);
    }
    if pu.u_Denoise.x < 0.5 {
        return vec4f(surface.color * (1.0 - surface.metal), 1.0);
    }
    let f0 = mix(vec3f(0.04), surface.color, surface.metal);
    let cosine = clamp(dot(surface.normal, hit.view), 0.0, 1.0);
    // Roughness limits the grazing reflectance of a broad lobe.
    let grazing = max(vec3f(1.0 - surface.roughness), f0);
    let specular = mix(f0, grazing, pow(1.0 - cosine, 5.0));
    return vec4f(specular, 1.0);
}

@fragment
fn path_fragment(input: PathVertex) -> @location(0) vec4f {
    let vUV = input.uv;
    // Pass 6 copies the specular distance into the single-channel texture required by NGX.
    if pu.u_Frame.y > 5.5 { return vec4f(textureSampleLevel(u_History, u_Nearest, vUV, 0.0).a, 0.0, 0.0, 1.0); }
    if pu.u_Frame.y > 4.5 { return rayReconstructionGuidePass(vUV); }
    if pu.u_Frame.y > 3.5 { return finalPass(vUV); }
    if pu.u_Frame.y > 2.5 { return waveletPass(vUV); }
    if pu.u_Frame.y > 1.5 { return guidePass(vUV); }
    if pu.u_Frame.y > 0.5 { return temporalPass(vUV); }
    let pixel = vec2u(input.position.xy);
    randomState = pixel.x * 1973u + pixel.y * 9277u + u32(pu.u_Frame.x) * 26699u + 911u;
    var color = vec3f(0.0);
    rrSpecularHitDistance = 0.0;
    let first = gbufferSurface(vUV);
    let hybrid = first.valid;
    if pu.u_Hybrid.x > 0.5 && !hybrid {
        // The raster pass drew nothing here: the sky. Never trace it, so path-tracing-only proxies stay invisible.
        let ndc = vUV * vec2f(2.0, -2.0) + vec2f(-1.0, 1.0);
        let nearPoint = pu.u_InverseProjection * vec4f(ndc, 0.0, 1.0);
        let farPoint = pu.u_InverseProjection * vec4f(ndc, 1.0, 1.0);
        let direction = normalize(viewRotation() * (farPoint.xyz / farPoint.w - nearPoint.xyz / nearPoint.w));
        let alpha = select(1.0, 0.0, pu.u_Hybrid.z > 0.5);
        return vec4f(clamp(sky(direction), vec3f(0.0), vec3f(pu.u_Trace.z)), alpha);
    }
    for (var sampleIndex = 0; sampleIndex < 8; sampleIndex++) {
        if sampleIndex >= i32(pu.u_Counts.z) {
            break;
        }
        if hybrid {
            var throughput = vec3f(1.0);
            var nextDirection: vec3f;
            var lighting = directLight(first.surface, first.view, 0, false);
            if i32(pu.u_Counts.w) > 1 {
                let pdf = scatter(first.surface, first.view, &throughput, &nextDirection, false);
                if pdf > 0.0 {
                    lighting += throughput * path(first.surface.position + first.surface.geometric * pu.u_Trace.y * 2.0, nextDirection, 1, pdf);
                }
            }
            // Clamp only the light: emission is added after, so demodulation removes it exactly.
            color += clamp(lighting, vec3f(0.0), vec3f(pu.u_Trace.z)) + first.surface.emission;
            continue;
        }
        let size = vec2f(textureDimensions(u_History, 0));
        let uv = vUV + (vec2f(randomValue(), randomValue()) - vec2f(0.5)) / size;
        let ndc = uv * vec2f(2.0, -2.0) + vec2f(-1.0, 1.0);
        let nearPoint = pu.u_InverseProjection * vec4f(ndc, 0.0, 1.0);
        let farPoint = pu.u_InverseProjection * vec4f(ndc, 1.0, 1.0);
        let viewOrigin = nearPoint.xyz / nearPoint.w;
        let direction = normalize(viewRotation() * (farPoint.xyz / farPoint.w - viewOrigin));
        let origin = (pu.u_InverseView * vec4f(viewOrigin, 1.0)).xyz;
        color += clamp(path(origin, direction, 0, 0.0), vec3f(0.0), vec3f(pu.u_Trace.z));
    }
    color = color / pu.u_Counts.z;
    if pu.u_Denoise.z > 0.5 {
        // Denoisers filter light without the surface's own colour and emission; the final pass restores both.
        return vec4f(max(color - emissionAt(vUV), vec3f(0.0)) / demodulation(vUV), 1.0);
    }
    // Plain accumulation of a still view (reference mode).
    if pu.u_Trace.w > 0.0 {
        color = mix(color, textureSampleLevel(u_History, u_Nearest, vUV, 0.0).rgb, pu.u_Trace.w / (pu.u_Trace.w + 1.0));
    }
    return vec4f(color, select(1.0, rrSpecularHitDistance, pu.u_Hybrid.z > 0.5));
}

@if(ADA_PATH_TRACING_CACHE)
fn radianceCacheLifetime() -> f32 {
    return select(CACHE_MAX_AGE, pu.u_Hybrid.w, pu.u_Hybrid.w > 0.0);
}

@if(ADA_PATH_TRACING_CACHE)
fn lookupRadianceCell(position: vec3f, normal: vec3f, minimumSamples: f32) -> RadianceCacheCell {
    let level = radianceCacheLevel(position, pu.u_InverseView[3].xyz);
    let key = radianceCacheKey(position, normal, level);
    let cell = u_CacheRead[radianceCacheIndex(key)];
    if radianceCacheCellMatches(cell, key, position, normal, pu.u_Frame.x, minimumSamples, radianceCacheLifetime()) {
        return cell;
    }
    return RadianceCacheCell();
}

@if(ADA_PATH_TRACING_CACHE)
fn useCachedBounce(s: Surface, distance: f32, previousPdf: f32) -> bool {
    let level = radianceCacheLevel(s.position, pu.u_InverseView[3].xyz);
    return s.receives && s.roughness >= 0.1 && s.metal <= 0.12 && previousPdf > 0.0 && previousPdf <= 1.0
        && dot(s.normal, s.geometric) >= 0.94 && distance > 1.732051 * radianceCacheCellSize(level);
}

@if(ADA_PATH_TRACING_CACHE_UPDATE)
fn cosineDirection(normal: vec3f) -> vec3f {
    let r = sqrt(randomValue());
    let phi = 2.0 * PI * randomValue();
    return normalize(basis(normal) * vec3f(r * cos(phi), r * sin(phi), sqrt(max(0.0, 1.0 - r * r))));
}

@if(ADA_PATH_TRACING_CACHE_UPDATE)
fn seedRadianceCache(probe: u32) {
    let grid = vec2u(64u, 64u);
    let tile = vec2u(probe % grid.x, probe / grid.x);
    let uv = (vec2f(tile) + vec2f(randomValue(), randomValue())) / vec2f(grid);
    let first = gbufferSurface(uv);
    if !first.valid { return; }
    let s = first.surface;
    let direction = cosineDirection(s.geometric);
    let origin = s.position + s.geometric * pu.u_Trace.y * 2.0;
    let hit = closestHit(origin, direction);
    if hit.triangle < 0 { return; }
    let surface = surfaceAt(hit.triangle, hit.barycentrics, origin, direction, hit.distance);
    let pdf = max(dot(s.geometric, direction), 0.0) / PI;
    if !useCachedBounce(surface, hit.distance, pdf) { return; }

    let normal = surface.geometric;
    let position = surface.position;
    let level = radianceCacheLevel(position, pu.u_InverseView[3].xyz);
    let key = radianceCacheKey(position, normal, level);
    let index = radianceCacheIndex(key);
    if pu.u_Transport.w > 0.5 {
        var cached = false;
        if pu.u_Transport.z < 0.5 {
            cached = lookupRadianceCell(position, normal, CACHE_MIN_SAMPLES).irradiance[0].w > 0.0;
        }
        atomicAdd(&u_CacheDiagnostics[select(1u, 0u, cached)], 1u);
    }
    if atomicCompareExchangeWeak(&u_CacheRequests[index].claimed, 0u, 1u).exchanged {
        u_CacheRequests[index].key = key;
        u_CacheRequests[index].position = vec4f(position, pu.u_Frame.x);
        u_CacheRequests[index].normal = vec4f(normal, 0.0);
    }
}

@if(ADA_PATH_TRACING_CACHE_UPDATE)
fn estimateDiffuseIrradiance(position: vec3f, normal: vec3f) -> RadianceCacheEstimate {
    // Hybrid tracing can first read the cache at bounce one. Skip unused deeper estimates.
    let depth = min(CACHE_DEPTHS, u32(pu.u_Counts.w) - 1u);
    var surface = Surface(position, normal, normal, vec3f(1.0), vec3f(0.0), 1.0, 0.0, true);
    var estimates: array<vec3f, CACHE_DEPTHS>;
    var accumulated = vec3f(0.0);
    var throughput = vec3f(1.0);
    for (var layer = 0u; layer < depth; layer++) {
        let direct = sampleDirectLight(surface, surface.normal, 1, layer + 1u < depth, true, false);
        estimates[layer] = accumulated + throughput * direct.radiance;
        if layer + 1u == depth { break; }

        accumulated += throughput * direct.continued;
        let direction = cosineDirection(surface.normal);
        let pdf = max(dot(surface.normal, direction), 0.0) / PI;
        if dot(surface.geometric, direction) <= 0.0 {
            for (var later = layer + 1u; later < depth; later++) { estimates[later] = accumulated; }
            break;
        }
        let origin = surface.position + surface.geometric * pu.u_Trace.y * 2.0;
        let hit = closestHit(origin, direction);
        if hit.triangle < 0 {
            accumulated += throughput * sky(direction) * PI;
            for (var later = layer + 1u; later < depth; later++) { estimates[later] = accumulated; }
            break;
        }
        surface = surfaceAt(hit.triangle, hit.barycentrics, origin, direction, hit.distance);
        if any(surface.emission > vec3f(0.0)) {
            accumulated += throughput * surface.emission * (PI * indirectEmissionWeight(hit, direction, pdf));
        }
        throughput *= surface.color * ((1.0 - surface.metal) * 0.96);
        // During motion or relighting, sample current visibility without feeding old bounces back into the cache.
        if pu.u_Transport.z == 0.0 && pu.u_Hybrid.w == 0.0 && useCachedBounce(surface, hit.distance, pdf) {
            let next = lookupRadianceCell(surface.position, surface.geometric, 1.0);
            if next.irradiance[0].w > 0.0 && next.normal.w == 0.0 {
                for (var later = layer + 1u; later < depth; later++) {
                    // A secondary hit consumes one interaction before reading a prior-frame stratum.
                    estimates[later] = accumulated + throughput * next.irradiance[later - layer - 1u].rgb;
                }
                break;
            }
        }
    }
    return estimates;
}

@if(ADA_PATH_TRACING_CACHE_UPDATE)
fn updateRadianceCache(index: u32) {
    let claim = atomicLoad(&u_CacheRequests[index].claimed);
    let relighting = pu.u_Transport.z < 0.0;
    let relightingLifetime = 48.0;
    let lifetime = select(relightingLifetime, pu.u_Hybrid.w, pu.u_Hybrid.w > 0.0);
    var previous: RadianceCacheCell;
    if pu.u_Transport.z < 0.5 {
        previous = u_CacheRead[index];
        if !radianceCacheCellIsFresh(previous, pu.u_Frame.x, radianceCacheLifetime()) {
            previous = RadianceCacheCell();
        }
    }
    if claim == 0u {
        if relighting && previous.irradiance[0].w > 0.0 {
            let previousLifetime = abs(previous.normal.w);
            let bounded = select(lifetime, min(lifetime, previousLifetime), previousLifetime > 0.0);
            previous.normal.w = -bounded;
            for (var layer = 0u; layer < CACHE_DEPTHS; layer++) {
                previous.irradiance[layer] = vec4f(previous.irradiance[layer].rgb * 0.93, previous.irradiance[layer].w);
            }
        }
        u_CacheWrite[index] = previous;
        return;
    }
    let key = u_CacheRequests[index].key;
    let position = u_CacheRequests[index].position.xyz;
    let normal = u_CacheRequests[index].normal.xyz;
    // The first refresh at rest starts a new estimate for this cell, so motion samples cannot linger at the still lifetime.
    let compatible = (pu.u_Hybrid.w > 0.0 || previous.normal.w == 0.0 || (relighting && previous.normal.w == -relightingLifetime))
        && radianceCacheCellMatches(previous, key, position, normal, pu.u_Frame.x, 1.0, radianceCacheLifetime());
    let probe = select(position, previous.position.xyz, compatible);
    let probeNormal = select(normal, previous.normal.xyz, compatible);
    let estimates = estimateDiffuseIrradiance(probe, probeNormal);
    let history = select(32.0, 4.0, pu.u_Hybrid.w > 0.0);
    let age = select(1.0, min(history, previous.irradiance[0].w + 1.0), compatible);
    var filtered: array<vec4f, CACHE_DEPTHS>;
    for (var layer = 0u; layer < CACHE_DEPTHS; layer++) {
        let irradiance = clamp(estimates[layer], vec3f(0.0), vec3f(PI * pu.u_Trace.z));
        let old = previous.irradiance[layer].rgb;
        let delta = length(irradiance - old) / max(0.2, length(old));
        let retainedSamples = max(age, min(32.0, 4.0 * previous.irradiance[0].w));
        let relightRate = max(0.045, 1.0 / retainedSamples);
        let sampleRate = select(1.0 / age, relightRate, relighting && compatible);
        let rate = max(sampleRate, 0.125 * clamp(delta - 1.0, 0.0, 1.0));
        filtered[layer] = vec4f(mix(old, irradiance, rate), age);
    }
    // Keep relit estimates out of recursive updates until refreshed with steady lighting.
    let probeLifetime = select(pu.u_Hybrid.w, -lifetime, relighting);
    u_CacheWrite[index] = RadianceCacheCell(key, filtered, vec4f(probe, pu.u_Frame.x), vec4f(probeNormal, probeLifetime));
    if pu.u_Transport.w > 0.5 { atomicAdd(&u_CacheDiagnostics[2], 1u); }
}

@if(ADA_PATH_TRACING_CACHE_UPDATE) @compute @workgroup_size(64, 1, 1)
fn cache_compute(@builtin(global_invocation_id) id: vec3u) {
    let index = id.x;
    if pu.u_Frame.y < 6.5 {
        if index < CACHE_CELLS { atomicStore(&u_CacheRequests[index].claimed, 0u); }
        if index < 3u && pu.u_Transport.z > 0.5 { atomicStore(&u_CacheDiagnostics[index], 0u); }
        return;
    }
    randomState = index * 1973u + u32(pu.u_Frame.x) * 26699u + 911u;
    if pu.u_Frame.y < 7.5 {
        if index < CACHE_PROBES { seedRadianceCache(index); }
        return;
    }
    if index < CACHE_CELLS { updateRadianceCache(index); }
}
