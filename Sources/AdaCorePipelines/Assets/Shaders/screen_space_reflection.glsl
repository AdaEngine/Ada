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

layout (location = 0) in vec2 v_UV;
layout (location = 0) out vec4 o_Color;

layout (binding = 0) uniform texture2D u_SceneColor;
layout (binding = 1) uniform texture2D u_NormalRoughness;
layout (binding = 2) uniform texture2D u_ViewPositionMetallic;
layout (binding = 3) uniform sampler u_LinearSampler;
layout (binding = 5) uniform texture2D u_EnvironmentTexture;
layout (binding = 6) uniform texture2D u_Radiance;
layout (binding = 7) uniform sampler u_RadianceSampler;
layout (binding = 8) uniform texture2D u_Indirect;
layout (binding = 9) uniform texture2D u_AO;
layout (binding = 11) uniform sampler u_GBufferSampler;
layout (binding = 12) uniform texture2D u_Bloom;
layout (binding = 13) uniform texture2D u_GradingLUT;
layout (binding = 14) uniform sampler u_GradingSampler;
layout (binding = 15) uniform texture2D u_ExposureState;
layout (binding = 16) uniform texture2D u_Volumetric;
layout (binding = 17) uniform texture2D u_ReflectionResponse;
layout (binding = 18) uniform texture2D u_PrefilteredEnvironment;
layout (binding = 19) uniform sampler u_IBLSampler;

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

const float PI = 3.14159265359;
layout (binding = 20) uniform texture2D u_DiffuseGITexture;

vec3 diffuseGI(vec3 position, vec3 normal) {
    if (u_DiffuseGI.x < 0.5) { return vec3(0.0); }
    vec2 size = vec2(textureSize(sampler2D(u_DiffuseGITexture, u_GBufferSampler), 0));
    vec2 pixel = v_UV * size - 0.5;
    vec2 base = floor(pixel), fraction = fract(pixel);
    vec3 sum = vec3(0.0); float weights = 0.0;
    for (int y = 0; y <= 1; ++y) for (int x = 0; x <= 1; ++x) {
        vec2 uv = clamp((base + vec2(x,y) + 0.5) / size, vec2(0.0), vec2(1.0));
        vec3 otherPosition = textureLod(sampler2D(u_ViewPositionMetallic,u_GBufferSampler), uv, 0.0).xyz;
        vec3 otherNormal = textureLod(sampler2D(u_NormalRoughness,u_GBufferSampler), uv, 0.0).xyz;
        if (length(otherNormal) < 0.1) { continue; }
        float bilinear = (x == 0 ? 1.0-fraction.x : fraction.x) * (y == 0 ? 1.0-fraction.y : fraction.y);
        float weight = bilinear * pow(max(dot(normal,normalize(otherNormal)),0.0),16.0)
            * exp(-abs(position.z-otherPosition.z) / max(0.04,u_DiffuseGI.y*4.0));
        sum += textureLod(sampler2D(u_DiffuseGITexture,u_GBufferSampler),uv,0.0).rgb * weight;
        weights += weight;
    }
    return sum / max(weights,0.00001);
}
// Weight below which a screen-space reflection ray is not traced (reflectivity times ambient occlusion).
const float MINIMUM_TRACED_REFLECTIVITY = 0.004;

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
    return adaApplyLut(adaOutputTransform(exposed, u_PostProcess.z), u_PostProcess.w);
}

// View-space depth the half-resolution volumetric pass saw at `uv`; sky counts as very far.
float volumetricDepthAt(vec2 uv) {
    vec3 position = texture(sampler2D(u_ViewPositionMetallic, u_GBufferSampler), uv).xyz;
    return length(position) > 0.0001 ? position.z : 10000.0;
}

// Shadowed sun light marched through the fog by the half-resolution volumetric pass. The four surrounding
// half-resolution texels are weighted by how close their depth is to this pixel's, so shafts do not bleed
// across silhouettes.
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

