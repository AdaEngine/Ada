import package::fullscreen::{FullscreenVertex, fullscreenVertex};
import package::environment_composite::{
    sceneColor, normalRoughness, viewPositionMetallic, linearSampler, gBufferSampler, environment, presentColor, applyFog,
};

@vertex
fn ssr_vertex(@builtin(vertex_index) index: u32) -> FullscreenVertex {
    return fullscreenVertex(index);
}

@fragment
fn path_composite_fragment(input: FullscreenVertex) -> @location(0) vec4f {
    let uv = input.uv;
    let color = textureSampleLevel(sceneColor, linearSampler, uv, 0.0).rgb;
    var position = textureSampleLevel(viewPositionMetallic, gBufferSampler, uv, 0.0).xyz;
    let normal = textureSampleLevel(normalRoughness, gBufferSampler, uv, 0.0).xyz;
    let isSky = dot(normal, normal) < 0.01 || dot(position, position) < 0.000001;
    if isSky {
        let farPoint = environment.inverseProjection * vec4f(uv * vec2f(2.0, -2.0) + vec2f(-1.0, 1.0), 1.0, 1.0);
        position = normalize(farPoint.xyz / farPoint.w) * 1000.0;
    }
    let fogged = applyFog(color, position, select(1.0, environment.fogRange.x, isSky), isSky, uv);
    return vec4f(presentColor(fogged, uv, input.position.xy), 1.0);
}
