struct SpriteVertex {
    @builtin(position) position: vec4f,
    @location(0) color: vec4f,
    @location(1) uv: vec2f,
}

@group(0) @binding(0) var spriteImage: texture_2d<f32>;
@group(0) @binding(1) var spriteSampler: sampler;

fn shadeSprite(input: SpriteVertex) -> vec4f {
    let color = textureSample(spriteImage, spriteSampler, input.uv) * input.color;
    if color.a == 0.0 {
        discard;
    }
    return color;
}