vec3 proceduralSky(vec3 direction) {
    float height = clamp(direction.y, -1.0, 1.0);
    float horizonBlend = pow(abs(height), 0.55);
    vec3 hemisphere = height >= 0.0 ? u_ZenithColor.rgb : u_GroundColor.rgb;
    vec3 sky = mix(u_HorizonColor.rgb, hemisphere, horizonBlend);
    if (u_EnvironmentFlags.w < 0.5) {
        return sky;
    }

    float longitude = atan(direction.z, direction.x) / (2.0 * PI) + 0.5;
    float latitude = asin(clamp(direction.y, -1.0, 1.0)) / PI + 0.5;
    vec2 gridSize = vec2(220.0, 110.0);
    vec2 gridPosition = vec2(longitude, latitude) * gridSize;
    vec2 cell = floor(gridPosition);
    vec2 local = fract(gridPosition);
    vec3 hashInput = vec3(cell, u_Starfield.w);
    hashInput = fract(hashInput * vec3(0.1031, 0.1030, 0.0973));
    hashInput += dot(hashInput, hashInput.yzx + 33.33);
    float existence = fract((hashInput.x + hashInput.y) * hashInput.z);
    vec2 offset = vec2(
        fract(existence * 17.17 + hashInput.x),
        fract(existence * 31.73 + hashInput.y)
    );
    float distanceToStar = length((local - offset) / max(u_Starfield.z, 0.1));
    float threshold = mix(0.998, 0.72, u_Starfield.x);
    float starExists = step(threshold, existence);
    float star = smoothstep(0.11, 0.0, distanceToStar) * starExists;
    float glow = smoothstep(0.42, 0.0, distanceToStar) * starExists * 0.22;
    vec3 warm = vec3(1.0, 0.72, 0.46);
    vec3 cool = vec3(0.58, 0.76, 1.0);
    vec3 starColor = mix(warm, cool, fract(existence * 47.0));
    return sky + starColor * (star + glow) * u_Starfield.y;
}

vec3 sampleSky(vec3 viewDirection) {
    if (u_EnvironmentFlags.x < 0.5) {
        return srgbToLinear(u_ClearColor.rgb);
    }
    vec3 worldDirection = normalize((u_InverseView * vec4(viewDirection, 0.0)).xyz);
    if (u_IBL.x > 0.5 && u_IBL.w > 0.5) {
        float angle = u_IBL.z;
        worldDirection.xz = mat2(cos(angle), -sin(angle), sin(angle), cos(angle)) * worldDirection.xz;
        vec2 uv = vec2(atan(worldDirection.z, worldDirection.x) / (2.0 * PI) + 0.5, asin(clamp(worldDirection.y, -1.0, 1.0)) / PI + 0.5);
        return texture(sampler2D(u_Radiance, u_RadianceSampler), uv).rgb * u_IBL.y;
    }
    if (u_EnvironmentFlags.y > 0.5) {
        vec2 uv = vec2(
            atan(worldDirection.z, worldDirection.x) / (2.0 * PI) + 0.5,
            asin(clamp(worldDirection.y, -1.0, 1.0)) / PI + 0.5
        );
        vec3 textureColor = texture(sampler2D(u_EnvironmentTexture, u_LinearSampler), uv).rgb;
        return srgbToLinear(textureColor) * u_EnvironmentFlags.z;
    }
    return srgbToLinear(proceduralSky(worldDirection)) * u_EnvironmentFlags.z;
}

float edgeVisibility(vec2 uv) {
    vec2 edge = min(uv, vec2(1.0) - uv);
    return smoothstep(0.0, u_ReflectionQuality.z, min(edge.x, edge.y));
}

