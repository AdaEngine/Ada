#version 450 core
#pragma stage : vert

#include <AdaEngine/View.glsl>

layout (location = 0) in vec4 a_Position;
layout (location = 1) in vec4 a_Color;
layout (location = 2) in vec2 a_TexCoordinate;
layout (location = 3) in vec4 a_GlassParams0;   // x=blurRadius, y=cornerRadius, z=tintStrength, w=edgeShadow
layout (location = 4) in vec4 a_GlassParams1;   // x=cornerRoundnessExponent, y=glassThickness, z=refractiveIndex, w=dispersionStrength
layout (location = 5) in vec4 a_GlassParams2;   // x=fresnelDistanceRange, y=fresnelIntensity, z=fresnelEdgeSharpness, w=glareDistanceRange
layout (location = 6) in vec4 a_GlassParams3;   // x=glareAngleConvergence, y=glareOppositeSideBias, z=glareIntensity, w=glareEdgeSharpness
layout (location = 7) in vec4 a_GlassInfo0;     // x=halfWidth, y=halfHeight, z=scaleFactor, w=opacity
layout (location = 8) in vec4 a_GlassInfo1;     // x=glareDirectionOffset, yzw reserved

layout (location = 0) out vec4 v_Color;
layout (location = 1) out vec2 v_TexCoordinate;
layout (location = 2) out vec4 v_GlassParams0;
layout (location = 3) out vec4 v_GlassParams1;
layout (location = 4) out vec4 v_GlassParams2;
layout (location = 5) out vec4 v_GlassParams3;
layout (location = 6) out vec4 v_GlassInfo0;
layout (location = 7) out vec4 v_GlassInfo1;

[[main]]
void glass_vertex() {
    v_Color = a_Color;
    v_TexCoordinate = a_TexCoordinate;
    v_GlassParams0 = a_GlassParams0;
    v_GlassParams1 = a_GlassParams1;
    v_GlassParams2 = a_GlassParams2;
    v_GlassParams3 = a_GlassParams3;
    v_GlassInfo0 = a_GlassInfo0;
    v_GlassInfo1 = a_GlassInfo1;
    gl_Position = u_ViewProjection * a_Position;
}

#version 450 core
#pragma stage : frag

layout (location = 0) out vec4 o_Color;

layout (location = 0) in vec4 v_Color;
layout (location = 1) in vec2 v_TexCoordinate;
layout (location = 2) in vec4 v_GlassParams0;
layout (location = 3) in vec4 v_GlassParams1;
layout (location = 4) in vec4 v_GlassParams2;
layout (location = 5) in vec4 v_GlassParams3;
layout (location = 6) in vec4 v_GlassInfo0;
layout (location = 7) in vec4 v_GlassInfo1;

layout (binding = 0) uniform texture2D u_BackgroundTexture;
layout (binding = 1) uniform sampler u_BackgroundSampler;

const int kBlurGridRadius = 10;

float saturate(float v) { return clamp(v, 0.0, 1.0); }

float sdRoundedBox(vec2 p, vec2 b, float r) {
    vec2 q = abs(p) - b + r;
    return min(max(q.x, q.y), 0.0) + length(max(q, vec2(0.0))) - r;
}

vec4 sampleBg(vec2 uv) {
    return texture(sampler2D(u_BackgroundTexture, u_BackgroundSampler), uv);
}

float sampleBlurredChannel(vec2 uv, vec2 texelSize, float radius, int channel) {
    float value = 0.0;
    float totalWeight = 0.0;
    float sigma = max(radius * 0.42, 1.0);
    float stepPx = max(radius / float(kBlurGridRadius), 1.0);

    for (int y = -kBlurGridRadius; y <= kBlurGridRadius; y++) {
        for (int x = -kBlurGridRadius; x <= kBlurGridRadius; x++) {
            vec2 offsetPx = vec2(float(x), float(y)) * stepPx;
            float w = exp(-dot(offsetPx, offsetPx) / (2.0 * sigma * sigma));
            vec2 offset = offsetPx * texelSize;
            vec2 sUV = clamp(uv + offset, vec2(0.001), vec2(0.999));
            value += sampleBg(sUV)[channel] * w;
            totalWeight += w;
        }
    }
    return value / totalWeight;
}

