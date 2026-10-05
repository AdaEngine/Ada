#version 450 core
#pragma stage : vert

#include <AdaEngine/View.glsl>

layout (binding = 1) uniform DirectionalLight3DUniform {
    vec4 u_LightDirectionIntensity;
    vec4 u_LightRadianceAmbient;
    mat4 u_ShadowViewProjection;
    vec4 u_ShadowParameters;
    mat4 u_ShadowViewProjection1;
    mat4 u_ShadowViewProjection2;
    vec4 u_CascadeSplits;
    vec4 u_ShadowAtlas;
};

layout (location = 13) in vec4 a_JointIndices;
layout (location = 14) in vec4 a_JointWeights;
layout (binding = 14) uniform Skinning3DUniform {
    mat4 u_JointMatrices[128];
};

mat4 skinTransform() {
    if (a_JointIndices.x < 0.0) { return mat4(1.0); }
    return u_JointMatrices[int(a_JointIndices.x)] * a_JointWeights.x
        + u_JointMatrices[int(a_JointIndices.y)] * a_JointWeights.y
        + u_JointMatrices[int(a_JointIndices.z)] * a_JointWeights.z
        + u_JointMatrices[int(a_JointIndices.w)] * a_JointWeights.w;
}

layout (location = 0) in vec3 a_Position;
layout (location = 1) in vec3 a_Normal;
layout (location = 2) in vec2 a_TextureCoordinate;
layout (location = 15) in vec2 a_TextureCoordinate1;
layout (location = 3) in vec4 a_VertexColor;
layout (location = 4) in vec4 a_Tangent;
layout (location = 5) in vec4 a_Model0;
layout (location = 6) in vec4 a_Model1;
layout (location = 7) in vec4 a_Model2;
layout (location = 8) in vec4 a_Model3;
layout (location = 9) in vec4 a_Color;
layout (location = 10) in vec4 a_Material;
layout (location = 11) in vec4 a_TextureFlags;
layout (location = 12) in vec4 a_ShadowFlags;

struct VertexOut
{
    vec4 Color;
    vec3 ViewPosition;
    vec3 WorldPosition;
    vec3 ViewNormal;
    vec4 ViewTangent;
    vec2 TextureCoordinate;
    vec2 TextureCoordinate1;
    vec4 TextureFlags;
    vec4 ShadowFlags;
    vec4 ShadowPosition;
    float Roughness;
    float Metallic;
    float EmissiveStrength;
    float EmissiveLightThreshold;
};

layout (location = 0) out VertexOut Output;

[[main]]
void flat3d_vertex()
{
    mat4 model = mat4(a_Model0, a_Model1, a_Model2, a_Model3) * skinTransform();
    mat3 basis = mat3(model);
    mat3 normalMatrix = abs(determinant(basis)) > 0.000001 ? transpose(inverse(basis)) : mat3(1.0);
    vec3 normal = normalize(normalMatrix * a_Normal);
    vec4 worldPosition = model * vec4(a_Position, 1.0);
    vec3 worldTangent = normalize(mat3(model) * a_Tangent.xyz);
    Output.Color = a_Color * a_VertexColor;
    Output.WorldPosition = worldPosition.xyz;
    Output.ViewPosition = (u_ViewMatrix * worldPosition).xyz;
    Output.ViewNormal = normalize(mat3(u_ViewMatrix) * normal);
    Output.ViewTangent = vec4(normalize(mat3(u_ViewMatrix) * worldTangent), a_Tangent.w);
    Output.TextureCoordinate = a_TextureCoordinate;
    Output.TextureCoordinate1 = a_TextureCoordinate1;
    Output.TextureFlags = a_TextureFlags;
    Output.ShadowFlags = a_ShadowFlags;
    Output.ShadowPosition = a_ShadowFlags.x > 0.5
        ? u_ShadowViewProjection * worldPosition
        : vec4(0.0);
    Output.Roughness = clamp(a_Material.x, 0.04, 1.0);
    Output.Metallic = clamp(a_Material.y, 0.0, 1.0);
    Output.EmissiveStrength = max(a_Material.z, 0.0);
    Output.EmissiveLightThreshold = a_Material.w;
    gl_Position = u_ViewProjection * worldPosition;
}

#version 450 core
#pragma stage : frag

layout (location = 0) out vec4 color;
layout (location = 1) out vec4 normalRoughness;
layout (location = 2) out vec4 viewPositionMetallic;
layout (location = 3) out vec4 indirectLighting;

