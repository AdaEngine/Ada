import ada_engine::view::projectPosition;

struct UIShadowMaterial {
    u_Color: vec4f,
    u_Geometry: vec4f,
    u_Style: vec4f,
}

struct UIShadowVertex {
    @builtin(position) position: vec4f,
    @location(0) color: vec4f,
    @location(1) uv: vec2f,
}

@group(0) @binding(0) var<uniform> material: UIShadowMaterial;

@vertex
fn ui_shadow_vertex(@location(0) position: vec4f, @location(1) color: vec4f, @location(2) uv: vec2f) -> UIShadowVertex {
    return UIShadowVertex(projectPosition(position), color, uv);
}

fn roundedBoxDistance(point: vec2f, halfSize: vec2f, radius: f32) -> f32 {
    let offset = abs(point) - halfSize + vec2f(radius);
    return length(max(offset, vec2f(0.0))) + min(max(offset.x, offset.y), 0.0) - radius;
}

@fragment
fn ui_shadow_fragment(input: UIShadowVertex) -> @location(0) vec4f {
    let viewSize = max(material.u_Geometry.xy, vec2f(1.0));
    let inset = material.u_Geometry.z;
    let cornerRadius = clamp(material.u_Geometry.w, 0.0, min(viewSize.x, viewSize.y) * 0.5);
    let effectSize = viewSize + vec2f(inset * 2.0);
    // Quad UV Y increases upward; modifier offsets use screen Y downward.
    let point = vec2f(input.uv.x, 1.0 - input.uv.y) * effectSize - vec2f(inset) - viewSize * 0.5;
    let sourceDistance = roundedBoxDistance(point, viewSize * 0.5, cornerRadius);
    let shadowDistance = roundedBoxDistance(point - material.u_Style.xy, viewSize * 0.5, cornerRadius);
    let softness = max(material.u_Style.z * 0.45, 0.5);
    let halo = 1.0 / (1.0 + exp(shadowDistance / softness));
    let outsideSource = smoothstep(-0.5, 0.75, sourceDistance);
    let alpha = clamp(material.u_Color.a * material.u_Style.w * halo * outsideSource, 0.0, 1.0);
    return vec4f(material.u_Color.rgb * alpha, alpha);
}
