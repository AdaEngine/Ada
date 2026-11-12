// WESL port of path_tracing_3d.glsl. One fullscreen pass selected by `pu.u_Frame.y`:
// 0 trace, 1 temporal, 2 guide, 3 wavelet denoise, 4 reconstruct, 5 Ray Reconstruction guides.

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
    u_Hybrid: vec4f, // x: first hit from the raster G-buffer
    u_PreviousViewProjection: mat4x4f, // unjittered, previous frame of this view
    u_PreviousView: mat4x4f,
    u_Denoise: vec4f, // x: wavelet step, y: minimum history weight, z: trace writes demodulated light, w: final remodulates
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

const PI: f32 = 3.141592653589793;

var<private> randomState: u32;

fn randomValue() -> f32 {
    randomState = randomState * 747796405u + 2891336453u;
    let word = ((randomState >> ((randomState >> 28u) + 4u)) ^ randomState) * 277803737u;
    return f32((word >> 22u) ^ word) / 4294967296.0;
}

fn texelCoordinate(index: i32) -> vec2i {
    return vec2i(index % 2048, index / 2048);
}
fn tri(index: i32) -> vec4f { return textureLoad(u_Triangles, texelCoordinate(index), 0); }
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
            let uv = tri(index + 6).xy * weights.x + tri(index + 7).xy * weights.y + tri(index + 8).xy * weights.z;
            let alpha = material(m).w * atlas(material(m + 3).x, uv).a;
            let mode = i32(material(m + 4).x);
            if mode == 1 && alpha < material(m + 2).z {
                continue;
            }
            if mode == 2 && randomValue() > alpha {
                continue;
            }
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
    s.receives = (i32(tri(hit + 1).w) & 2) != 0;
    return s;
}

fn fresnel(f0: vec3f, cosine: f32) -> vec3f {
    return f0 + (vec3f(1.0) - f0) * pow(1.0 - clamp(cosine, 0.0, 1.0), 5.0);
}

fn brdf(s: Surface, view: vec3f, direction: vec3f) -> vec3f {
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
    return ((vec3f(1.0) - f) * (1.0 - s.metal) * s.color / PI + f * d * gv * gl / max(4.0 * nv * nl, 0.0001)) * nl;
}

fn sampleLight(s: Surface, view: vec3f, selectedIndex: i32) -> vec3f {
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
            return vec3f(0.0);
        }
        direction = delta / distance;
        let cutoff = max(0.0, 1.0 - pow(distance / b.w, 4.0));
        attenuation = cutoff * cutoff / max(distance * distance, 0.01);
        if a.w > 1.5 {
            attenuation *= smoothstep(d.y, d.x, dot(-direction, normalize(c.xyz)));
        }
    }
    if dot(s.normal, direction) <= 0.0 || dot(s.geometric, direction) <= 0.0 {
        return vec3f(0.0);
    }
    if s.receives && c.w > 0.5 {
        var maximum = max(pu.u_Trace.y, distance - pu.u_Trace.y * 2.0);
        var bary: vec3f;
        if intersectScene(s.position + s.geometric * pu.u_Trace.y * 2.0, direction, &maximum, &bary, true) >= 0 {
            return vec3f(0.0);
        }
    }
    return brdf(s, view, direction) * max(b.rgb, vec3f(0.0)) * attenuation;
}

fn directLight(s: Surface, view: vec3f) -> vec3f {
    // Deterministic enumeration removes light-selection noise from the small authored game light set.
    var result = vec3f(0.0);
    for (var index = 0; index < i32(pu.u_Counts.y); index++) {
        result += sampleLight(s, view, index);
    }
    return result;
}

