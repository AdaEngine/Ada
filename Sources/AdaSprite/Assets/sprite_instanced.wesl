import ada_engine::view::projectPosition;
import package::sprite_surface::{SpriteVertex, shadeSprite};

@vertex
fn sprite_instanced_vertex(
    @location(0) corner: vec2f,
    @location(1) origin: vec4f,
    @location(2) axisX: vec4f,
    @location(3) axisY: vec4f,
    @location(4) color: vec4f,
    @location(5) bottomUV: vec4f,
    @location(6) topUV: vec4f,
) -> SpriteVertex {
    let bottom = mix(bottomUV.xy, bottomUV.zw, corner.x);
    let top = mix(topUV.xy, topUV.zw, corner.x);
    let uv = mix(bottom, top, corner.y);
    let position = origin + corner.x * axisX + corner.y * axisY;
    return SpriteVertex(projectPosition(position), color, uv);
}

@fragment
fn sprite_instanced_fragment(input: SpriteVertex) -> @location(0) vec4f {
    return shadeSprite(input);
}
