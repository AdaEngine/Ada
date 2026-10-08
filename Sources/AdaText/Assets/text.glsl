#version 450 core
#pragma stage : vert

#include <AdaEngine/View.glsl>

layout (location = 0) in vec4 a_Position;
layout (location = 1) in vec4 a_ForegroundColor;
layout (location = 2) in vec4 a_OutlineColor;
layout (location = 3) in float a_OutlineWidth;
layout (location = 4) in vec2 a_TexCoordinate;

layout (location = 0) out vec4 v_ForegroundColor;
layout (location = 1) out vec4 v_OutlineColor;
layout (location = 2) out float v_OutlineWidth;
layout (location = 3) out vec2 v_TexCoordinate;

[[main]]
void text_vertex() {
    v_ForegroundColor = a_ForegroundColor;
    v_OutlineColor = a_OutlineColor;
    v_OutlineWidth = a_OutlineWidth;
    v_TexCoordinate = a_TexCoordinate;

    gl_Position = u_ViewProjection * a_Position;
}

#version 450 core
#pragma stage : frag

layout (location = 0) out vec4 color;

layout (location = 0) in vec4 v_ForegroundColor;
layout (location = 1) in vec4 v_OutlineColor;
layout (location = 2) in float v_OutlineWidth;
layout (location = 3) in vec2 v_TexCoordinate;
layout (binding = 0) uniform texture2D u_FontAtlas;
layout (binding = 1) uniform sampler   u_FontSampler;

float ScreenPxRange() {
    // Must match FontAtlasGenerator.atlasPixelRange, including cached atlases.
    float pxRange = 4.0f;
    ivec2 textureSize = textureSize(sampler2D(u_FontAtlas, u_FontSampler), 0);
    vec2 unitRange = vec2(pxRange) / vec2(textureSize);
    vec2 screenTexSize = vec2(1.0) / fwidth(v_TexCoordinate);
    return max(0.5 * dot(unitRange, screenTexSize), 1.0);
}

float Median(vec3 msd) {
    return max(min(msd.r, msd.g), min(max(msd.r, msd.g), msd.b));
}

[[main]]
void text_fragment() {
    vec4 fgColor = v_ForegroundColor;
    vec4 outlineColor = v_OutlineColor;

    vec3 msd = texture(sampler2D(u_FontAtlas, u_FontSampler), v_TexCoordinate).rgb;
    float sd = Median(msd);
    float pxDistance = ScreenPxRange() * (sd - 0.5f);
    float fillAlpha = clamp(pxDistance + 0.5, 0.0, 1.0) * fgColor.a;
    float outlineAlpha = clamp(pxDistance + v_OutlineWidth + 0.5, 0.0, 1.0) * outlineColor.a;

    // Composite fill over outline, then return straight-alpha color for the
    // pipeline's sourceAlpha RGB blending. Premultiplied RGB here would apply
    // edge coverage twice and make small regular-weight text appear too thin.
    float visibleOutlineAlpha = outlineAlpha * (1.0 - fillAlpha);
    float alpha = fillAlpha + visibleOutlineAlpha;
    vec3 premultipliedColor = fgColor.rgb * fillAlpha + outlineColor.rgb * visibleOutlineAlpha;
    color = vec4(alpha > 0.0 ? premultipliedColor / alpha : vec3(0.0), alpha);
}