vec3 blurredScene(vec2 uv, float roughness) {
    vec2 radius = vec2(0.012 * roughness * roughness);
    vec3 center = texture(sampler2D(u_SceneColor, u_LinearSampler), uv).rgb * 0.4;
    center += texture(sampler2D(u_SceneColor, u_LinearSampler), uv + vec2(radius.x, 0.0)).rgb * 0.15;
    center += texture(sampler2D(u_SceneColor, u_LinearSampler), uv - vec2(radius.x, 0.0)).rgb * 0.15;
    center += texture(sampler2D(u_SceneColor, u_LinearSampler), uv + vec2(0.0, radius.y)).rgb * 0.15;
    center += texture(sampler2D(u_SceneColor, u_LinearSampler), uv - vec2(0.0, radius.y)).rgb * 0.15;
    return center;
}

// Projects a view-space point to screen UV, or reports that it falls outside the view.
bool projectToScreen(vec3 point, out vec2 uv) {
    vec4 clip = u_Projection * vec4(point, 1.0);
    if (clip.w <= 0.0) {
        return false;
    }
    uv = (clip.xy / clip.w) * vec2(0.5, -0.5) + 0.5;
    return !(any(lessThanEqual(uv, vec2(0.0))) || any(greaterThanEqual(uv, vec2(1.0))));
}

// How far behind the visible surface the point lies (negative in front of it), or a large negative number when
// nothing is rendered there.
float depthBehindSurface(vec3 point, vec2 uv) {
    vec3 scenePosition = texture(sampler2D(u_ViewPositionMetallic, u_GBufferSampler), uv).xyz;
    // View-space z grows away from the camera, so a point farther than the surface has the larger z.
    return length(scenePosition) > 0.0001 ? point.z - scenePosition.z : -1000000.0;
}

// Marches in steps of twice the configured stride and, once a step crosses a surface, narrows the crossing with a
// short binary search. Half the steps of a fixed-stride march find the same hits.
bool traceReflection(vec3 origin, vec3 direction, out vec2 hitUV) {
    float stride = u_Reflection.z * 2.0;
    float thickness = u_Reflection.w;
    vec3 previous = origin + direction * thickness;
    vec3 ray = previous;
    int steps = (min(int(u_ReflectionQuality.x), 64) + 1) / 2;
    for (int step = 0; step < 32; ++step) {
        if (step >= steps) {
            break;
        }
        ray += direction * stride;
        if (distance(ray, origin) > u_Reflection.y) {
            break;
        }
        vec2 uv;
        if (!projectToScreen(ray, uv)) {
            break;
        }
        float behind = depthBehindSurface(ray, uv);
        if (behind > 0.0 && behind < stride + thickness) {
            vec3 near = previous;
            vec3 far = ray;
            for (int refinement = 0; refinement < 4; ++refinement) {
                vec3 middle = (near + far) * 0.5;
                vec2 middleUV;
                if (!projectToScreen(middle, middleUV)) {
                    break;
                }
                if (depthBehindSurface(middle, middleUV) > 0.0) {
                    far = middle;
                } else {
                    near = middle;
                }
            }
            vec2 hitCandidate;
            if (projectToScreen(far, hitCandidate) && abs(depthBehindSurface(far, hitCandidate)) <= thickness) {
                hitUV = hitCandidate;
                return true;
            }
        }
        previous = ray;
    }
    return false;
}

float ambientOcclusion(vec3 position, vec3 normal) {
    if (u_Quality.x < 0.5) { return 1.0; }
    vec2 size = vec2(textureSize(sampler2D(u_AO, u_LinearSampler), 0));
    vec2 base = floor(v_UV * size - 0.5);
    vec2 fraction = fract(v_UV * size - 0.5);
    float sum = 0.0, weights = 0.0;
    for (int y = 0; y < 2; ++y) {
        for (int x = 0; x < 2; ++x) {
            vec2 uv = clamp((base + vec2(float(x), float(y)) + 0.5) / size, 0.5 / size, vec2(1.0) - 0.5 / size);
            vec3 other = texture(sampler2D(u_ViewPositionMetallic, u_GBufferSampler), uv).xyz;
            vec3 otherNormal = texture(sampler2D(u_NormalRoughness, u_GBufferSampler), uv).xyz;
            if (other.z <= 0.0 || length(otherNormal) < 0.1) { continue; }
            float bilinear = (x == 0 ? 1.0 - fraction.x : fraction.x) * (y == 0 ? 1.0 - fraction.y : fraction.y);
            float weight = bilinear * exp(-abs(position.z - other.z) / max(0.02, u_Quality.y * 0.1));
            weight *= pow(max(dot(normal, normalize(otherNormal)), 0.0), 8.0);
            sum += texture(sampler2D(u_AO, u_GBufferSampler), uv).r * weight;
            weights += weight;
        }
    }
    return weights > 0.0001 ? sum / weights : 1.0;
}

