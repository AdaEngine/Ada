import ada_engine::view::projectPosition;
import package::sprite_surface::{SpriteVertex, shadeSprite};

// Shader Graph materials (ADA_SHADER_GRAPH) receive the generated graph source at this marker line.
// ADA_GRAPH_SOURCE_MARKER

@if(ADA_SHADER_GRAPH)
fn shadeGraphSprite(input: SpriteVertex) -> vec4f {
    let evaluated = ada_graph_evaluate(input.uv);
    var color = evaluated.color * input.color;
    color.a *= evaluated.alpha;
    // Slot zero holds the render settings: y alpha cutoff, z mode (0 opaque, 1 mask, otherwise blended).
    let settings = ada_graph_uniforms.values[0];
    if settings.z < 0.5 {
        color.a = 1.0;
    } else if settings.z < 1.5 {
        if color.a < settings.y {
            discard;
        }
        color.a = 1.0;
    }
    // Avoid depth writes for invisible texels.
    if color.a == 0.0 {
        discard;
    }
    return color;
}

@vertex
fn sprite_vertex(@location(0) position: vec4f, @location(1) color: vec4f, @location(2) uv: vec2f) -> SpriteVertex {
    return SpriteVertex(projectPosition(position), color, uv);
}

@fragment
fn sprite_fragment(input: SpriteVertex) -> @location(0) vec4f {
    @if(ADA_SHADER_GRAPH) {
        return shadeGraphSprite(input);
    }
    return shadeSprite(input);
}
