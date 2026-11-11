import ada_engine::view::projectPosition;

struct TextVertex {
    @builtin(position) position: vec4f,
    @location(0) foreground: vec4f,
    @location(1) outline: vec4f,
    @location(2) outlineWidth: f32,
    @location(3) uv: vec2f,
}

@group(0) @binding(0) var fontAtlas: texture_2d<f32>;
@group(0) @binding(1) var fontSampler: sampler;

@vertex
fn text_vertex(
    @location(0) position: vec4f,
    @location(1) foreground: vec4f,
    @location(2) outline: vec4f,
    @location(3) outlineWidth: f32,
    @location(4) uv: vec2f,
) -> TextVertex {
    return TextVertex(projectPosition(position), foreground, outline, outlineWidth, uv);
}

fn screenPixelRange(uv: vec2f) -> f32 {
    // Keep this in sync with FontAtlasGenerator.atlasPixelRange.
    let unitRange = vec2f(4.0) / vec2f(textureDimensions(fontAtlas, 0));
    let screenSize = vec2f(1.0) / fwidth(uv);
    return max(0.5 * dot(unitRange, screenSize), 1.0);
}

fn medianDistance(msd: vec3f) -> f32 {
    return max(min(msd.r, msd.g), min(max(msd.r, msd.g), msd.b));
}

@fragment
fn text_fragment(input: TextVertex) -> @location(0) vec4f {
    let msd = textureSample(fontAtlas, fontSampler, input.uv).rgb;
    let distance = screenPixelRange(input.uv) * (medianDistance(msd) - 0.5);
    let fillAlpha = clamp(distance + 0.5, 0.0, 1.0) * input.foreground.a;
    let outlineAlpha = clamp(distance + input.outlineWidth + 0.5, 0.0, 1.0) * input.outline.a;
    let visibleOutline = outlineAlpha * (1.0 - fillAlpha);
    let alpha = fillAlpha + visibleOutline;
    let premultiplied = input.foreground.rgb * fillAlpha + input.outline.rgb * visibleOutline;
    // The pipeline blends straight-alpha RGB.
    if alpha > 0.0 {
        return vec4f(premultiplied / alpha, alpha);
    }
    return vec4f(vec3f(0.0), alpha);
}