layout (binding = 1) uniform DirectionalLight3DUniform {
    vec4 u_LightDirectionIntensity;
    vec4 u_LightRadianceAmbient;
    mat4 u_ShadowViewProjection;
    vec4 u_ShadowParameters;
    mat4 u_ShadowViewProjection1;
    mat4 u_ShadowViewProjection2;
    vec4 u_CascadeSplits;
    vec4 u_ShadowAtlas;
};

layout (binding = 4) uniform texture2D u_BaseColorTexture;
layout (binding = 5) uniform texture2D u_MetallicRoughnessTexture;
layout (binding = 6) uniform texture2D u_NormalTexture;
layout (binding = 7) uniform sampler u_BaseColorSampler;
layout (binding = 8) uniform sampler u_MetallicRoughnessSampler;
layout (binding = 9) uniform sampler u_NormalSampler;
layout (binding = 10) uniform texture2D u_DirectionalShadowTexture;
layout (binding = 11) uniform sampler u_DirectionalShadowSampler;
layout (binding = 12) uniform texture2D u_EmissiveTexture;
layout (binding = 13) uniform sampler u_EmissiveSampler;

layout (binding = 15) uniform PBR3DUniform {
    vec4 u_EmissiveFactor;
    vec4 u_SurfaceProperties;
    vec4 u_SurfaceFlags;
    vec4 u_UVSets;
    vec4 u_Emission;
};
layout (binding = 16) uniform texture2D u_OcclusionTexture;
layout (binding = 0) uniform sampler u_OcclusionSampler;
layout (binding = 18) uniform texture2D u_Irradiance;
layout (binding = 19) uniform texture2D u_PrefilteredEnvironment;
layout (binding = 20) uniform texture2D u_BRDF;
layout (binding = 3) uniform sampler u_IBLSampler;
layout (binding = 22) uniform IBL3DUniform {
    mat4 u_EnvironmentInverseView;
    vec4 u_IBLParameters;
};

struct VertexOut
{
    vec4 Color;
    vec3 ViewPosition;
    vec3 WorldPosition;
    vec3 ViewNormal;
    vec4 ViewTangent;
    vec2 TextureCoordinate;
    vec2 TextureCoordinate1;
    vec4 TextureFlags;
    vec4 ShadowFlags;
    vec4 ShadowPosition;
    float Roughness;
    float Metallic;
    float EmissiveStrength;
    float EmissiveLightThreshold;
};

layout (location = 0) in VertexOut Input;

const float PI = 3.14159265359;

vec3 srgbToLinear(vec3 value) {
    return mix(value / 12.92, pow((value + 0.055) / 1.055, vec3(2.4)), step(vec3(0.04045), value));
}

float distributionGGX(vec3 normal, vec3 halfway, float roughness) {
    float alpha = roughness * roughness;
    float alphaSquared = alpha * alpha;
    float normalHalfway = max(dot(normal, halfway), 0.0);
    float denominator = normalHalfway * normalHalfway * (alphaSquared - 1.0) + 1.0;
    return alphaSquared / max(PI * denominator * denominator, 0.000001);
}

float geometrySchlickGGX(float normalDirection, float roughness) {
    float radius = roughness + 1.0;
    float k = radius * radius / 8.0;
    return normalDirection / max(normalDirection * (1.0 - k) + k, 0.000001);
}

float geometrySmith(vec3 normal, vec3 viewDirection, vec3 lightDirection, float roughness) {
    return geometrySchlickGGX(max(dot(normal, viewDirection), 0.0), roughness)
        * geometrySchlickGGX(max(dot(normal, lightDirection), 0.0), roughness);
}

vec3 fresnelSchlick(float cosine, vec3 reflectanceAtNormal) {
    return reflectanceAtNormal + (vec3(1.0) - reflectanceAtNormal) * pow(clamp(1.0 - cosine, 0.0, 1.0), 5.0);
}

vec2 materialUV(float setIndex) {
    return setIndex > 0.5 ? Input.TextureCoordinate1 : Input.TextureCoordinate;
}

vec2 environmentUV(vec3 direction) {
    float angle = u_IBLParameters.w;
    direction.xz = mat2(cos(angle), -sin(angle), sin(angle), cos(angle)) * direction.xz;
    return vec2(atan(direction.z, direction.x) / (2.0 * PI) + 0.5, asin(clamp(direction.y, -1.0, 1.0)) / PI + 0.5);
}

