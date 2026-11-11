struct MorphUniform {
    counts: vec4f,
    flags: vec4f,
    current: array<vec4f, 8>,
    previous: array<vec4f, 8>,
}

@group(0) @binding(21) var<uniform> morph: MorphUniform;
@group(0) @binding(40) var morphDeltas: texture_2d<f32>;

const MORPH_TEXTURE_WIDTH: u32 = 2048u;

fn morphPosition(position: vec3f, vertexIndex: u32, previous: bool) -> vec3f {
    var result = position;
    let count = u32(select(morph.counts.x, morph.counts.y, previous));
    for (var index = 0u; index < min(8u, count); index++) {
        let weightedTarget = select(morph.current[index], morph.previous[index], previous);
        let texel = (u32(weightedTarget.x) * u32(morph.counts.z) + vertexIndex) * u32(morph.counts.w);
        let coordinates = vec2i(i32(texel % MORPH_TEXTURE_WIDTH), i32(texel / MORPH_TEXTURE_WIDTH));
        result += textureLoad(morphDeltas, coordinates, 0).xyz * weightedTarget.y;
    }
    return result;
}
