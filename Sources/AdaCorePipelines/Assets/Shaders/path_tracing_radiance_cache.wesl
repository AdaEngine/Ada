const CACHE_CELLS: u32 = 16384u;
const CACHE_PROBES: u32 = 4096u;
const CACHE_DEPTHS: u32 = 4u;
const CACHE_MAX_AGE: f32 = 96.0;
const CACHE_MIN_SAMPLES: f32 = 2.0;

alias RadianceCacheEstimate = array<vec3f, CACHE_DEPTHS>;

struct RadianceCacheCell {
    key: vec4i,
    irradiance: array<vec4f, CACHE_DEPTHS>, // index: remaining interactions minus one; rgb: irradiance, a: sample count
    position: vec4f, // xyz: probe position, a: last update frame
    normal: vec4f, // w: optional short lifetime, negative when the probe carries relighting history
}

struct RadianceCacheRequest {
    claimed: atomic<u32>,
    key: vec4i,
    position: vec4f,
    normal: vec4f,
}

fn radianceCacheLevel(position: vec3f, camera: vec3f) -> i32 {
    return i32(clamp(floor(log2(1.0 + distance(position, camera) / 15.0)), 0.0, 5.0));
}

fn radianceCacheCellSize(level: i32) -> f32 {
    return 0.18 * exp2(f32(level));
}

fn radianceCacheKey(position: vec3f, normal: vec3f, level: i32) -> vec4i {
    let quantized = vec3i(round(normal * 4.0)) + vec3i(4);
    let direction = quantized.x + quantized.y * 9 + quantized.z * 81;
    return vec4i(vec3i(floor(position / radianceCacheCellSize(level))), direction + level * 729);
}

fn radianceCacheIndex(key: vec4i) -> u32 {
    let words = bitcast<vec4u>(key);
    var h = (words.x * 0x8da6b343u) ^ (words.y * 0xd8163841u) ^ (words.z * 0xcb1ab31fu) ^ (words.w * 0x9e3779b9u);
    h = (h ^ (h >> 16u)) * 0x7feb352du;
    h = (h ^ (h >> 15u)) * 0x846ca68bu;
    return (h ^ (h >> 16u)) & (CACHE_CELLS - 1u);
}

fn radianceCacheCellMatches(cell: RadianceCacheCell, key: vec4i, position: vec3f, normal: vec3f, frame: f32, minimumSamples: f32, maximumAge: f32) -> bool {
    let level = key.w / 729;
    return cell.irradiance[0].w >= minimumSamples && all(cell.key == key)
        && radianceCacheCellIsFresh(cell, frame, maximumAge)
        && dot(normal, cell.normal.xyz) > 0.94
        && abs(dot(cell.position.xyz - position, normal)) <= 0.08 * radianceCacheCellSize(level)
        && distance(cell.position.xyz, position) <= radianceCacheCellSize(level);
}

fn radianceCacheCellIsFresh(cell: RadianceCacheCell, frame: f32, maximumAge: f32) -> bool {
    let lifetime = abs(cell.normal.w);
    let age = select(maximumAge, min(lifetime, maximumAge), lifetime > 0.0);
    return frame >= cell.position.w && frame - cell.position.w <= age;
}