vec3 samplePrefiltered(vec3 direction, float roughness) {
    vec2 uv = environmentUV(direction);
    float levels = max(u_IBLParameters.z, 2.0);
    float layer = roughness * (levels - 1.0);
    float lower = floor(layer);
    float upper = min(lower + 1.0, levels - 1.0);
    float texels = float(textureSize(sampler2D(u_PrefilteredEnvironment, u_IBLSampler), 0).y) / levels;
    uv.y = clamp(uv.y, 0.5 / texels, 1.0 - 0.5 / texels);
    vec3 left = texture(sampler2D(u_PrefilteredEnvironment, u_IBLSampler), vec2(uv.x, (lower + uv.y) / levels)).rgb;
    vec3 right = texture(sampler2D(u_PrefilteredEnvironment, u_IBLSampler), vec2(uv.x, (upper + uv.y) / levels)).rgb;
    return mix(left, right, layer - lower);
}

vec3 environmentLighting(vec3 normal, vec3 viewDirection, vec3 baseColor, float metallic, float roughness) {
    vec3 worldNormal = normalize(mat3(u_EnvironmentInverseView) * normal);
    vec3 worldView = normalize(mat3(u_EnvironmentInverseView) * viewDirection);
    float ndotv = max(dot(normal, viewDirection), 0.0);
    vec3 f0 = mix(vec3(0.04), baseColor, metallic);
    vec3 fresnel = f0 + (max(vec3(1.0 - roughness), f0) - f0) * pow(1.0 - ndotv, 5.0);
    vec3 diffuseWeight = (vec3(1.0) - fresnel) * (1.0 - metallic);
    vec3 irradiance = texture(sampler2D(u_Irradiance, u_IBLSampler), environmentUV(worldNormal)).rgb;
    vec3 reflected = samplePrefiltered(reflect(-worldView, worldNormal), roughness);
    vec2 lutSize = vec2(textureSize(sampler2D(u_BRDF, u_IBLSampler), 0));
    vec2 lutUV = clamp(vec2(ndotv, roughness), 0.5 / lutSize, vec2(1.0) - 0.5 / lutSize);
    vec2 lut = texture(sampler2D(u_BRDF, u_IBLSampler), lutUV).rg;
    return (diffuseWeight * irradiance * baseColor / PI + reflected * (f0 * lut.x + lut.y)) * u_IBLParameters.y;
}

mat3 cotangentFrame(vec3 normal, vec3 position, vec2 uv) {
    vec3 positionX = dFdx(position);
    vec3 positionY = dFdy(position);
    vec2 uvX = dFdx(uv);
    vec2 uvY = dFdy(uv);
    vec3 positionYPerpendicular = cross(positionY, normal);
    vec3 positionXPerpendicular = cross(normal, positionX);
    vec3 tangent = positionYPerpendicular * uvX.x + positionXPerpendicular * uvY.x;
    vec3 bitangent = positionYPerpendicular * uvX.y + positionXPerpendicular * uvY.y;
    float scale = inversesqrt(max(max(dot(tangent, tangent), dot(bitangent, bitangent)), 0.000001));
    return mat3(tangent * scale, bitangent * scale, normal);
}

vec3 materialNormal() {
    vec3 normal = normalize(Input.ViewNormal);
    if (Input.TextureFlags.z < 0.5) {
        return normal;
    }

    vec3 tangentNormal = texture(sampler2D(u_NormalTexture, u_NormalSampler), materialUV(u_UVSets.z)).xyz * 2.0 - 1.0;
    tangentNormal.xy *= u_SurfaceProperties.x;
    if (Input.TextureFlags.w > 0.5 && u_UVSets.z < 0.5) {
        vec3 tangent = normalize(Input.ViewTangent.xyz - normal * dot(normal, Input.ViewTangent.xyz));
        vec3 bitangent = normalize(cross(normal, tangent)) * Input.ViewTangent.w;
        return normalize(mat3(tangent, bitangent, normal) * tangentNormal);
    }

    return normalize(cotangentFrame(normal, Input.ViewPosition, materialUV(u_UVSets.z)) * tangentNormal);
}

