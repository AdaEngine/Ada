// WESL port of Public/Morph.glsl. Morph targets (glTF blend shapes) applied before skinning.
// Declared only for draws of morphed meshes, which enable the ADA_MORPH feature.

struct Morph3DUniform {
    u_MorphCounts: vec4f,              // x active targets, y previous frame's, z vertices per target, w attributes per vertex
    u_MorphFlags: vec4f,               // x bit 0: normal deltas, bit 1: tangent deltas
    u_MorphCurrent: array<vec4f, 8>,   // x target index, y weight
    u_MorphPrevious: array<vec4f, 8>,  // previous frame's, for motion vectors
}

struct MorphedVertex {
    position: vec3f,
    normal: vec3f,
    tangent: vec3f,
}

@if(ADA_MORPH) @group(0) @binding(21) var<uniform> morph: Morph3DUniform;
@if(ADA_MORPH) @group(0) @binding(40) var u_MorphDeltas: texture_2d<f32>;

const MORPH_TEXTURE_WIDTH: i32 = 2048;

@if(ADA_MORPH)
fn morphDelta(vertexIndex: u32, morphTarget: i32, channel: i32) -> vec3f {
    let texel = (morphTarget * i32(morph.u_MorphCounts.z) + i32(vertexIndex)) * i32(morph.u_MorphCounts.w) + channel;
    return textureLoad(u_MorphDeltas, vec2i(texel % MORPH_TEXTURE_WIDTH, texel / MORPH_TEXTURE_WIDTH), 0).xyz;
}

@if(ADA_MORPH)
fn applyMorphPosition(vertexIndex: u32, input: vec3f) -> vec3f {
    var position = input;
    for (var i = 0; i < 8; i++) {
        if i >= i32(morph.u_MorphCounts.x) {
            break;
        }
        position += morphDelta(vertexIndex, i32(morph.u_MorphCurrent[i].x), 0) * morph.u_MorphCurrent[i].y;
    }
    return position;
}

@if(ADA_MORPH)
fn previousMorphedPosition(vertexIndex: u32, input: vec3f) -> vec3f {
    var position = input;
    for (var i = 0; i < 8; i++) {
        if i >= i32(morph.u_MorphCounts.y) {
            break;
        }
        position += morphDelta(vertexIndex, i32(morph.u_MorphPrevious[i].x), 0) * morph.u_MorphPrevious[i].y;
    }
    return position;
}

@if(ADA_MORPH)
fn applyMorph(vertexIndex: u32, position: vec3f, normal: vec3f, tangent: vec3f) -> MorphedVertex {
    var result = MorphedVertex(position, normal, tangent);
    let flags = i32(morph.u_MorphFlags.x);
    let hasNormals = (flags & 1) != 0;
    let hasTangents = (flags & 2) != 0;
    let tangentChannel = select(1, 2, hasNormals);
    for (var i = 0; i < 8; i++) {
        if i >= i32(morph.u_MorphCounts.x) {
            break;
        }
        let morphTarget = i32(morph.u_MorphCurrent[i].x);
        let weight = morph.u_MorphCurrent[i].y;
        result.position += morphDelta(vertexIndex, morphTarget, 0) * weight;
        if hasNormals {
            result.normal += morphDelta(vertexIndex, morphTarget, 1) * weight;
        }
        if hasTangents {
            result.tangent += morphDelta(vertexIndex, morphTarget, tangentChannel) * weight;
        }
    }
    return result;
}
