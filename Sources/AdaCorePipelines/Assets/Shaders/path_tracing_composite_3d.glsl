#version 450 core
#pragma stage : vert

layout (location = 0) out vec2 v_UV;

[[main]]
void ssr_vertex() {
    uint vertexIndex = gl_VertexIndex;
    vec2 uv = vec2(float(vertexIndex >> 1u), float(vertexIndex & 1u)) * 2.0;
    gl_Position = vec4(uv * vec2(2.0, -2.0) + vec2(-1.0, 1.0), 0.0, 1.0);
    v_UV = uv;
}

#version 450 core
#pragma stage : frag
layout(location=0) in vec2 v_UV;
layout(location=0) out vec4 o_Color;
layout(binding=0) uniform texture2D u_SceneColor;
layout(binding=1) uniform texture2D u_NormalRoughness;
layout(binding=2) uniform texture2D u_ViewPositionMetallic;
layout(binding=3) uniform sampler u_LinearSampler;
layout(binding=11) uniform sampler u_GBufferSampler;
layout(binding=12) uniform texture2D u_Bloom;
layout(binding=13) uniform texture2D u_GradingLUT;
layout(binding=14) uniform sampler u_GradingSampler;
layout(binding=15) uniform texture2D u_ExposureState;
layout(binding=16) uniform texture2D u_Volumetric;
layout (binding = 4) uniform Environment3DUniform {
    mat4 u_Projection;
    mat4 u_InverseProjection;
    mat4 u_InverseView;
    vec4 u_ZenithColor;
    vec4 u_HorizonColor;
    vec4 u_GroundColor;
    vec4 u_ClearColor;
    vec4 u_Reflection;
    vec4 u_ReflectionQuality;
    vec4 u_EnvironmentFlags;
    vec4 u_Starfield;
    vec4 u_IBL;
    vec4 u_Quality;
    vec4 u_PostProcess; // x exposure scale, y bloom intensity, z tone mapper (see Tonemapping.glsl), w LUT intensity
    vec4 u_Grading;     // x saturation, y contrast, z vignette intensity, w vignette radius
    vec4 u_Vignette;    // x vignette smoothness, y 1 when automatic exposure is bound
    vec4 u_FogColor;    // rgb sRGB fog color, w density (0 = fog off)
    vec4 u_FogShape;    // x height falloff, y base height, z start distance, w maximum opacity
    vec4 u_FogRange;    // x sky influence, y sun exponent, z 1 when volumetric light shafts are bound
    vec4 u_FogSun;      // xyz world direction to the sun, w sun in-scattering strength
    vec4 u_FogSunColor; // rgb sun radiance times intensity
    vec4 u_ProbePosition;
    vec4 u_ProbeMinimum;
    vec4 u_ProbeMaximum;
    vec4 u_DiffuseGI;
};

vec3 srgbToLinear(vec3 value) {
    return mix(value / 12.92, pow((value + 0.055) / 1.055, vec3(2.4)), step(vec3(0.04045), value));
}

#include <AdaEngine/Tonemapping.glsl>
#include <AdaEngine/ColorGrading.glsl>

// Exposure and bloom act on linear HDR before tone mapping. The bloom texture is already exposed; with bloom
// off it is a white placeholder scaled by zero, so default settings leave the color unchanged.
vec3 presentColor(vec3 linearColor) {
    vec2 exposureState = u_Vignette.y > 0.5 ? textureLod(sampler2D(u_ExposureState, u_GradingSampler), vec2(0.5), 0.0).rg : vec2(0.0);
    float automatic = exp2(exposureState.x + exposureState.y);
    vec3 exposed = linearColor * (u_PostProcess.x * automatic)
        + texture(sampler2D(u_Bloom, u_LinearSampler), v_UV).rgb * u_PostProcess.y;
    exposed = adaGradeLinear(exposed, u_Grading, u_Vignette, v_UV);
    if (u_Quality.z > 0.5) {
        return exposed;
    }
    vec3 display = adaApplyLut(adaOutputTransform(exposed, u_PostProcess.z), u_PostProcess.w);
    return adaDitherDisplay(display, gl_FragCoord.xy);
}

// View-space depth the half-resolution volumetric pass saw at `uv`; sky counts as very far.
float volumetricDepthAt(vec2 uv) {
    vec3 position = texture(sampler2D(u_ViewPositionMetallic, u_GBufferSampler), uv).xyz;
    return length(position) > 0.0001 ? position.z : 10000.0;
}

