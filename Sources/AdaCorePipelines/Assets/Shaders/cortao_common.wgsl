// Shared helpers for the CORTAO passes.
// Adapted from https://github.com/theagentd/CORTAO, Copyright (c) 2026 Daniel Isheden, MIT License. See CORTAO-LICENSE.txt.

fn cortaoSeed(coords: vec2u) -> u32 {
    let q = coords * vec2u(1719413u * 929u, 140473u * 2467u * 11u);
    return q.x ^ q.y;
}

fn cortaoHash(n: u32) -> u32 {
    return n * (n ^ (n >> 15u));
}

// The G-buffer is left-handed (+Z forward). The spheremap is singular towards -Z, which is where camera-facing
// normals point here, so the encoding runs in a space with the Z axis flipped.
fn cortaoEncodeNormal(normal: vec3f) -> vec2f {
    let flipped = vec3f(normal.x, normal.y, -normal.z);
    return flipped.xy * inverseSqrt(max(flipped.z * 2.0 + 2.0, 0.00001));
}

fn cortaoDecodeNormal(encoded: vec2f) -> vec3f {
    let z = max(1.0 - dot(encoded, encoded), 0.0);
    let flipped = vec3f(encoded * (2.0 * sqrt(z)), z * 2.0 - 1.0);
    return vec3f(flipped.x, flipped.y, -flipped.z);
}

// Octahedral unit-vector encoding: a direction in two components in [-1, 1].
fn cortaoOctEncode(n: vec3f) -> vec2f {
    let p = n.xy / (abs(n.x) + abs(n.y) + abs(n.z));
    if n.z < 0.0 {
        return (vec2f(1.0) - abs(p.yx)) * select(vec2f(-1.0), vec2f(1.0), p >= vec2f(0.0));
    }
    return p;
}

fn cortaoOctDecode(e: vec2f) -> vec3f {
    var n = vec3f(e.x, e.y, 1.0 - abs(e.x) - abs(e.y));
    if n.z < 0.0 {
        let folded = (vec2f(1.0) - abs(n.yx)) * select(vec2f(-1.0), vec2f(1.0), n.xy >= vec2f(0.0));
        n = vec3f(folded.x, folded.y, n.z);
    }
    return normalize(n);
}
