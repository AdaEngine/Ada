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
};

const float PI = 3.14159265359;

vec3 srgbToLinear(vec3 value) {
    return mix(value / 12.92, pow((value + 0.055) / 1.055, vec3(2.4)), step(vec3(0.04045), value));
}

vec3 linearToSrgb(vec3 value) {
    value = max(value, vec3(0.0));
    return mix(value * 12.92, 1.055 * pow(value, vec3(1.0 / 2.4)) - 0.055, step(vec3(0.0031308), value));
}

vec3 acesToneMap(vec3 value) {
    const float a = 2.51;
    const float b = 0.03;
    const float c = 2.43;
    const float d = 0.59;
    const float e = 0.14;
    return clamp((value * (a * value + b)) / (value * (c * value + d) + e), 0.0, 1.0);
}

vec3 presentColor(vec3 linearColor) {
    return linearToSrgb(acesToneMap(linearColor));
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

bool traceReflection(vec3 origin, vec3 direction, out vec2 hitUV) {
    vec3 ray = origin + direction * u_Reflection.w;
    for (int step = 0; step < 64; ++step) {
        if (step >= int(u_ReflectionQuality.x)) {
            break;
        }
        ray += direction * u_Reflection.z;
        if (distance(ray, origin) > u_Reflection.y) {
            break;
        }

        vec4 clip = u_Projection * vec4(ray, 1.0);
        if (clip.w <= 0.0) {
            break;
        }
        vec2 uv = clip.xy / clip.w;
        uv = uv * vec2(0.5, -0.5) + 0.5;
        if (any(lessThanEqual(uv, vec2(0.0))) || any(greaterThanEqual(uv, vec2(1.0)))) {
            break;
        }

        vec3 scenePosition = texture(sampler2D(u_ViewPositionMetallic, u_LinearSampler), uv).xyz;
        if (length(scenePosition) > 0.0001) {
            float rayDepth = -ray.z;
            float sceneDepth = -scenePosition.z;
            if (rayDepth >= sceneDepth - u_Reflection.w && rayDepth <= sceneDepth + u_Reflection.w) {
                hitUV = uv;
                return true;
            }
        }
    }
    return false;
}

[[main]]
void ssr_fragment() {
    vec4 normalRoughness = texture(sampler2D(u_NormalRoughness, u_LinearSampler), v_UV);
    vec4 positionMetallic = texture(sampler2D(u_ViewPositionMetallic, u_LinearSampler), v_UV);
    if (length(normalRoughness.xyz) < 0.1 || length(positionMetallic.xyz) < 0.0001) {
        vec2 ndc = vec2(v_UV.x * 2.0 - 1.0, 1.0 - v_UV.y * 2.0);
        vec4 viewFar = u_InverseProjection * vec4(ndc, 1.0, 1.0);
        vec3 viewRay = normalize(viewFar.xyz / viewFar.w);
        o_Color = vec4(presentColor(sampleSky(viewRay)), 1.0);
        return;
    }

    vec3 baseColor = texture(sampler2D(u_SceneColor, u_LinearSampler), v_UV).rgb;
    // The PBR pass already integrated diffuse and specular IBL, including AO and material F0.
    if (u_IBL.x > 0.5) { o_Color = vec4(presentColor(baseColor), 1.0); return; }
    vec3 normal = normalize(normalRoughness.xyz);
    float roughness = clamp(normalRoughness.w, 0.04, 1.0);
    float metallic = clamp(positionMetallic.w, 0.0, 1.0);
    vec3 viewDirection = normalize(positionMetallic.xyz);
    vec3 reflectionDirection = normalize(reflect(viewDirection, normal));
    vec3 environment = sampleSky(reflectionDirection);

    vec3 reflectedColor = environment;
    float visibility = 0.0;
    if (u_Reflection.x > 0.5) {
        vec2 hitUV;
        if (traceReflection(positionMetallic.xyz + normal * u_Reflection.w, reflectionDirection, hitUV)) {
            reflectedColor = blurredScene(hitUV, roughness);
            visibility = edgeVisibility(hitUV);
        }
    }

    float fresnel = pow(1.0 - clamp(dot(-viewDirection, normal), 0.0, 1.0), 5.0);
    float reflectivity = mix(0.04, 1.0, metallic) * mix(1.0, fresnel, 0.35);
    reflectivity *= (1.0 - roughness * 0.7) * u_ReflectionQuality.y;
    vec3 ambient = sampleSky(normal) * (0.035 + 0.035 * (1.0 - roughness));
    vec3 reflectionResult = mix(environment, reflectedColor, visibility);
    o_Color = vec4(presentColor(baseColor + ambient + reflectionResult * reflectivity), 1.0);
}