// Shadowed light marched through the fog by the half-resolution pass. Weight
// the four surrounding texels by their depth agreement with this pixel, so
// scattering does not cross foreground silhouettes.
vec4 volumetricScatter(float depth) {
    if (u_FogRange.z < 0.5) {
        return vec4(0.0);
    }
    vec2 size = vec2(textureSize(sampler2D(u_Volumetric, u_LinearSampler), 0));
    vec2 base = floor(v_UV * size - 0.5);
    vec2 fraction = fract(v_UV * size - 0.5);
    vec4 sum = vec4(0.0);
    vec4 plain = vec4(0.0);
    float weights = 0.0;
    for (int y = 0; y < 2; ++y) {
        for (int x = 0; x < 2; ++x) {
            vec2 uv = clamp((base + vec2(float(x), float(y)) + 0.5) / size, 0.5 / size, vec2(1.0) - 0.5 / size);
            float bilinear = (x == 0 ? 1.0 - fraction.x : fraction.x) * (y == 0 ? 1.0 - fraction.y : fraction.y);
            vec4 value = texture(sampler2D(u_Volumetric, u_GBufferSampler), uv);
            float weight = bilinear * exp(-abs(volumetricDepthAt(uv) - depth) / max(0.1 * depth, 0.05));
            sum += value * weight;
            plain += value * bilinear;
            weights += weight;
        }
    }
    return weights > 0.001 ? sum / weights : plain;
}

// Blends exponential height fog into linear HDR color. `viewPosition` is the view-space position of the surface
// (or a far point along the ray for the sky, flagged by `isSky`) and `skyAmount` scales fog for sky pixels.
vec3 applyFog(vec3 linearColor, vec3 viewPosition, float skyAmount, bool isSky) {
    if (u_FogColor.w <= 0.0 && u_FogRange.z < 0.5) {
        return linearColor;
    }
    float travel = max(length(viewPosition) - u_FogShape.z, 0.0);
    vec3 worldDirection = normalize((u_InverseView * vec4(viewPosition, 0.0)).xyz);
    float falloff = u_FogShape.x;
    float cameraHeight = u_InverseView[3].y;
    float rise = falloff * worldDirection.y;
    // Integral of exp(-falloff * (height - base)) along the ray, with the series limit for a flat ray.
    float exponent = clamp(rise * travel, -60.0, 60.0);
    float pathFactor = abs(rise * travel) > 0.0001 ? (1.0 - exp(-exponent)) / rise : travel;
    float baseDensity = u_FogColor.w * exp(clamp(-falloff * (cameraHeight - u_FogShape.y), -60.0, 60.0));
    float opacity = min(1.0 - exp(-baseDensity * pathFactor), u_FogShape.w) * skyAmount;
    float sunAlignment = pow(max(dot(worldDirection, u_FogSun.xyz), 0.0), u_FogRange.y);
    vec3 scattered = srgbToLinear(u_FogColor.rgb) + u_FogSunColor.rgb * (u_FogSun.w * sunAlignment);
    vec4 volume = volumetricScatter(isSky ? 10000.0 : viewPosition.z);
    if (u_FogRange.w < 0.5) { return mix(linearColor, scattered, opacity) + volume.rgb; }
    return mix(linearColor, scattered, opacity) * (1.0-volume.a*skyAmount) + volume.rgb*skyAmount;
}


[[main]]
void path_composite_fragment() {
    vec3 color=texture(sampler2D(u_SceneColor,u_LinearSampler),v_UV).rgb;
    vec3 position=texture(sampler2D(u_ViewPositionMetallic,u_GBufferSampler),v_UV).xyz;
    vec3 normal=texture(sampler2D(u_NormalRoughness,u_GBufferSampler),v_UV).xyz;
    bool isSky=dot(normal,normal)<0.01 || dot(position,position)<0.000001;
    if(isSky) {
        vec4 farPoint=u_InverseProjection*vec4(v_UV*vec2(2,-2)+vec2(-1,1),1,1);
        position=normalize(farPoint.xyz/farPoint.w)*1000.0;
    }
    o_Color=vec4(presentColor(applyFog(color,position,isSky?u_FogRange.x:1.0,isSky)),1);
}