vec3 sampleBlurredAll(vec2 uv, vec2 texelSize, float radius) {
    vec3 value = vec3(0.0);
    float totalWeight = 0.0;
    float sigma = max(radius * 0.42, 1.0);
    float stepPx = max(radius / float(kBlurGridRadius), 1.0);

    for (int y = -kBlurGridRadius; y <= kBlurGridRadius; y++) {
        for (int x = -kBlurGridRadius; x <= kBlurGridRadius; x++) {
            vec2 offsetPx = vec2(float(x), float(y)) * stepPx;
            float w = exp(-dot(offsetPx, offsetPx) / (2.0 * sigma * sigma));
            vec2 offset = offsetPx * texelSize;
            vec2 sUV = clamp(uv + offset, vec2(0.001), vec2(0.999));
            value += sampleBg(sUV).rgb * w;
            totalWeight += w;
        }
    }
    return value / totalWeight;
}

[[main]]
void glass_fragment() {
    float blurRadius     = v_GlassParams0.x;
    float cornerRadius   = v_GlassParams0.y;
    float glassTintStr   = saturate(v_GlassParams0.z);
    float edgeShadowStr  = saturate(v_GlassParams0.w);

    float glassThickness     = max(0.0, v_GlassParams1.y);
    float refractiveIndex    = max(1.0, v_GlassParams1.z);
    float dispersionStrength = saturate(v_GlassParams1.w);

    float halfW        = v_GlassInfo0.x;
    float halfH        = v_GlassInfo0.y;
    float scaleFactor  = max(v_GlassInfo0.z, 1.0);
    float glassOpacity = saturate(v_GlassInfo0.w);

    ivec2 bgTexSizeI = textureSize(sampler2D(u_BackgroundTexture, u_BackgroundSampler), 0);
    vec2 bgTexSize = vec2(bgTexSizeI);
    vec2 texelSize = 1.0 / bgTexSize;

    // Local position from center (logical pixels).
    vec2 localPos = (v_TexCoordinate - 0.5) * 2.0 * vec2(halfW, halfH);
    vec2 halfSize = vec2(halfW, halfH);

    // --- SDF (simple rounded box, like OpenGlass) ---
    float sdf = sdRoundedBox(localPos, halfSize, cornerRadius);
    float edgeAA = max(length(vec2(dFdx(sdf), dFdy(sdf))), 0.5);

    float distFromEdge = -sdf;
    float effectiveSize = min(halfW * 2.0, halfH * 2.0);

    // --- Edge-band refraction (OpenGlass approach) ---
    float edgeBandMul = 0.1;
    float edgeBand = effectiveSize * edgeBandMul;
    float edgeFactor = 1.0 - smoothstep(0.0, edgeBand, distFromEdge);
    edgeFactor = edgeFactor * edgeFactor * edgeFactor * 2.0;

    // Refraction direction from SDF gradient (smooth, no cross-hair artifact).
    const float kGradEps = 1.0;
    float sdfXp = sdRoundedBox(localPos + vec2(kGradEps, 0.0), halfSize, cornerRadius);
    float sdfXm = sdRoundedBox(localPos - vec2(kGradEps, 0.0), halfSize, cornerRadius);
    float sdfYp = sdRoundedBox(localPos + vec2(0.0, kGradEps), halfSize, cornerRadius);
    float sdfYm = sdRoundedBox(localPos - vec2(0.0, kGradEps), halfSize, cornerRadius);
    vec2 sdfGrad = vec2(sdfXp - sdfXm, sdfYp - sdfYm);
    float gradLen = length(sdfGrad);
    vec2 toCenter = gradLen > 1e-4 ? -sdfGrad / gradLen : vec2(0.0);

    // Zoom / magnification from glass thickness.
    float zoom = 1.0 + glassThickness * 0.0015;
    vec2 normFromCenter = localPos / max(halfSize, vec2(1e-4));
    float distNorm = length(normFromCenter);
    float zoomFactor = max(0.0, 1.0 - distNorm * distNorm);
    float zoomStrength = zoom - 1.0;
    float minSide = min(halfW, halfH);
    vec2 magOffset = -normFromCenter * zoomFactor * zoomStrength * minSide;

    // Refraction and chromatic aberration strengths.
    float refrStr = (refractiveIndex - 1.0) * 5.0;
    float disp = edgeFactor * refrStr * edgeBand;
    float chrome = edgeFactor * dispersionStrength * 4.0;

    vec2 greenOff = toCenter * disp + magOffset;

    // --- Sample background ---
    float blurPhysical = max(blurRadius * scaleFactor, 0.0);
    vec2 fragPx = gl_FragCoord.xy;

    vec2 redOff  = toCenter * (disp + chrome) + magOffset;
    vec2 blueOff = toCenter * (disp - chrome) + magOffset;

    vec2 redUV   = clamp((fragPx + redOff   * scaleFactor) / bgTexSize, vec2(0.001), vec2(0.999));
    vec2 greenUV = clamp((fragPx + greenOff  * scaleFactor) / bgTexSize, vec2(0.001), vec2(0.999));
    vec2 blueUV  = clamp((fragPx + blueOff  * scaleFactor) / bgTexSize, vec2(0.001), vec2(0.999));

    float r = sampleBlurredChannel(redUV,   texelSize, blurPhysical, 0);
    float g = sampleBlurredChannel(greenUV, texelSize, blurPhysical, 1);
    float b = sampleBlurredChannel(blueUV,  texelSize, blurPhysical, 2);
    vec3 color = vec3(r, g, b);

    // --- Luminance-adaptive tinting (OpenGlass light-mode path) ---
    float lum = dot(color, vec3(0.299, 0.587, 0.114));
    float tintAmount = max(lum, 0.08) * glassTintStr * mix(1.0, 0.35, lum);
    color = 1.0 - (1.0 - color) * (1.0 - tintAmount);

    // --- Shadow ---
    float shadowScale = saturate(1.0 - lum * 0.8);
    float overallShadow = 0.02 * shadowScale;
    float edgeShadow = (1.0 - smoothstep(0.0, 20.0, distFromEdge)) * edgeShadowStr * shadowScale;
    color *= (1.0 - overallShadow - edgeShadow);

    // --- Anti-aliased alpha ---
    float aa = saturate(0.5 - sdf / (edgeAA * 2.0));

    // --- Thin directional border (OpenGlass style, softened) ---
    float borderWidth = 1.5;
    float borderInner = smoothstep(borderWidth, 0.2, distFromEdge);
    float borderOuter = saturate(distFromEdge / (edgeAA * 0.8));
    float borderMask = borderInner * borderOuter * aa;

    vec2 borderNorm = gradLen > 1e-4 ? sdfGrad / gradLen : vec2(0.0);
    vec2 lightDir = normalize(vec2(1.0, 1.0));
    float dirFactor = abs(dot(borderNorm, lightDir));
    dirFactor = dirFactor * dirFactor;
    float borderLight = mix(0.35, 0.70, dirFactor) * mix(0.5, 1.0, lum);
    color = mix(color, vec3(1.0), borderMask * borderLight * 0.6);

    // Optional tint color overlay from vertex data.
    color = mix(color, v_Color.rgb, v_Color.a * 0.3);

    o_Color = vec4(clamp(color, vec3(0.0), vec3(1.0)), aa * glassOpacity);
}
