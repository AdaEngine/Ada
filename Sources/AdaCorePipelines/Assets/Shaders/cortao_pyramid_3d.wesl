// CORTAO prepass: builds the depth/normal pyramid for the main pass in one dispatch.
//
// Adapted from https://github.com/theagentd/CORTAO, Copyright (c) 2026 Daniel Isheden, MIT License. See CORTAO-LICENSE.txt.
//
// Each texel holds (view depth, spheremap normal.xy, source pixel index within the 16x16 tile). Level 0 comes from the G-buffer. Every higher level keeps
// one pseudo-randomly chosen texel of each 2x2 block rather than an average, so silhouettes stay sharp, exactly
// as the reference prepass does. A 16x16 workgroup produces levels 0...3 for its tile through shared memory.
// Compute shaders may bind at most four storage textures, which caps the pyramid at four levels.
import package::cortao_common::{cortaoDecodeNormal, cortaoEncodeNormal, cortaoHash, cortaoSeed};

@group(0) @binding(0) var positionImage: texture_2d<f32>;
@group(0) @binding(1) var normalImage: texture_2d<f32>;
@group(0) @binding(2) var level0: texture_storage_2d<rgba16float, write>;
@group(0) @binding(3) var level1: texture_storage_2d<rgba16float, write>;
@group(0) @binding(4) var level2: texture_storage_2d<rgba16float, write>;
@group(0) @binding(5) var level3: texture_storage_2d<rgba16float, write>;

var<workgroup> tile: array<vec4f, 256>;

fn baseTexel(pixel: vec2i, size: vec2i, tileIndex: u32) -> vec4f {
    if any(pixel >= size) {
        return vec4f(0.0);
    }
    let position = textureLoad(positionImage, pixel, 0);
    let normal = textureLoad(normalImage, pixel, 0).xyz;
    if position.z <= 0.0 || length(normal) < 0.1 {
        return vec4f(0.0);
    }
    // w records which pixel of the 16x16 tile the texel came from. Higher levels keep one pixel of each block, and the
    // main pass unprojects from that pixel's centre, so the stored depth belongs exactly to the reconstructed position.
    return vec4f(position.z, cortaoEncodeNormal(normalize(normal)), f32(tileIndex));
}

// Picks one pseudo-random texel of the 2x2 block starting at `blockStart` in the previous level, which the tile
// stores with `stride` texels per row. `coords` is the output texel's position in its own level.
fn pick(coords: vec2u, blockStart: vec2u, level: u32, stride: u32) -> vec4f {
    let h = cortaoHash(cortaoSeed(coords + vec2u(level * 7919u)));
    let choice = vec2u(h & 1u, (h >> 1u) & 1u);
    let source = blockStart + choice;
    return tile[source.y * stride + source.x];
}

@compute @workgroup_size(16, 16)
fn cortao_pyramid(
    @builtin(local_invocation_id) local: vec3u,
    @builtin(workgroup_id) group: vec3u
) {
    let size = vec2i(textureDimensions(level0));
    let origin = group.xy * 16u;
    let pixel = origin + local.xy;

    // Level 0: the tile occupies tile[0..<256], row stride 16.
    let base = baseTexel(vec2i(pixel), size, local.y * 16u + local.x);
    tile[local.y * 16u + local.x] = base;
    if all(vec2i(pixel) < size) {
        textureStore(level0, vec2i(pixel), base);
    }
    workgroupBarrier();

    // Each level is read into registers, then a barrier separates those reads from the in-place overwrite of
    // the tile by the level just computed. Level k is written by the top-left (16 >> k) square of threads.
    var texel1 = vec4f(0.0);
    if all(local.xy < vec2u(8u)) {
        texel1 = pick((origin >> vec2u(1u)) + local.xy, local.xy * 2u, 1u, 16u);
    }
    workgroupBarrier();
    if all(local.xy < vec2u(8u)) {
        tile[local.y * 8u + local.x] = texel1;
        let coords = vec2i((origin >> vec2u(1u)) + local.xy);
        if all(coords < vec2i(textureDimensions(level1))) {
            textureStore(level1, coords, texel1);
        }
    }
    workgroupBarrier();

    var texel2 = vec4f(0.0);
    if all(local.xy < vec2u(4u)) {
        texel2 = pick((origin >> vec2u(2u)) + local.xy, local.xy * 2u, 2u, 8u);
    }
    workgroupBarrier();
    if all(local.xy < vec2u(4u)) {
        tile[local.y * 4u + local.x] = texel2;
        let coords = vec2i((origin >> vec2u(2u)) + local.xy);
        if all(coords < vec2i(textureDimensions(level2))) {
            textureStore(level2, coords, texel2);
        }
    }
    workgroupBarrier();

    var texel3 = vec4f(0.0);
    if all(local.xy < vec2u(2u)) {
        texel3 = pick((origin >> vec2u(3u)) + local.xy, local.xy * 2u, 3u, 4u);
    }
    workgroupBarrier();
    if all(local.xy < vec2u(2u)) {
        tile[local.y * 2u + local.x] = texel3;
        let coords = vec2i((origin >> vec2u(3u)) + local.xy);
        if all(coords < vec2i(textureDimensions(level3))) {
            textureStore(level3, coords, texel3);
        }
    }
}
