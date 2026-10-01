// WGSL counterpart of ui_shadow.glsl; uniform layout and alpha model are identical.
struct UIShadowMaterial {
    u_Color: vec4f,
    u_Geometry: vec4f,
    u_Style: vec4f,
}
@group(0) @binding(0) var<uniform> material: UIShadowMaterial;

fn roundedBoxDistance(point: vec2f, halfSize: vec2f, radius: f32) -> f32 {
    let offset = abs(point) - halfSize + vec2f(radius);
    return length(max(offset, vec2f(0.0))) + min(max(offset.x, offset.y), 0.0) - radius;
}

@fragment
fn ui_shadow_fragment(
    @location(0) worldPosition: vec4f,
    @location(1) worldNormal: vec3f,
    @location(2) uv: vec2f,
    @location(3) vertexColor: vec4f
) -> @location(0) vec4f {
    let viewSize = max(material.u_Geometry.xy, vec2f(1.0));
    let inset = material.u_Geometry.z;
    let cornerRadius = clamp(material.u_Geometry.w, 0.0, min(viewSize.x, viewSize.y) * 0.5);
    let effectSize = viewSize + vec2f(inset * 2.0);
    let point = vec2f(uv.x, 1.0 - uv.y) * effectSize - vec2f(inset) - viewSize * 0.5;
    let sourceDistance = roundedBoxDistance(point, viewSize * 0.5, cornerRadius);
    let shadowDistance = roundedBoxDistance(point - material.u_Style.xy, viewSize * 0.5, cornerRadius);
    let softness = max(material.u_Style.z * 0.45, 0.5);
    let halo = 1.0 / (1.0 + exp(shadowDistance / softness));
    let outsideSource = smoothstep(-0.5, 0.75, sourceDistance);
    let alpha = clamp(material.u_Color.a * material.u_Style.w * halo * outsideSource, 0.0, 1.0);
    return vec4f(material.u_Color.rgb * alpha, alpha);
}