float cascadeVisibility(int cascade, vec3 normal, vec3 lightDirection) {
    vec4 position;
    if (cascade == 0) { position = u_ShadowViewProjection * vec4(Input.WorldPosition, 1.0); }
    else if (cascade == 1) { position = u_ShadowViewProjection1 * vec4(Input.WorldPosition, 1.0); }
    else { position = u_ShadowViewProjection2 * vec4(Input.WorldPosition, 1.0); }
    vec3 projected = position.xyz / position.w;
    vec2 localUV = projected.xy * vec2(0.5, -0.5) + 0.5;
    if (projected.z < 0.0 || projected.z > 1.0 || any(lessThan(localUV, vec2(0.0))) || any(greaterThan(localUV, vec2(1.0)))) { return 1.0; }
    float count = max(u_CascadeSplits.w, 1.0);
    vec2 uv = vec2((localUV.x + float(cascade)) / count, localUV.y);
    vec2 minimum = vec2(float(cascade) / count, 0.0) + u_ShadowAtlas.xy * 0.5;
    vec2 maximum = vec2(float(cascade + 1) / count, 1.0) - u_ShadowAtlas.xy * 0.5;
    float bias = u_ShadowParameters.y + u_ShadowParameters.z * (1.0 - max(dot(normal, lightDirection), 0.0));
    float visibility = 0.0;
    for (int y = -1; y <= 1; ++y) {
        for (int x = -1; x <= 1; ++x) {
            vec2 sampleUV = clamp(uv + vec2(float(x), float(y)) * u_ShadowAtlas.xy, minimum, maximum);
            float storedDepth = texture(sampler2D(u_DirectionalShadowTexture, u_DirectionalShadowSampler), sampleUV).r;
            visibility += projected.z - bias <= storedDepth ? 1.0 : 0.0;
        }
    }
    return visibility / 9.0;
}

float directionalShadow(vec3 normal, vec3 lightDirection) {
    if (Input.ShadowFlags.x < 0.5 || u_ShadowParameters.x < 0.5) { return 1.0; }
    float depth = Input.ViewPosition.z;
    if (depth > u_CascadeSplits.z) { return 1.0; }
    int count = int(u_CascadeSplits.w);
    int cascade = depth <= u_CascadeSplits.x ? 0 : (depth <= u_CascadeSplits.y ? 1 : 2);
    cascade = min(cascade, count - 1);
    float visibility = cascadeVisibility(cascade, normal, lightDirection);
    if (cascade < count - 1) {
        float edge = cascade == 0 ? u_CascadeSplits.x : u_CascadeSplits.y;
        float start = cascade == 0 ? 0.0 : u_CascadeSplits.x;
        float width = (edge - start) * u_ShadowAtlas.z;
        if (width > 0.0 && depth > edge - width) {
            float next = cascadeVisibility(cascade + 1, normal, lightDirection);
            visibility = mix(visibility, next, smoothstep(edge - width, edge, depth));
        }
    }
    return visibility;
}

float visibilityDither(vec2 pixel) {
    int x = int(mod(floor(pixel.x), 4.0)), y = int(mod(floor(pixel.y), 4.0));
    const float values[16] = float[](0.0,8.0,2.0,10.0,12.0,4.0,14.0,6.0,3.0,11.0,1.0,9.0,15.0,7.0,13.0,5.0);
    return (values[y * 4 + x] + 0.5) / 16.0;
}

