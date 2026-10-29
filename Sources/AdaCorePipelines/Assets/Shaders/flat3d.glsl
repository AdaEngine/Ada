#version 450 core
#pragma stage : vert
#ifdef ADA_MORPH
#extension GL_EXT_samplerless_texture_functions : require
#endif

#ifdef ADA_METAL_RENDER_LAYER
#extension GL_ARB_shader_viewport_layer_array : require
layout (binding = 30) uniform RenderTargetLayer {
    uint u_RenderTargetLayer;
};
#endif

#include <AdaEngine/View.glsl>
#include <AdaEngine/Morph.glsl>

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
    mat4 u_JointMatrices[256];
};

layout (location = 12) in vec4 a_ShadowFlags;

mat4 skinTransform() {
    int jointBase = int(max(0.0, -a_ShadowFlags.y));
    if (a_JointIndices.x < 0.0) { return mat4(1.0); }
    return u_JointMatrices[jointBase + int(a_JointIndices.x)] * a_JointWeights.x
        + u_JointMatrices[jointBase + int(a_JointIndices.y)] * a_JointWeights.y
        + u_JointMatrices[jointBase + int(a_JointIndices.z)] * a_JointWeights.z
        + u_JointMatrices[jointBase + int(a_JointIndices.w)] * a_JointWeights.w;
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
layout (location = 14) flat out float ModelOrientation;

[[main]]
void flat3d_vertex()
{
#ifdef ADA_METAL_RENDER_LAYER
    gl_Layer = int(u_RenderTargetLayer);
#endif
    // Morph targets move the rest pose first; skinning then moves the morphed pose.
    vec3 localPosition = a_Position;
    vec3 localNormal = a_Normal;
    vec3 localTangent = a_Tangent.xyz;
#ifdef ADA_MORPH
    applyMorph(localPosition, localNormal, localTangent);
#endif
    mat4 model = mat4(a_Model0, a_Model1, a_Model2, a_Model3) * skinTransform();
    mat3 basis = mat3(model);
    float basisDeterminant = determinant(basis);
    ModelOrientation = basisDeterminant < 0.0 ? -1.0 : 1.0;
    mat3 normalMatrix = abs(basisDeterminant) > 0.000001 ? transpose(inverse(basis)) : mat3(1.0);
    vec3 normal = normalize(normalMatrix * localNormal);
    vec4 worldPosition = model * vec4(localPosition, 1.0);
    vec3 worldTangent = normalize(mat3(model) * localTangent);
    Output.Color = a_Color * a_VertexColor;
    Output.WorldPosition = worldPosition.xyz;
    Output.ViewPosition = (u_ViewMatrix * worldPosition).xyz;
    Output.ViewNormal = normalize(mat3(u_ViewMatrix) * normal);
    Output.ViewTangent = vec4(normalize(mat3(u_ViewMatrix) * worldTangent), a_Tangent.w * ModelOrientation);
    Output.TextureCoordinate = a_TextureCoordinate;
    Output.TextureCoordinate1 = a_TextureCoordinate1;
    Output.TextureFlags = a_TextureFlags;
    Output.ShadowFlags = a_ShadowFlags;
    Output.ShadowFlags.y = max(0.0, Output.ShadowFlags.y);
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

#include <AdaEngine/Tonemapping.glsl>

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
#include <AdaEngine/ShadowPCF.glsl>
layout (binding = 12) uniform texture2D u_EmissiveTexture;
layout (binding = 13) uniform sampler u_EmissiveSampler;

layout (binding = 15) uniform PBR3DUniform {
    vec4 u_EmissiveFactor;
    vec4 u_SurfaceProperties;
    vec4 u_SurfaceFlags;
    vec4 u_UVSets;
    vec4 u_Emission;
    vec4 u_Parallax;
    // Per texture slot (base color, metallic/roughness, normal, occlusion, emission): xyzw is a row-major 2x2
    // matrix, then xy is the offset (glTF KHR_texture_transform).
    vec4 u_TextureTransforms[10];
    vec4 u_Dielectric; // rgb: reflectance of non-metals at normal incidence (0.04 for the default IOR of 1.5)
    vec4 u_Coat;       // x clearcoat strength, y clearcoat roughness (KHR_materials_clearcoat)
    vec4 u_Sheen;      // rgb sheen color, w sheen roughness (KHR_materials_sheen)
    vec4 u_Anisotropy; // x strength, y rotation in radians (KHR_materials_anisotropy)
    // UV set of each layer texture (clearcoat, clearcoat roughness, clearcoat normal, sheen color, sheen roughness,
    // anisotropy, specular, specular color), and for each a row-major 2x2 matrix then an offset.
    vec4 u_LayerSets[2];
    vec4 u_LayerTransforms[16];
    vec4 u_LayerParameters; // x clearcoat normal scale
};

// Layer textures exist only in the shader variants of materials that have them. They are read with the base color
// sampler, because the main pass has no free sampler slot.
#ifdef ADA_CLEARCOAT_TEXTURE
layout (binding = 32) uniform texture2D u_ClearcoatTexture;
#endif
#ifdef ADA_CLEARCOAT_ROUGHNESS_TEXTURE
layout (binding = 33) uniform texture2D u_ClearcoatRoughnessTexture;
#endif
#ifdef ADA_CLEARCOAT_NORMAL_TEXTURE
layout (binding = 34) uniform texture2D u_ClearcoatNormalTexture;
#endif
#ifdef ADA_SHEEN_COLOR_TEXTURE
layout (binding = 35) uniform texture2D u_SheenColorTexture;
#endif
#ifdef ADA_SHEEN_ROUGHNESS_TEXTURE
layout (binding = 36) uniform texture2D u_SheenRoughnessTexture;
#endif
#ifdef ADA_ANISOTROPY_TEXTURE
layout (binding = 37) uniform texture2D u_AnisotropyTexture;
#endif
#ifdef ADA_SPECULAR_TEXTURE
layout (binding = 38) uniform texture2D u_SpecularTexture;
#endif
#ifdef ADA_SPECULAR_COLOR_TEXTURE
layout (binding = 39) uniform texture2D u_SpecularColorTexture;
#endif

vec2 applyTextureTransform(vec2 uv, int slot) {
    vec4 matrix = u_TextureTransforms[slot * 2];
    return vec2(dot(matrix.xy, uv), dot(matrix.zw, uv)) + u_TextureTransforms[slot * 2 + 1].xy;
}
layout (binding = 16) uniform texture2D u_OcclusionTexture;
layout (binding = 17) uniform texture2D u_HeightTexture;
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
layout (location = 14) flat in float ModelOrientation;

bool surfaceFrontFacing() {
    // Reflection reverses raster winding, while inverse-transpose normals still face physically outward.
    return ModelOrientation < 0.0 ? !gl_FrontFacing : gl_FrontFacing;
}

struct LocalLight3D {
    vec4 positionRange;
    vec4 radianceIntensity;
    vec4 directionOuter;
    vec4 innerShadow;
};
layout (binding = 25) uniform LocalLighting3DUniform {
    vec4 u_LightCounts;
    vec4 u_AdditionalDirections[3];
    vec4 u_AdditionalRadiance[3];
    LocalLight3D u_LocalLights[32];
};
layout (binding = 28) uniform LocalShadow3DUniform {
    mat4 u_LocalShadowMatrices[24];
    vec4 u_LocalAtlas;
};
layout (binding = 26) uniform texture2D u_LocalShadowTexture;
layout (binding = 27) uniform LightTiles3DUniform {
    mat4 u_TileProjection;
    vec4 u_TileViewport; // xy pixel origin, zw pixel size of the viewport the projection maps to
    vec4 u_TileInfo;     // x tile size in pixels, y columns, z rows, w 1 when tile masks are valid
};
layout (binding = 29) uniform LightTileMasks3DUniform {
    uvec4 u_TileMasks[1024];
};

// Bit mask of the local lights that may reach this fragment. The tile comes from projecting the view-space
// position the same way the CPU bounded each light, so it holds for any backend's fragment coordinate origin.
uint localLightMask() {
    uint reachable = int(u_LightCounts.y) >= 32 ? 0xFFFFFFFFu : ((1u << uint(max(int(u_LightCounts.y), 0))) - 1u);
    if (u_TileInfo.w < 0.5) { return reachable; }
    vec4 clip = u_TileProjection * vec4(Input.ViewPosition, 1.0);
    if (clip.w <= 0.0001) { return reachable; }
    vec2 pixel = u_TileViewport.xy + vec2(clip.x / clip.w * 0.5 + 0.5, 0.5 - clip.y / clip.w * 0.5) * u_TileViewport.zw;
    ivec2 tile = clamp(ivec2(floor(pixel / u_TileInfo.x)), ivec2(0), ivec2(int(u_TileInfo.y) - 1, int(u_TileInfo.z) - 1));
    int index = tile.y * int(u_TileInfo.y) + tile.x;
    return u_TileMasks[index >> 2][index & 3] & reachable;
}

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

// Clearcoat layer: x strength, y roughness. It sits on the geometric normal, not on the normal map. Set once per fragment.
vec2 g_Clearcoat = vec2(0.0);
vec3 g_CoatNormal = vec3(0.0, 0.0, 1.0);

// The optional layers are compiled in only for materials that use them (ADA_CLEARCOAT, ADA_SHEEN, ADA_ANISOTROPY), which
// keeps the common path as small as it was before the layers existed.
bool hasClearcoat() {
#ifdef ADA_CLEARCOAT
    return g_Clearcoat.x > 0.0;
#else
    return false;
#endif
}

// Share of the base layer's light that survives the coat at this view angle.
float coatTransmission(float normalView) {
    return 1.0 - g_Clearcoat.x * fresnelSchlick(normalView, vec3(0.04)).x;
}

// Reflectance of non-metals at normal incidence for this fragment: the material value times its specular textures.
vec3 g_Dielectric = vec3(0.04);

// Sheen layer (cloth): rgb color, w roughness. A black color turns it off.
vec4 g_Sheen = vec4(0.0);
// Average share of light the sheen lobe takes from the base layer. The glTF sheen albedo lookup is replaced by this constant.
const float SHEEN_ALBEDO = 0.4;

bool hasSheen() {
#ifdef ADA_SHEEN
    return max(g_Sheen.r, max(g_Sheen.g, g_Sheen.b)) > 0.0;
#else
    return false;
#endif
}

// Share of the base layer's light that survives the sheen.
float sheenTransmission() {
    return 1.0 - max(g_Sheen.r, max(g_Sheen.g, g_Sheen.b)) * SHEEN_ALBEDO;
}

// Anisotropy: strength, and the view-space tangent and bitangent of the stretched highlight.
float g_Anisotropy = 0.0;
vec3 g_AnisotropyT = vec3(1.0, 0.0, 0.0);
vec3 g_AnisotropyB = vec3(0.0, 1.0, 0.0);

bool hasAnisotropy() {
#ifdef ADA_ANISOTROPY
    return g_Anisotropy > 0.0;
#else
    return false;
#endif
}

// UV shift from parallax occlusion mapping, applied to every material texture that uses the height map's UV set.
vec2 g_ParallaxDelta = vec2(0.0);

vec2 materialUV(float setIndex, int slot) {
    vec2 uv = setIndex > 0.5 ? Input.TextureCoordinate1 : Input.TextureCoordinate;
    // The parallax shift lives in mesh UV space, so it applies before the texture's own transform.
    if (abs(setIndex - u_Parallax.y) < 0.5) { uv += g_ParallaxDelta; }

    return applyTextureTransform(uv, slot);
}

// UV of a layer texture (slot 0 to 7 in PBRLayerTexture order): its UV set, with the parallax shift, then its own transform.
vec2 layerUV(int slot) {
    float setIndex = u_LayerSets[slot >> 2][slot & 3];
    vec2 uv = setIndex > 0.5 ? Input.TextureCoordinate1 : Input.TextureCoordinate;
    if (abs(setIndex - u_Parallax.y) < 0.5) { uv += g_ParallaxDelta; }
    vec4 matrix = u_LayerTransforms[slot * 2];
    return vec2(dot(matrix.xy, uv), dot(matrix.zw, uv)) + u_LayerTransforms[slot * 2 + 1].xy;
}

// Ray-marches the height map along the view ray. Returns the UV shift that makes the surface appear to have depth.
// Depth is measured in view units: a surface point `d * scale` below the top shifts by `d * scale` along the view
// ray's projection onto the surface, converted to UV through the screen-space position/UV derivatives so no
// tangent frame is needed.
vec2 parallaxDelta() {
    vec3 normal = normalize(Input.ViewNormal);
    vec3 viewDirection = normalize(-Input.ViewPosition);
    float facing = dot(normal, viewDirection);
    if (facing < 0.0) { normal = -normal; facing = -facing; }
    float fadeDistance = u_Parallax.w;
    float scale = u_Parallax.x * (1.0 - smoothstep(fadeDistance * 0.5, fadeDistance, length(Input.ViewPosition)));
    vec2 uv = u_Parallax.y > 0.5 ? Input.TextureCoordinate1 : Input.TextureCoordinate;
    vec3 positionX = dFdx(Input.ViewPosition);
    vec3 positionY = dFdy(Input.ViewPosition);
    float xx = dot(positionX, positionX), xy = dot(positionX, positionY), yy = dot(positionY, positionY);
    float determinant = xx * yy - xy * xy;
    if (scale <= 0.0 || abs(determinant) < 1e-12) { return vec2(0.0); }

    vec3 shift = -(viewDirection - normal * facing) / max(facing, 0.08);
    vec2 projected = vec2(dot(shift, positionX), dot(shift, positionY));
    vec2 coefficients = vec2(yy * projected.x - xy * projected.y, xx * projected.y - xy * projected.x) / determinant;
    vec2 uvPerDepth = (dFdx(uv) * coefficients.x + dFdy(uv) * coefficients.y) * scale;

    vec2 gradientX = dFdx(uv), gradientY = dFdy(uv);
    float maximumLayers = u_Parallax.z;
    float layers = mix(maximumLayers, max(maximumLayers * 0.25, 4.0), clamp(facing, 0.0, 1.0));
    float previousDepth = 0.0;
    float previousGap = -(1.0 - textureGrad(sampler2D(u_HeightTexture, u_BaseColorSampler), uv, gradientX, gradientY).r);
    float hitDepth = 1.0;
    for (int i = 1; i <= 64; ++i) {
        if (float(i) > layers) { break; }
        float depth = float(i) / layers;
        float height = textureGrad(sampler2D(u_HeightTexture, u_BaseColorSampler), uv + uvPerDepth * depth, gradientX, gradientY).r;
        float gap = depth - (1.0 - height);
        if (gap >= 0.0) {
            hitDepth = mix(previousDepth, depth, previousGap / (previousGap - gap));
            break;
        }
        previousDepth = depth;
        previousGap = gap;
    }
    return uvPerDepth * hitDepth;
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
    vec3 f0 = mix(g_Dielectric, baseColor, metallic);
    vec3 fresnel = f0 + (max(vec3(1.0 - roughness), f0) - f0) * pow(1.0 - ndotv, 5.0);
    vec3 diffuseWeight = (vec3(1.0) - fresnel) * (1.0 - metallic);
    vec3 irradiance = texture(sampler2D(u_Irradiance, u_IBLSampler), environmentUV(worldNormal)).rgb;
    vec3 reflectionNormal = worldNormal;
    if (hasAnisotropy()) {
        // Bend the reflection toward the stretched direction so the environment smears along it (Filament).
        vec3 anisotropicTangent = cross(g_AnisotropyB, viewDirection);
        vec3 anisotropicNormal = cross(anisotropicTangent, g_AnisotropyB);
        float bend = g_Anisotropy * clamp(5.0 * roughness, 0.0, 1.0);
        reflectionNormal = normalize(mat3(u_EnvironmentInverseView) * normalize(mix(normal, anisotropicNormal, bend)));
    }
    vec3 reflected = samplePrefiltered(reflect(-worldView, reflectionNormal), roughness);
    vec2 lutSize = vec2(textureSize(sampler2D(u_BRDF, u_IBLSampler), 0));
    vec2 lutUV = clamp(vec2(ndotv, roughness), 0.5 / lutSize, vec2(1.0) - 0.5 / lutSize);
    vec2 lut = texture(sampler2D(u_BRDF, u_IBLSampler), lutUV).rg;
    vec3 result = (diffuseWeight * irradiance * baseColor / PI + reflected * (f0 * lut.x + lut.y)) * u_IBLParameters.y;
    if (hasSheen()) {
        // Sheen under image-based lighting is approximated as a diffuse lobe with the average sheen albedo.
        result = result * sheenTransmission() + g_Sheen.rgb * SHEEN_ALBEDO * irradiance / PI * u_IBLParameters.y;
    }
    if (hasClearcoat()) {
        // The coat reflects the environment along the geometric normal and dims the base layer beneath it.
        vec3 coatWorldNormal = normalize(mat3(u_EnvironmentInverseView) * g_CoatNormal);
        float coatNormalView = max(dot(g_CoatNormal, viewDirection), 0.0);
        vec2 coatLutUV = clamp(vec2(coatNormalView, g_Clearcoat.y), 0.5 / lutSize, vec2(1.0) - 0.5 / lutSize);
        vec2 coatLut = texture(sampler2D(u_BRDF, u_IBLSampler), coatLutUV).rg;
        vec3 coatReflected = samplePrefiltered(reflect(-worldView, coatWorldNormal), g_Clearcoat.y);
        result = result * coatTransmission(coatNormalView) + coatReflected * (0.04 * coatLut.x + coatLut.y) * g_Clearcoat.x * u_IBLParameters.y;
    }
    return result;
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

    vec3 tangentNormal = texture(sampler2D(u_NormalTexture, u_NormalSampler), materialUV(u_UVSets.z, 2)).xyz * 2.0 - 1.0;
    tangentNormal.xy *= u_SurfaceProperties.x;
    // Authored tangents follow the mesh UVs, so they only hold while the normal map's transform keeps its axes.
    vec4 normalMatrix = u_TextureTransforms[4];
    bool keepsTangents = abs(normalMatrix.y) < 0.0001 && abs(normalMatrix.z) < 0.0001 && normalMatrix.x > 0.0 && normalMatrix.w > 0.0;
    if (Input.TextureFlags.w > 0.5 && u_UVSets.z < 0.5 && keepsTangents) {
        vec3 tangent = normalize(Input.ViewTangent.xyz - normal * dot(normal, Input.ViewTangent.xyz));
        vec3 bitangent = normalize(cross(normal, tangent)) * Input.ViewTangent.w;
        return normalize(mat3(tangent, bitangent, normal) * tangentNormal);
    }

    return normalize(cotangentFrame(normal, Input.ViewPosition, materialUV(u_UVSets.z, 2)) * tangentNormal);
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
    return adaDirectionalShadowPCF(uv, u_ShadowAtlas.xy, minimum, maximum, projected.z - bias);
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

// The coat's own highlight for one light (rgb, already scaled by radiance and n.l) and the transmission of the
// base layer under it (a).
vec4 clearcoatDirect(vec3 viewDirection, vec3 lightDirection, vec3 radiance) {
    vec3 normal = g_CoatNormal;
    float nl = max(dot(normal, lightDirection), 0.0), nv = max(dot(normal, viewDirection), 0.0);
    float transmission = coatTransmission(nv);
    if (nl <= 0.0 || nv <= 0.0) { return vec4(0.0, 0.0, 0.0, transmission); }
    vec3 halfway = normalize(viewDirection + lightDirection);
    float fresnel = fresnelSchlick(max(dot(halfway, viewDirection), 0.0), vec3(0.04)).x * g_Clearcoat.x;
    float distribution = distributionGGX(normal, halfway, g_Clearcoat.y);
    float geometry = geometrySmith(normal, viewDirection, lightDirection, g_Clearcoat.y);
    float specular = distribution * geometry * fresnel / max(4.0 * nv * nl, 0.0001);
    return vec4(vec3(specular) * max(radiance, vec3(0.0)) * nl, transmission);
}

// Charlie sheen distribution (Estevez and Kulla) and the Neubelt visibility term, as in the glTF sheen specification.
float sheenDistribution(float roughness, float normalHalfway) {
    float alpha = roughness * roughness;
    float inverseAlpha = 1.0 / alpha;
    float sine2 = max(1.0 - normalHalfway * normalHalfway, 0.0078125);
    return (2.0 + inverseAlpha) * pow(sine2, inverseAlpha * 0.5) / (2.0 * PI);
}

float sheenVisibility(float normalLight, float normalView) {
    return clamp(1.0 / (4.0 * (normalLight + normalView - normalLight * normalView)), 0.0, 1.0);
}

vec3 evaluateDirect(vec3 normal, vec3 viewDirection, vec3 lightDirection, vec3 baseColor, float metallic, float roughness, vec3 radiance) {
    float nl = max(dot(normal, lightDirection), 0.0), nv = max(dot(normal, viewDirection), 0.0);
    vec3 base = vec3(0.0);
    if (nl > 0.0 && nv > 0.0) {
        vec3 halfway = normalize(viewDirection + lightDirection);
        vec3 f0 = mix(g_Dielectric, baseColor, metallic);
        vec3 fresnel = fresnelSchlick(max(dot(halfway, viewDirection), 0.0), f0);
        vec3 specular;
        if (hasAnisotropy()) {
            // Anisotropic GGX: roughness stretches along the tangent, so the highlight streaks along the bitangent.
            float normalHalfway = max(dot(normal, halfway), 0.0);
            float alpha = roughness * roughness;
            float alphaT = mix(alpha, 1.0, g_Anisotropy * g_Anisotropy), alphaB = alpha;
            float tangentHalfway = dot(g_AnisotropyT, halfway), bitangentHalfway = dot(g_AnisotropyB, halfway);
            float denominator = tangentHalfway * tangentHalfway / (alphaT * alphaT) + bitangentHalfway * bitangentHalfway / (alphaB * alphaB) + normalHalfway * normalHalfway;
            float distribution = 1.0 / max(PI * alphaT * alphaB * denominator * denominator, 0.000001);
            float lambdaView = nl * length(vec3(alphaT * dot(g_AnisotropyT, viewDirection), alphaB * dot(g_AnisotropyB, viewDirection), nv));
            float lambdaLight = nv * length(vec3(alphaT * dot(g_AnisotropyT, lightDirection), alphaB * dot(g_AnisotropyB, lightDirection), nl));
            specular = fresnel * distribution * 0.5 / max(lambdaView + lambdaLight, 0.00001);
        } else {
            float distribution = distributionGGX(normal, halfway, roughness);
            float geometry = geometrySmith(normal, viewDirection, lightDirection, roughness);
            specular = distribution * geometry * fresnel / max(4.0 * nv * nl, 0.0001);
        }
        base = ((vec3(1.0) - fresnel) * (1.0 - metallic) * baseColor / PI + specular) * max(radiance, vec3(0.0)) * nl;
        if (hasSheen()) {
            vec3 sheen = g_Sheen.rgb * sheenDistribution(g_Sheen.w, max(dot(normal, halfway), 0.0)) * sheenVisibility(nl, nv);
            base = base * sheenTransmission() + sheen * max(radiance, vec3(0.0)) * nl;
        }
    }
    if (!hasClearcoat()) { return base; }
    vec4 coat = clearcoatDirect(viewDirection, lightDirection, radiance);
    return base * coat.a + coat.rgb;
}

int localPointFace(vec3 ray) {
    vec3 a = abs(ray);
    if (a.x >= a.y && a.x >= a.z) { return ray.x >= 0.0 ? 0 : 1; }
    if (a.y >= a.z) { return ray.y >= 0.0 ? 2 : 3; }
    return ray.z >= 0.0 ? 4 : 5;
}

float localShadowVisibility(LocalLight3D light, vec3 lightDirection, vec3 normal) {
    int slot = int(light.innerShadow.w);
    if (slot < 0 || slot >= 4 || Input.ShadowFlags.x < 0.5) { return 1.0; }
    // View-space direction to the surface converted back to world-space for cube-face choice.
    vec3 worldRay = mat3(u_EnvironmentInverseView) * (Input.ViewPosition - light.positionRange.xyz);
    int face = light.directionOuter.w < 0.0 ? localPointFace(worldRay) : 0;
    vec4 clip = u_LocalShadowMatrices[slot * 6 + face] * vec4(Input.WorldPosition, 1.0);
    if (clip.w <= 0.0) { return 1.0; }
    vec3 ndc = clip.xyz / clip.w;
    if (ndc.z < 0.0 || ndc.z > 1.0 || any(greaterThan(abs(ndc.xy), vec2(1.0)))) { return 1.0; }
    vec2 tileOrigin = vec2(float(face), float(slot)) * u_LocalAtlas.z;
    vec2 texel = u_LocalAtlas.xy;
    vec2 uv = (tileOrigin + (ndc.xy * vec2(0.5, -0.5) + 0.5) * u_LocalAtlas.z) * texel;
    vec2 lo = (tileOrigin + 0.5) * texel, hi = (tileOrigin + u_LocalAtlas.z - 0.5) * texel;
    float bias = light.innerShadow.y + light.innerShadow.z * (1.0 - max(dot(normal, lightDirection), 0.0));
    float visibility = 0.0;
    for (int y = -1; y <= 1; ++y) { for (int x = -1; x <= 1; ++x) {
        float stored = texture(sampler2D(u_LocalShadowTexture, u_DirectionalShadowSampler), clamp(uv + vec2(float(x), float(y)) * texel, lo, hi)).r;
        visibility += ndc.z - bias <= stored ? 1.0 : 0.0;
    } }
    return visibility / 9.0;
}

vec3 additionalLighting(vec3 normal, vec3 viewDirection, vec3 baseColor, float metallic, float roughness) {
    vec3 result = vec3(0.0);
    for (int i = 0; i < 3; ++i) {
        if (i >= int(u_LightCounts.x)) { break; }
        result += evaluateDirect(normal, viewDirection, normalize(u_AdditionalDirections[i].xyz), baseColor, metallic, roughness,
            u_AdditionalRadiance[i].rgb * max(u_AdditionalDirections[i].w, 0.0));
    }
    uint mask = localLightMask();
    for (int n = 0; n < 32; ++n) {
        if (mask == 0u) { break; }
        int i = findLSB(mask);
        mask &= mask - 1u;
        LocalLight3D light = u_LocalLights[i];
        vec3 delta = light.positionRange.xyz - Input.ViewPosition;
        float distance = length(delta), range = light.positionRange.w;
        if (distance >= range || range <= 0.0) { continue; }
        vec3 direction = delta / max(distance, 0.00001);
        float ratio = distance / range;
        float cutoff = max(0.0, 1.0 - ratio * ratio * ratio * ratio);
        float attenuation = cutoff * cutoff / max(distance * distance, 0.01);
        if (light.directionOuter.w >= 0.0) {
            float cone = dot(normalize(light.directionOuter.xyz), -direction);
            attenuation *= smoothstep(light.directionOuter.w, light.innerShadow.x, cone);
        }
        if (attenuation <= 0.0) { continue; }
        vec3 contribution = evaluateDirect(normal, viewDirection, direction, baseColor, metallic, roughness,
            light.radianceIntensity.rgb * max(light.radianceIntensity.w, 0.0) * attenuation);
        // The shadow lookup (nine depth taps) only scales the contribution, so a light that adds nothing here
        // (facing away, or behind the surface) never needs it.
        if (max(contribution.r, max(contribution.g, contribution.b)) <= 0.0) { continue; }
        result += contribution * localShadowVisibility(light, direction, normal);
    }
    return result;
}

float visibilityDither(vec2 pixel) {
    int x = int(mod(floor(pixel.x), 4.0)), y = int(mod(floor(pixel.y), 4.0));
    const float values[16] = float[](0.0,8.0,2.0,10.0,12.0,4.0,14.0,6.0,3.0,11.0,1.0,9.0,15.0,7.0,13.0,5.0);
    return (values[y * 4 + x] + 0.5) / 16.0;
}

// Debug visualizations selected by u_ShadowAtlas.w (see DebugView3D.mainPassMode). Mode 0 is normal shading.
vec3 heatRamp(float t) {
    t = clamp(t, 0.0, 1.0);
    return clamp(vec3(1.5 - abs(4.0 * t - 3.0), 1.5 - abs(4.0 * t - 2.0), 1.5 - abs(4.0 * t - 1.0)), 0.0, 1.0);
}

vec3 cascadeTint(float normalLight) {
    float shade = 0.35 + 0.65 * normalLight;
    if (Input.ShadowFlags.x < 0.5 || u_ShadowParameters.x < 0.5) { return vec3(0.5) * shade; }
    float depth = Input.ViewPosition.z;
    if (depth > u_CascadeSplits.z) { return vec3(0.18) * shade; }
    int count = int(u_CascadeSplits.w);
    int cascade = min(depth <= u_CascadeSplits.x ? 0 : (depth <= u_CascadeSplits.y ? 1 : 2), count - 1);
    vec3 tint = cascade == 0 ? vec3(0.9, 0.2, 0.2) : (cascade == 1 ? vec3(0.2, 0.8, 0.3) : vec3(0.25, 0.4, 0.95));
    return tint * shade;
}

float reachingLightCount() {
    float count = u_LightDirectionIntensity.w > 0.0 ? 1.0 : 0.0;
    count += float(int(u_LightCounts.x));
    for (int i = 0; i < 32; ++i) {
        if (i >= int(u_LightCounts.y)) { break; }
        LocalLight3D light = u_LocalLights[i];
        vec3 delta = light.positionRange.xyz - Input.ViewPosition;
        float distance = length(delta), range = light.positionRange.w;
        if (distance >= range || range <= 0.0) { continue; }
        if (light.directionOuter.w >= 0.0) {
            float cone = dot(normalize(light.directionOuter.xyz), -delta / max(distance, 0.00001));
            if (smoothstep(light.directionOuter.w, light.innerShadow.x, cone) <= 0.0) { continue; }
        }
        count += 1.0;
    }
    return count;
}

// Surface evaluation is independent of the shared lighting implementation.
#define ADA_GRAPH_SOURCE_MARKER 1

struct AdaPBRSurface {
    vec4 baseColor;
    vec3 normal;
    float roughness;
    float metallic;
    float opacity;
    float occlusion;
    vec3 emission;
};

AdaPBRSurface ada_material_surface() {
    #ifdef ADA_SHADER_GRAPH
    AdaGraphSurface graph = ada_graph_evaluate(Input.TextureCoordinate);
    vec4 baseColor = Input.Color * graph.color;
    baseColor.a *= graph.alpha;
    if (u_SurfaceProperties.w > 0.5 && u_SurfaceProperties.w < 1.5 && baseColor.a < u_SurfaceProperties.z) { discard; }
    float opacity = u_SurfaceProperties.w > 1.5 ? baseColor.a : 1.0;
    vec3 geometric = normalize(Input.ViewNormal);
    vec3 tangentNormal = length(graph.normal) > 0.00001 ? normalize(graph.normal) : vec3(0.0, 0.0, 1.0);
    vec3 normal;
    if (Input.TextureFlags.w > 0.5) {
        vec3 tangent = normalize(Input.ViewTangent.xyz - geometric * dot(geometric, Input.ViewTangent.xyz));
        vec3 bitangent = normalize(cross(geometric, tangent)) * Input.ViewTangent.w;
        normal = normalize(mat3(tangent, bitangent, geometric) * tangentNormal);
    } else {
        normal = normalize(cotangentFrame(geometric, Input.ViewPosition, Input.TextureCoordinate) * tangentNormal);
    }
    if (!surfaceFrontFacing() && u_SurfaceFlags.x > 0.5) { normal = -normal; }
    return AdaPBRSurface(baseColor, normal, clamp(graph.roughness, 0.04, 1.0), clamp(graph.metallic, 0.0, 1.0), opacity,
        clamp(graph.occlusion, 0.0, 1.0), max(graph.emission, vec3(0.0)));
    #else
    vec4 baseColor = Input.Color;
    if (Input.TextureFlags.x > 0.5) {
        vec4 sampledBaseColor = texture(sampler2D(u_BaseColorTexture, u_BaseColorSampler), materialUV(u_UVSets.x, 0));
        baseColor *= vec4(srgbToLinear(sampledBaseColor.rgb), sampledBaseColor.a);
    }

    if (u_SurfaceProperties.w > 0.5 && u_SurfaceProperties.w < 1.5 && baseColor.a < u_SurfaceProperties.z) { discard; }
    float opacity = u_SurfaceProperties.w > 1.5 ? baseColor.a : 1.0;
    float roughness = Input.Roughness;
    float metallic = Input.Metallic;
    if (Input.TextureFlags.y > 0.5) {
        vec4 metallicRoughness = texture(
            sampler2D(u_MetallicRoughnessTexture, u_MetallicRoughnessSampler),
            materialUV(u_UVSets.y, 1)
        );
        roughness = clamp(roughness * metallicRoughness.g, 0.04, 1.0);
        metallic = clamp(metallic * metallicRoughness.b, 0.0, 1.0);
    }

    vec3 normal = materialNormal();
    if (!surfaceFrontFacing() && u_SurfaceFlags.x > 0.5) { normal = -normal; }
    return AdaPBRSurface(baseColor, normal, roughness, metallic, opacity, 1.0, vec3(0.0));
    #endif
}

[[main]]
void flat3d_fragment()
{
    if (u_SurfaceFlags.z > 0.5) { g_ParallaxDelta = parallaxDelta(); }
    if (Input.ShadowFlags.w > 0.0 && visibilityDither(gl_FragCoord.xy) < Input.ShadowFlags.w) { discard; }
    if (u_SurfaceFlags.x < 0.5 && !surfaceFrontFacing()) { discard; }
    AdaPBRSurface surface = ada_material_surface();
    vec4 baseColor = surface.baseColor;
    float opacity = surface.opacity;
    float roughness = surface.roughness;
    float metallic = surface.metallic;
    vec3 normal = surface.normal;
    // Shading layers: each factor is multiplied by its texture when the material has one.
    g_Dielectric = u_Dielectric.rgb;
#ifdef ADA_SPECULAR_TEXTURE
    g_Dielectric *= texture(sampler2D(u_SpecularTexture, u_BaseColorSampler), layerUV(6)).a;
#endif
#ifdef ADA_SPECULAR_COLOR_TEXTURE
    g_Dielectric *= srgbToLinear(texture(sampler2D(u_SpecularColorTexture, u_BaseColorSampler), layerUV(7)).rgb);
#endif

    g_Sheen = vec4(max(u_Sheen.rgb, vec3(0.0)), clamp(u_Sheen.w, 0.07, 1.0));
#ifdef ADA_SHEEN_COLOR_TEXTURE
    g_Sheen.rgb *= srgbToLinear(texture(sampler2D(u_SheenColorTexture, u_BaseColorSampler), layerUV(3)).rgb);
#endif
#ifdef ADA_SHEEN_ROUGHNESS_TEXTURE
    g_Sheen.w = clamp(u_Sheen.w * texture(sampler2D(u_SheenRoughnessTexture, u_BaseColorSampler), layerUV(4)).a, 0.07, 1.0);
#endif

    g_Anisotropy = clamp(u_Anisotropy.x, 0.0, 1.0);
    vec2 anisotropyDirection = vec2(1.0, 0.0);
#ifdef ADA_ANISOTROPY_TEXTURE
    // Red and green hold the direction in tangent space, blue scales the strength.
    vec3 anisotropySample = texture(sampler2D(u_AnisotropyTexture, u_BaseColorSampler), layerUV(5)).rgb;
    g_Anisotropy = clamp(g_Anisotropy * anisotropySample.b, 0.0, 1.0);
    vec2 sampledDirection = anisotropySample.rg * 2.0 - 1.0;
    if (dot(sampledDirection, sampledDirection) > 0.0001) { anisotropyDirection = normalize(sampledDirection); }
#endif
    if (hasAnisotropy()) {
        bool authored = Input.TextureFlags.w > 0.5;
        vec3 tangent = authored ? Input.ViewTangent.xyz : cotangentFrame(normalize(Input.ViewNormal), Input.ViewPosition, materialUV(u_UVSets.x, 0))[0];
        tangent = normalize(tangent - normal * dot(normal, tangent));
        vec3 bitangent = normalize(cross(normal, tangent)) * (authored ? Input.ViewTangent.w : 1.0);
        // The rotation turns the direction, whether it comes from the texture or is the tangent itself.
        float rotationCosine = cos(u_Anisotropy.y), rotationSine = sin(u_Anisotropy.y);
        vec2 turned = vec2(rotationCosine * anisotropyDirection.x - rotationSine * anisotropyDirection.y,
            rotationSine * anisotropyDirection.x + rotationCosine * anisotropyDirection.y);
        g_AnisotropyT = normalize(turned.x * tangent + turned.y * bitangent);
        g_AnisotropyB = normalize(cross(normal, g_AnisotropyT));
    }

    g_Clearcoat = vec2(u_Coat.x, clamp(u_Coat.y, 0.04, 1.0));
    g_CoatNormal = normalize(Input.ViewNormal);
    if (!surfaceFrontFacing() && u_SurfaceFlags.x > 0.5) { g_CoatNormal = -g_CoatNormal; }
#ifdef ADA_CLEARCOAT_TEXTURE
    g_Clearcoat.x *= texture(sampler2D(u_ClearcoatTexture, u_BaseColorSampler), layerUV(0)).r;
#endif
#ifdef ADA_CLEARCOAT_ROUGHNESS_TEXTURE
    g_Clearcoat.y = clamp(u_Coat.y * texture(sampler2D(u_ClearcoatRoughnessTexture, u_BaseColorSampler), layerUV(1)).g, 0.04, 1.0);
#endif
#ifdef ADA_CLEARCOAT_NORMAL_TEXTURE
    vec3 coatTangentNormal = texture(sampler2D(u_ClearcoatNormalTexture, u_BaseColorSampler), layerUV(2)).xyz * 2.0 - 1.0;
    coatTangentNormal.xy *= u_LayerParameters.x;
    g_CoatNormal = normalize(cotangentFrame(g_CoatNormal, Input.ViewPosition, layerUV(2)) * coatTangentNormal);
#endif
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

    vec3 radiance = max(u_LightRadianceAmbient.rgb, vec3(0.0)) * max(u_LightDirectionIntensity.w, 0.0);
    // The sun term is multiplied by n.l, so surfaces facing away from it skip the cascade lookups. The clearcoat
    // follows the geometric normal and can still be lit there.
    float shadowVisibility = (normalLight > 0.0 || hasClearcoat()) ? directionalShadow(normal, lightDirection) : 1.0;
    vec3 directLighting = evaluateDirect(normal, viewDirection, lightDirection, baseColor.rgb, metallic, roughness, radiance) * shadowVisibility;
    directLighting += additionalLighting(normal, viewDirection, baseColor.rgb, metallic, roughness);
    vec3 ambient = baseColor.rgb * (1.0 - metallic) * max(u_LightRadianceAmbient.w, 0.0);
    if (u_IBLParameters.x > 0.5) { ambient = environmentLighting(normal, viewDirection, baseColor.rgb, metallic, roughness); }
    else if (hasClearcoat()) { ambient *= coatTransmission(max(dot(g_CoatNormal, viewDirection), 0.0)); }
    #ifdef ADA_SHADER_GRAPH
    float occlusion = surface.occlusion;
    #else
    float occlusion = u_SurfaceFlags.y > 0.5 ? texture(sampler2D(u_OcclusionTexture, u_OcclusionSampler), materialUV(u_UVSets.w, 3)).r : 1.0;
    #endif
    ambient *= mix(1.0, occlusion, u_SurfaceProperties.y);
    float emissiveVisibility = 1.0;
    if (Input.EmissiveLightThreshold >= 0.0) {
        emissiveVisibility = 1.0 - smoothstep(
            Input.EmissiveLightThreshold,
            Input.EmissiveLightThreshold + 0.16,
            normalLight
        );
    }
    #ifdef ADA_SHADER_GRAPH
    vec3 emissive = surface.emission * emissiveVisibility;
    #else
    vec3 emissive = srgbToLinear(texture(
        sampler2D(u_EmissiveTexture, u_EmissiveSampler),
        materialUV(u_Emission.x, 4)
    ).rgb) * u_EmissiveFactor.rgb * Input.EmissiveStrength * emissiveVisibility;
    #endif

    color = vec4(directLighting + ambient + emissive, opacity);
    if (u_ShadowAtlas.w > 0.5) {
        vec3 debugColor = u_ShadowAtlas.w < 1.5 ? adaLinearToSrgb(baseColor.rgb)
            : (u_ShadowAtlas.w < 2.5 ? cascadeTint(normalLight) : heatRamp(reachingLightCount() / 8.0));
        color = vec4(debugColor, opacity);
    }
    // Transparent surfaces attenuate the opaque indirect buffer but do not contribute to it.
    indirectLighting = vec4(u_SurfaceProperties.w > 1.5 ? vec3(0.0) : ambient, opacity);
    normalRoughness = vec4(normal, roughness);
    viewPositionMetallic = vec4(Input.ViewPosition, metallic);
}
