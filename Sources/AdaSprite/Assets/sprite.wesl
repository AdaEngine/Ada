import ada_engine::view::projectPosition;
import package::sprite_surface::{SpriteVertex, shadeSprite};

@vertex
fn sprite_vertex(@location(0) position: vec4f, @location(1) color: vec4f, @location(2) uv: vec2f) -> SpriteVertex {
    return SpriteVertex(projectPosition(position), color, uv);
}

@fragment
fn sprite_fragment(input: SpriteVertex) -> @location(0) vec4f {
    return shadeSprite(input);
}