[[main]]
void flat3d_fragment()
{
    if (Input.ShadowFlags.w > 0.0 && visibilityDither(gl_FragCoord.xy) < Input.ShadowFlags.w) { discard; }
    if (u_SurfaceFlags.x < 0.5 && !gl_FrontFacing) { discard; }
    vec4 baseColor = Input.Color;
    if (Input.TextureFlags.x > 0.5) {
        vec4 sampledBaseColor = texture(sampler2D(u_BaseColorTexture, u_BaseColorSampler), materialUV(u_UVSets.x));
        baseColor *= vec4(srgbToLinear(sampledBaseColor.rgb), sampledBaseColor.a);
    }

    if (u_SurfaceProperties.w > 0.5 && u_SurfaceProperties.w < 1.5 && baseColor.a < u_SurfaceProperties.z) { discard; }
    float opacity = u_SurfaceProperties.w > 1.5 ? baseColor.a : 1.0;
    float roughness = Input.Roughness;
    float metallic = Input.Metallic;
    if (Input.TextureFlags.y > 0.5) {
        vec4 metallicRoughness = texture(
            sampler2D(u_MetallicRoughnessTexture, u_MetallicRoughnessSampler),
            materialUV(u_UVSets.y)
        );
        roughness = clamp(roughness * metallicRoughness.g, 0.04, 1.0);
        metallic = clamp(metallic * metallicRoughness.b, 0.0, 1.0);
    }

    vec3 normal = materialNormal();
    if (!gl_FrontFacing && u_SurfaceFlags.x > 0.5) { normal = -normal; }
    vec3 viewDirection = normalize(-Input.ViewPosition);
    vec3 lightDirection = normalize(u_LightDirectionIntensity.xyz);
    gl_FragDepth = gl_FragCoord.z;

    if (Input.ShadowFlags.y > 0.0) {
        // The atmosphere is drawn before the planet. Keep its haze in the
        // color target without preventing the opaque planet from drawing.
        gl_FragDepth = 1.0;

        float dayFacing = smoothstep(-0.3, 0.55, dot(normal, lightDirection));
        float fresnelPower = mix(
            Input.ShadowFlags.y + 1.5,
            Input.ShadowFlags.y * 0.58,
            dayFacing
        );
        float fresnel = pow(
            clamp(1.0 - abs(dot(normal, viewDirection)), 0.0, 1.0),
            max(fresnelPower, 0.5)
        );
        float alpha = clamp(
            baseColor.a * Input.ShadowFlags.z * fresnel * mix(0.28, 1.0, dayFacing),
            0.0,
            0.88
        );
        vec3 atmosphereColor = baseColor.rgb * mix(0.72, 1.2, dayFacing);

        color = vec4(atmosphereColor, alpha);
        indirectLighting = vec4(0.0, 0.0, 0.0, alpha);
        normalRoughness = vec4(normal, 1.0);
        viewPositionMetallic = vec4(Input.ViewPosition, 0.0);
        return;
    }

    vec3 halfway = normalize(viewDirection + lightDirection);
    float normalLight = max(dot(normal, lightDirection), 0.0);
    float normalView = max(dot(normal, viewDirection), 0.0);

    vec3 reflectanceAtNormal = mix(vec3(0.04), baseColor.rgb, metallic);
    vec3 fresnel = fresnelSchlick(max(dot(halfway, viewDirection), 0.0), reflectanceAtNormal);
    float distribution = distributionGGX(normal, halfway, roughness);
    float geometry = geometrySmith(normal, viewDirection, lightDirection, roughness);
    vec3 specular = distribution * geometry * fresnel / max(4.0 * normalView * normalLight, 0.0001);
    vec3 diffuseWeight = (vec3(1.0) - fresnel) * (1.0 - metallic);
    vec3 radiance = max(u_LightRadianceAmbient.rgb, vec3(0.0)) * max(u_LightDirectionIntensity.w, 0.0);
    float shadowVisibility = directionalShadow(normal, lightDirection);
    vec3 directLighting = (diffuseWeight * baseColor.rgb / PI + specular) * radiance * normalLight * shadowVisibility;
    vec3 ambient = baseColor.rgb * (1.0 - metallic) * max(u_LightRadianceAmbient.w, 0.0);
    if (u_IBLParameters.x > 0.5) { ambient = environmentLighting(normal, viewDirection, baseColor.rgb, metallic, roughness); }
    float occlusion = u_SurfaceFlags.y > 0.5 ? texture(sampler2D(u_OcclusionTexture, u_OcclusionSampler), materialUV(u_UVSets.w)).r : 1.0;
    ambient *= mix(1.0, occlusion, u_SurfaceProperties.y);
    float emissiveVisibility = 1.0;
    if (Input.EmissiveLightThreshold >= 0.0) {
        emissiveVisibility = 1.0 - smoothstep(
            Input.EmissiveLightThreshold,
            Input.EmissiveLightThreshold + 0.16,
            normalLight
        );
    }
    vec3 emissive = srgbToLinear(texture(
        sampler2D(u_EmissiveTexture, u_EmissiveSampler),
        materialUV(u_Emission.x)
    ).rgb) * u_EmissiveFactor.rgb * Input.EmissiveStrength * emissiveVisibility;

    color = vec4(directLighting + ambient + emissive, opacity);
    // Transparent surfaces attenuate the opaque indirect buffer but do not contribute to it.
    indirectLighting = vec4(u_SurfaceProperties.w > 1.5 ? vec3(0.0) : ambient, opacity);
    normalRoughness = vec4(normal, roughness);
    viewPositionMetallic = vec4(Input.ViewPosition, metallic);
}