vec3 probeReflection(vec3 viewPosition, vec3 viewDirection, float roughness) {
    vec3 direction = normalize(mat3(u_InverseView) * viewDirection);
    vec3 position = (u_InverseView * vec4(viewPosition, 1.0)).xyz;
    if (u_ProbePosition.w > 0.5 && all(greaterThanEqual(position, u_ProbeMinimum.xyz)) && all(lessThanEqual(position, u_ProbeMaximum.xyz))) {
        vec3 safeDirection = mix(direction, vec3(0.000001), lessThan(abs(direction), vec3(0.000001)));
        vec3 boundary = mix(u_ProbeMinimum.xyz, u_ProbeMaximum.xyz, greaterThanEqual(direction, vec3(0.0)));
        vec3 travel = (boundary - position) / safeDirection;
        travel = mix(travel, vec3(1e20), lessThan(abs(direction), vec3(0.000001)));
        vec3 projected = position + direction * min(travel.x, min(travel.y, travel.z)) - u_ProbePosition.xyz;
        if (dot(projected, projected) > 0.000001) { direction = normalize(projected); }
    }
    float angle = u_IBL.z;
    direction.xz = mat2(cos(angle), -sin(angle), sin(angle), cos(angle)) * direction.xz;
    vec2 uv = vec2(atan(direction.z, direction.x) / (2.0 * PI) + 0.5, asin(clamp(direction.y, -1.0, 1.0)) / PI + 0.5);
    float levels = max(u_ReflectionQuality.w, 2.0);
    float layer = roughness * (levels - 1.0), lower = floor(layer), upper = min(lower + 1.0, levels - 1.0);
    float texels = float(textureSize(sampler2D(u_PrefilteredEnvironment, u_IBLSampler), 0).y) / levels;
    uv.y = clamp(uv.y, 0.5 / texels, 1.0 - 0.5 / texels);
    vec3 a = texture(sampler2D(u_PrefilteredEnvironment, u_IBLSampler), vec2(uv.x, (lower + uv.y) / levels)).rgb;
    vec3 b = texture(sampler2D(u_PrefilteredEnvironment, u_IBLSampler), vec2(uv.x, (upper + uv.y) / levels)).rgb;
    return mix(a, b, layer - lower) * u_IBL.y;
}