// Samples the next direction from a diffuse/GGX mixture and updates the throughput; false ends the path.
fn scatter(s: Surface, view: vec3f, throughput: ptr<function, vec3f>, nextDirection: ptr<function, vec3f>) -> bool {
    let f0 = mix(vec3f(0.04), s.color, s.metal);
    let chance = clamp(max(f0.r, max(f0.g, f0.b)), 0.1, 0.9);
    if randomValue() < chance {
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
    let nl = dot(s.normal, *nextDirection);
    if nl <= 0.0 || dot(s.geometric, *nextDirection) <= 0.0 {
        return false;
    }
    let h = normalize(view + *nextDirection);
    let nh = max(dot(s.normal, h), 0.0);
    let a = s.roughness * s.roughness;
    let a2 = a * a;
    let denominator = nh * nh * (a2 - 1.0) + 1.0;
    let d = a2 / max(PI * denominator * denominator, 1e-10);
    let pdf = (1.0 - chance) * nl / PI + chance * d * nh / max(4.0 * abs(dot(view, h)), 0.00001);
    *throughput = *throughput * (brdf(s, view, *nextDirection) / max(pdf, 1e-8));
    return true;
}

// Traces from `origin`; `firstBounce` counts interactions already shaded by the caller.
fn path(originIn: vec3f, directionIn: vec3f, firstBounce: i32) -> vec3f {
    var origin = originIn;
    var direction = directionIn;
    var throughput = vec3f(1.0);
    var radiance = vec3f(0.0);
    for (var bounce = firstBounce; bounce < 8; bounce++) {
        if bounce >= i32(pu.u_Counts.w) {
            break;
        }
        var distance = pu.u_Trace.x;
        var bary: vec3f;
        let hit = intersectScene(origin, direction, &distance, &bary, false);
        if hit < 0 {
            radiance += throughput * sky(direction);
            break;
        }
        let s = surfaceAt(hit, bary, origin, direction, distance);
        radiance += throughput * (s.emission + directLight(s, -direction));
        var nextDirection: vec3f;
        if !scatter(s, -direction, &throughput, &nextDirection) {
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
    let sigma = 4.0 * sqrt(max(square / 9.0 - mean * mean, 0.0)) + 0.0001;
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
    let normal = textureSampleLevel(u_Normal, u_Nearest, vUV, 0.0);
    if dot(normal.xyz, normal.xyz) < 0.01 {
        return vec4f(0.0);
    }
    if pu.u_Denoise.x > 1.5 {
        return vec4f(normalize(viewRotation() * normal.xyz), normal.w);
    }
    let base = textureSampleLevel(u_Albedo, u_Nearest, vUV, 0.0).rgb;
    let metal = textureSampleLevel(u_Position, u_Nearest, vUV, 0.0).w;
    return vec4f(select(mix(vec3f(0.04), base, metal), base * (1.0 - metal), pu.u_Denoise.x < 0.5), 1.0);
}

@fragment
fn path_fragment(input: PathVertex) -> @location(0) vec4f {
    let vUV = input.uv;
    // Pass 0 traces; 1 temporal, 2 guide and 3 wavelet denoise; 4 reconstructs the output; 5 writes RR guides.
    if pu.u_Frame.y > 4.5 { return rayReconstructionGuidePass(vUV); }
    if pu.u_Frame.y > 3.5 { return finalPass(vUV); }
    if pu.u_Frame.y > 2.5 { return waveletPass(vUV); }
    if pu.u_Frame.y > 1.5 { return guidePass(vUV); }
    if pu.u_Frame.y > 0.5 { return temporalPass(vUV); }
    let pixel = vec2u(input.position.xy);
    randomState = pixel.x * 1973u + pixel.y * 9277u + u32(pu.u_Frame.x) * 26699u + 911u;
    var color = vec3f(0.0);
    let first = gbufferSurface(vUV);
    let hybrid = first.valid;
    if pu.u_Hybrid.x > 0.5 && !hybrid {
        // The raster pass drew nothing here: the sky. Never trace it, so path-tracing-only proxies stay invisible.
        let ndc = vUV * vec2f(2.0, -2.0) + vec2f(-1.0, 1.0);
        let nearPoint = pu.u_InverseProjection * vec4f(ndc, 0.0, 1.0);
        let farPoint = pu.u_InverseProjection * vec4f(ndc, 1.0, 1.0);
        let direction = normalize(viewRotation() * (farPoint.xyz / farPoint.w - nearPoint.xyz / nearPoint.w));
        return vec4f(clamp(sky(direction), vec3f(0.0), vec3f(pu.u_Trace.z)), 1.0);
    }
    for (var sampleIndex = 0; sampleIndex < 8; sampleIndex++) {
        if sampleIndex >= i32(pu.u_Counts.z) {
            break;
        }
        if hybrid {
            var throughput = vec3f(1.0);
            var nextDirection: vec3f;
            var lighting = directLight(first.surface, first.view);
            if i32(pu.u_Counts.w) > 1 && scatter(first.surface, first.view, &throughput, &nextDirection) {
                lighting += throughput * path(first.surface.position + first.surface.geometric * pu.u_Trace.y * 2.0, nextDirection, 1);
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
        color += clamp(path(origin, direction, 0), vec3f(0.0), vec3f(pu.u_Trace.z));
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
    return vec4f(color, 1.0);
}
