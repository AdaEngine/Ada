// Shared ABI and math of the cloud noise passes. All noise is periodic, so the atlases tile in every dimension.
struct CloudNoiseUniform {
    // x and y: the low and high 16 bits of the mixed seed.
    seed: vec4f,
    // x: tile size in texels, y: tiles per row, z: slice count.
    size: vec4f,
}

@group(0) @binding(4) var<uniform> noise: CloudNoiseUniform;

fn pcg3d(input: vec3u) -> vec3u {
    var v = input * 1664525u + 1013904223u;
    v.x += v.y * v.z;
    v.y += v.z * v.x;
    v.z += v.x * v.y;
    v ^= v >> vec3u(16u);
    v.x += v.y * v.z;
    v.y += v.z * v.x;
    v.z += v.x * v.y;
    return v;
}

// A random vector in [0, 1)^3 for a lattice cell, wrapped to the period and mixed with the seed.
fn cellHash(cell: vec3i, period: i32) -> vec3f {
    let wrapped = vec3u(((cell % vec3i(period)) + vec3i(period)) % vec3i(period));
    let seed = u32(noise.seed.x) | (u32(noise.seed.y) << 16u);
    let mixed = wrapped + vec3u(seed, seed * 747796405u + 2891336453u, seed ^ 2779096485u);
    return vec3f(pcg3d(mixed) >> vec3u(8u)) / 16777216.0;
}

// Periodic gradient noise remapped to roughly 0 to 1.
fn gradientNoise(p: vec3f, period: i32) -> f32 {
    let base = vec3i(floor(p));
    let f = fract(p);
    let u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
    var result = 0.0;
    for (var z = 0; z < 2; z++) {
        var planeY = vec2f(0.0);
        for (var y = 0; y < 2; y++) {
            var line = vec2f(0.0);
            for (var x = 0; x < 2; x++) {
                let offset = vec3i(x, y, z);
                let gradient = normalize(cellHash(base + offset, period) * 2.0 - 1.0 + vec3f(0.0001));
                line[x] = dot(gradient, f - vec3f(offset));
            }
            planeY[y] = mix(line.x, line.y, u.x);
        }
        let plane = mix(planeY.x, planeY.y, u.y);
        result = select(plane, mix(result, plane, u.z), z == 1);
    }
    return clamp(result * 0.8 + 0.5, 0.0, 1.0);
}

// Periodic Worley noise, inverted so it is brightest at the cell centres.
fn worleyNoise(p: vec3f, period: i32) -> f32 {
    let base = vec3i(floor(p));
    let f = fract(p);
    var nearest = 4.0;
    for (var z = -1; z <= 1; z++) {
        for (var y = -1; y <= 1; y++) {
            for (var x = -1; x <= 1; x++) {
                let offset = vec3i(x, y, z);
                let feature = vec3f(offset) + cellHash(base + offset, period);
                let delta = f - feature;
                nearest = min(nearest, dot(delta, delta));
            }
        }
    }
    return clamp(1.0 - sqrt(nearest), 0.0, 1.0);
}

// The position of a texel inside the volume: x and y inside its tile, z from the slice. Each in (0, 1).
fn atlasCoordinate(pixel: vec2f) -> vec3f {
    let tile = noise.size.x;
    let columns = noise.size.y;
    let slices = noise.size.z;
    let column = floor(pixel.x / tile);
    let row = floor(pixel.y / tile);
    let slice = row * columns + column;
    let local = (pixel - vec2f(column, row) * tile) / tile;
    return vec3f(local, (slice + 0.5) / slices);
}
