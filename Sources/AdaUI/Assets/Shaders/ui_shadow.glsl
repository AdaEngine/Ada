#version 450 core
#pragma stage : frag
#include <AdaEngine/UIShaderMaterial.frag>

layout (std140, binding = 0) uniform UIShadowMaterial {
    vec4 u_Color;
    vec4 u_Geometry;
    vec4 u_Style;
};

float roundedBoxDistance(vec2 point, vec2 halfSize, float radius) {
    vec2 offset = abs(point) - halfSize + radius;
    return length(max(offset, 0.0)) + min(max(offset.x, offset.y), 0.0) - radius;
}

[[main]]
void ui_shadow_fragment() {
    vec2 viewSize = max(u_Geometry.xy, vec2(1.0));
    float inset = u_Geometry.z;
    float cornerRadius = clamp(u_Geometry.w, 0.0, min(viewSize.x, viewSize.y) * 0.5);
    vec2 effectSize = viewSize + vec2(inset * 2.0);
    // UI quad UVs have Y increasing upward; modifier offsets use screen Y downward.
    vec2 point = vec2(Input.UV.x, 1.0 - Input.UV.y) * effectSize - vec2(inset) - viewSize * 0.5;
    float sourceDistance = roundedBoxDistance(point, viewSize * 0.5, cornerRadius);
    float shadowDistance = roundedBoxDistance(point - u_Style.xy, viewSize * 0.5, cornerRadius);
    float softness = max(u_Style.z * 0.45, 0.5);
    float halo = 1.0 / (1.0 + exp(shadowDistance / softness));
    float outsideSource = smoothstep(-0.5, 0.75, sourceDistance);
    float alpha = clamp(u_Color.a * u_Style.w * halo * outsideSource, 0.0, 1.0);
    COLOR = vec4(u_Color.rgb * alpha, alpha);
}