[[main]]
void ssr_fragment() {
    vec4 normalRoughness = texture(sampler2D(u_NormalRoughness, u_GBufferSampler), v_UV);
    vec4 positionMetallic = texture(sampler2D(u_ViewPositionMetallic, u_GBufferSampler), v_UV);
    if (length(normalRoughness.xyz) < 0.1 || length(positionMetallic.xyz) < 0.0001) {
        vec2 ndc = vec2(v_UV.x * 2.0 - 1.0, 1.0 - v_UV.y * 2.0);
        vec4 viewFar = u_InverseProjection * vec4(ndc, 1.0, 1.0);
        vec3 viewRay = normalize(viewFar.xyz / viewFar.w);
        // Transparent geometry and particles do not populate the opaque GBuffer. The HDR scene
        // target stores their premultiplied color/coverage over transparent black at these pixels.
        vec4 foreground = texture(sampler2D(u_SceneColor, u_LinearSampler), v_UV);
        vec3 skyWithForeground = foreground.rgb + sampleSky(viewRay) * (1.0-clamp(foreground.a,0.0,1.0));
        o_Color = vec4(presentColor(applyFog(skyWithForeground, viewRay * 1000.0, u_FogRange.x, true)), 1.0);
        return;
    }

    vec3 baseColor = texture(sampler2D(u_SceneColor, u_LinearSampler), v_UV).rgb;
    float ao = ambientOcclusion(positionMetallic.xyz, normalize(normalRoughness.xyz));
    vec3 indirect = texture(sampler2D(u_Indirect, u_LinearSampler), v_UV).rgb;
    baseColor = max(baseColor - indirect * (1.0 - ao), vec3(0.0));
    baseColor += diffuseGI(positionMetallic.xyz, normalize(normalRoughness.xyz)) * ao;
    vec3 normal = normalize(normalRoughness.xyz);
    float roughness = clamp(normalRoughness.w, 0.04, 1.0);
    float metallic = clamp(positionMetallic.w, 0.0, 1.0);
    vec3 viewDirection = normalize(positionMetallic.xyz);
    vec3 reflectionDirection = normalize(reflect(viewDirection, normal));
    // Replace the base specular lobe, using the exact material BRDF response written by PBR. A miss retains
    // the offline capture, including geometry behind the camera. Diffuse, coat and anisotropic probes survive.
    if (u_IBL.x > 0.5) {
        if (u_Quality.w > 0.5 && u_Reflection.x > 0.5 && u_ReflectionQuality.y > 0.0) {
            vec3 response = texture(sampler2D(u_ReflectionResponse, u_GBufferSampler), v_UV).rgb * ao;
            if (max(response.r, max(response.g, response.b)) > MINIMUM_TRACED_REFLECTIVITY) {
                vec2 hitUV;
                if (traceReflection(positionMetallic.xyz + normal * u_Reflection.w, reflectionDirection, hitUV)) {
                    float weight = edgeVisibility(hitUV) * clamp(u_ReflectionQuality.y, 0.0, 1.0);
                    vec3 previous = probeReflection(positionMetallic.xyz, reflectionDirection, roughness);
                    baseColor = max(baseColor + (blurredScene(hitUV, roughness) - previous) * response * weight, vec3(0.0));
                }
            }
        }
        o_Color = vec4(presentColor(applyFog(baseColor, positionMetallic.xyz, 1.0, false)), 1.0);
        return;
    }
    // A baked view without a specular IBL asset already owns its diffuse illumination.
    // The legacy procedural fill would add a second, unoccluded ambient term.
    if (u_DiffuseGI.z > 0.5) {
        o_Color = vec4(presentColor(applyFog(baseColor, positionMetallic.xyz, 1.0, false)), 1.0);
        return;
    }
    vec3 environment = sampleSky(reflectionDirection);

    float fresnel = pow(1.0 - clamp(dot(-viewDirection, normal), 0.0, 1.0), 5.0);
    float reflectivity = mix(0.04, 1.0, metallic) * mix(1.0, fresnel, 0.35);
    reflectivity *= (1.0 - roughness * 0.7) * u_ReflectionQuality.y;

    vec3 reflectedColor = environment;
    float visibility = 0.0;
    // Most of a typical frame is matte or head-on surfaces whose reflection weighs a percent or two of the
    // pixel. Tracing a ray for them costs the bulk of this pass and cannot change the result visibly.
    if (u_Reflection.x > 0.5 && reflectivity * ao > MINIMUM_TRACED_REFLECTIVITY) {
        vec2 hitUV;
        if (traceReflection(positionMetallic.xyz + normal * u_Reflection.w, reflectionDirection, hitUV)) {
            reflectedColor = blurredScene(hitUV, roughness);
            visibility = edgeVisibility(hitUV);
        }
    }
    vec3 ambient = sampleSky(normal) * (0.035 + 0.035 * (1.0 - roughness));
    vec3 reflectionResult = mix(environment, reflectedColor, visibility);
    o_Color = vec4(presentColor(applyFog(baseColor + (ambient + reflectionResult * reflectivity) * ao, positionMetallic.xyz, 1.0, false)), 1.0);
}
