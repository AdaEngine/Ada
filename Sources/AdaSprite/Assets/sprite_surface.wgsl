struct SpriteVertex {
    @builtin(position) position: vec4f,
    @location(0) color: vec4f,
    @location(1) uv: vec2f,
}

// The names match what Shader Graph sprite nodes emit (`textureSample(u_Texture, u_Sampler, ...)`).
@group(0) @binding(0) var u_Texture: texture_2d<f32>;
@group(0) @binding(1) var u_Sampler: sampler;

fn shadeSprite(input: SpriteVertex) -> vec4f {
    let color = textureSample(u_Texture, u_Sampler, input.uv) * input.color;
    if color.a == 0.0 {
        discard;
    }
    return color;
}
