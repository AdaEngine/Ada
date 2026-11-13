import ada_engine::view::projectPosition;

struct SpineVertex {
    @builtin(position) position: vec4f,
    @location(0) lightColor: vec4f,
    @location(1) uv: vec2f,
    @location(2) darkColor: vec4f,
}

@group(0) @binding(0) var atlas: texture_2d<f32>;
@group(0) @binding(1) var atlasSampler: sampler;

@vertex
fn spine_vertex(
    @location(0) position: vec4f,
    @location(1) lightColor: vec4f,
    @location(2) uv: vec2f,
    @location(3) darkColor: vec4f,
) -> SpineVertex {
    return SpineVertex(projectPosition(position), lightColor, uv, darkColor);
}

@fragment
fn spine_fragment(input: SpineVertex) -> @location(0) vec4f {
    let texel = textureSample(atlas, atlasSampler, input.uv);
    let darkWeight = vec3f(mix(1.0, texel.a, input.darkColor.a)) - texel.rgb;
    let color = vec4f(texel.rgb * input.lightColor.rgb + darkWeight * input.darkColor.rgb, texel.a * input.lightColor.a);
    if color.a == 0.0 {
        discard;
    }
    return color;
}
