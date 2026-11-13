import ada_engine::view::view;
import ada_engine::tonemapping::adaLinearToSrgb;
import ada_engine::shadow_pcf::{adaDirectionalShadowPCF, adaDirectionalShadowPCSS, adaNearestShadowDepth};
import ada_engine::baked_diffuse::adaBakedDiffuse;
import ada_engine::distance_field::{adaDistanceFieldVisibility, distanceField};
@if(ADA_MORPH) import ada_engine::morph::applyMorph;

// WESL port of flat3d.glsl. Retained resources keep their original binding slots.
//
// Differences from the GLSL that the port requires:
//  * Derivatives are taken once, at the top of the fragment stage, in uniform control flow. Texture reads inside
//    data-dependent branches use explicit gradients (transformed by the texture's UV transform) instead of implicit ones.
//  * `inverse`, `mod`, `out` parameters and mutable globals are expressed with helper functions, structs and `var<private>`.
//  * Shader Graph materials (ADA_SHADER_GRAPH) receive the generated graph source at the marker below.

// ADA_GRAPH_SOURCE_MARKER

struct DirectionalLight3DUniform {
    u_LightDirectionIntensity: vec4f,
    u_LightRadianceAmbient: vec4f,
    u_ShadowViewProjection: mat4x4f,
    u_ShadowParameters: vec4f,
    u_ShadowViewProjection1: mat4x4f,
    u_ShadowViewProjection2: mat4x4f,
    u_CascadeSplits: vec4f,
    u_ShadowAtlas: vec4f,
}

struct Skinning3DUniform {
    u_JointMatrices: array<mat4x4f, 256>,
}

struct PBR3DUniform {
    u_EmissiveFactor: vec4f,
    u_SurfaceProperties: vec4f,
    u_SurfaceFlags: vec4f,
    u_UVSets: vec4f,
    u_Emission: vec4f,
    u_Parallax: vec4f,
    // Per texture slot (base color, metallic/roughness, normal, occlusion, emission): xyzw is a row-major 2x2
    // matrix, then xy is the offset (glTF KHR_texture_transform).
    u_TextureTransforms: array<vec4f, 10>,
    u_Dielectric: vec4f,
    u_Coat: vec4f,
    u_Sheen: vec4f,
    u_Anisotropy: vec4f,
    u_LayerSets: array<vec4f, 2>,
    u_LayerTransforms: array<vec4f, 16>,
    u_LayerParameters: vec4f,
    u_LightmapScaleOffset: vec4f,
    u_BakedParameters: vec4f,
}

struct IBL3DUniform {
    u_EnvironmentInverseView: mat4x4f,
    u_IBLParameters: vec4f,
    u_ProbePosition: vec4f,
    u_ProbeMinimum: vec4f,
    u_ProbeMaximum: vec4f,
}

struct LocalLight3D {
    positionRange: vec4f,
    radianceIntensity: vec4f,
    directionOuter: vec4f,
    innerShadow: vec4f,
}

struct LocalLighting3DUniform {
    u_LightCounts: vec4f,
    u_AdditionalDirections: array<vec4f, 3>,
    u_AdditionalRadiance: array<vec4f, 3>,
    u_LocalLights: array<LocalLight3D, 32>,
}

struct LocalShadow3DUniform {
    u_LocalShadowMatrices: array<mat4x4f, 24>,
    u_LocalAtlas: vec4f,
}

struct LightTiles3DUniform {
    u_TileProjection: mat4x4f,
    u_TileViewport: vec4f, // xy pixel origin, zw pixel size of the viewport the projection maps to
    u_TileInfo: vec4f,     // x tile size in pixels, y columns, z rows, w 1 when tile masks are valid
}

struct LightTileMasks3DUniform {
    u_TileMasks: array<vec4u, 1024>,
}

struct SurfaceLighting3DUniform {
    u_ContactProjection: mat4x4f,
    u_ContactInverseProjection: mat4x4f,
    u_Contact: vec4f,        // enabled, ray length, thickness, bias (view-space meters)
    u_ContactQuality: vec4f, // steps, max distance, primary light casts shadows
    u_ShadowFilter: vec4f,   // PCSS, tan angular radius, max filter radius, blocker search radius
}

@group(0) @binding(1) var<uniform> directional: DirectionalLight3DUniform;
@group(0) @binding(14) var<uniform> skinning: Skinning3DUniform;
@group(0) @binding(15) var<uniform> pbr: PBR3DUniform;
@group(0) @binding(22) var<uniform> ibl: IBL3DUniform;
@group(0) @binding(25) var<uniform> localLighting: LocalLighting3DUniform;
@group(0) @binding(28) var<uniform> localShadow: LocalShadow3DUniform;
@group(0) @binding(27) var<uniform> lightTiles: LightTiles3DUniform;
@group(0) @binding(29) var<uniform> lightTileMasks: LightTileMasks3DUniform;
@group(0) @binding(23) var<uniform> surfaceLighting: SurfaceLighting3DUniform;

@if(ADA_TERRAIN) @group(0) @binding(4) var u_TerrainAlbedo: texture_2d_array<f32>;
@if(!ADA_TERRAIN) @group(0) @binding(4) var u_BaseColorTexture: texture_2d<f32>;
@group(0) @binding(5) var u_MetallicRoughnessTexture: texture_2d<f32>;
@group(0) @binding(6) var u_NormalTexture: texture_2d<f32>;
@group(0) @binding(7) var u_BaseColorSampler: sampler;
@group(0) @binding(8) var u_MetallicRoughnessSampler: sampler;
@group(0) @binding(9) var u_NormalSampler: sampler;
@group(0) @binding(10) var u_DirectionalShadowTexture: texture_2d<f32>;
@if(ADA_TERRAIN) @group(0) @binding(12) var u_TerrainNormal: texture_2d_array<f32>;
@if(!ADA_TERRAIN) @group(0) @binding(12) var u_EmissiveTexture: texture_2d<f32>;
@group(0) @binding(13) var u_EmissiveSampler: sampler;
@if(ADA_TERRAIN) @group(0) @binding(16) var u_TerrainORM: texture_2d_array<f32>;
@if(!ADA_TERRAIN) @group(0) @binding(16) var u_OcclusionTexture: texture_2d<f32>;
@group(0) @binding(17) var u_HeightTexture: texture_2d<f32>;
@group(0) @binding(0) var u_OcclusionSampler: sampler;
@group(0) @binding(18) var u_Irradiance: texture_2d<f32>;
@group(0) @binding(19) var u_PrefilteredEnvironment: texture_2d<f32>;
@group(0) @binding(20) var u_BRDF: texture_2d<f32>;
@group(0) @binding(3) var u_IBLSampler: sampler;
@group(0) @binding(26) var u_LocalShadowTexture: texture_2d<f32>;
@group(0) @binding(41) var u_ContactSceneDepth: texture_2d<f32>;

// Layer textures exist only in the shader variants of materials that have them. They are read with the base color
// sampler, because the main pass has no free sampler slot.
@if(ADA_CLEARCOAT_TEXTURE) @group(0) @binding(32) var u_ClearcoatTexture: texture_2d<f32>;
@if(ADA_CLEARCOAT_ROUGHNESS_TEXTURE) @group(0) @binding(33) var u_ClearcoatRoughnessTexture: texture_2d<f32>;
@if(ADA_CLEARCOAT_NORMAL_TEXTURE) @group(0) @binding(34) var u_ClearcoatNormalTexture: texture_2d<f32>;
@if(ADA_SHEEN_COLOR_TEXTURE) @group(0) @binding(35) var u_SheenColorTexture: texture_2d<f32>;
@if(ADA_SHEEN_ROUGHNESS_TEXTURE) @group(0) @binding(36) var u_SheenRoughnessTexture: texture_2d<f32>;
@if(ADA_ANISOTROPY_TEXTURE) @group(0) @binding(37) var u_AnisotropyTexture: texture_2d<f32>;
@if(ADA_SPECULAR_TEXTURE) @group(0) @binding(38) var u_SpecularTexture: texture_2d<f32>;
@if(ADA_SPECULAR_COLOR_TEXTURE) @group(0) @binding(39) var u_SpecularColorTexture: texture_2d<f32>;

struct Flat3DVertex {
    @builtin(position) position: vec4f,
    @location(0) color: vec4f,
    @location(1) viewPosition: vec3f,
    @location(2) worldPosition: vec3f,
    @location(3) viewNormal: vec3f,
    @location(4) viewTangent: vec4f,
    @location(5) textureCoordinate: vec2f,
    @location(6) textureCoordinate1: vec2f,
    @location(7) textureFlags: vec4f,
    @location(8) shadowFlags: vec4f,
    // Roughness, metallic, emissive strength, and emissive light threshold share one interpolator.
    @location(9) material: vec4f,
    @location(10) @interpolate(flat) modelOrientation: f32,
}

// ---------------------------------------------------------------------------------------------------------------------
// Vertex stage
// ---------------------------------------------------------------------------------------------------------------------

fn skinTransform(jointIndices: vec4f, jointWeights: vec4f, shadowFlags: vec4f) -> mat4x4f {
    let jointBase = i32(max(0.0, -shadowFlags.y));
    if jointIndices.x < 0.0 {
        return mat4x4f(vec4f(1.0, 0.0, 0.0, 0.0), vec4f(0.0, 1.0, 0.0, 0.0), vec4f(0.0, 0.0, 1.0, 0.0), vec4f(0.0, 0.0, 0.0, 1.0));
    }
    return skinning.u_JointMatrices[jointBase + i32(jointIndices.x)] * jointWeights.x
        + skinning.u_JointMatrices[jointBase + i32(jointIndices.y)] * jointWeights.y
        + skinning.u_JointMatrices[jointBase + i32(jointIndices.z)] * jointWeights.z
        + skinning.u_JointMatrices[jointBase + i32(jointIndices.w)] * jointWeights.w;
}

fn upperLeft(m: mat4x4f) -> mat3x3f {
    return mat3x3f(m[0].xyz, m[1].xyz, m[2].xyz);
}

// WGSL has no inverse(). For a 3x3 matrix with columns c0, c1, c2 the inverse transpose has columns
// (c1 x c2, c2 x c0, c0 x c1) / det.
fn inverseTranspose3(m: mat3x3f) -> mat3x3f {
    let determinantValue = determinant(m);
    return mat3x3f(cross(m[1], m[2]), cross(m[2], m[0]), cross(m[0], m[1])) * (1.0 / determinantValue);
}

fn inverse3(m: mat3x3f) -> mat3x3f {
    return transpose(inverseTranspose3(m));
}

@vertex
fn flat3d_vertex(
    @builtin(vertex_index) vertexIndex: u32,
    @location(0) aPosition: vec3f,
    @location(1) aNormal: vec3f,
    @location(2) aTextureCoordinate: vec2f,
    @location(3) aVertexColor: vec4f,
    @location(4) aTangent: vec4f,
    @location(5) aModel0: vec4f,
    @location(6) aModel1: vec4f,
    @location(7) aModel2: vec4f,
    @location(8) aModel3: vec4f,
    @location(9) aColor: vec4f,
    @location(10) aMaterial: vec4f,
    @location(11) aTextureFlags: vec4f,
    @location(12) aShadowFlags: vec4f,
    @location(13) aJointIndices: vec4f,
    @location(14) aJointWeights: vec4f,
    @location(15) aTextureCoordinate1: vec2f
) -> Flat3DVertex {
    // Morph targets move the rest pose first; skinning then moves the morphed pose.
    var localPosition = aPosition;
    var localNormal = aNormal;
    var localTangent = aTangent.xyz;
    @if(ADA_MORPH) {
        let morphed = applyMorph(vertexIndex, localPosition, localNormal, localTangent);
        localPosition = morphed.position;
        localNormal = morphed.normal;
        localTangent = morphed.tangent;
    }
    let model = mat4x4f(aModel0, aModel1, aModel2, aModel3) * skinTransform(aJointIndices, aJointWeights, aShadowFlags);
    let basis = upperLeft(model);
    let basisDeterminant = determinant(basis);
    let orientation = select(1.0, -1.0, basisDeterminant < 0.0);
    var normalMatrix = mat3x3f(vec3f(1.0, 0.0, 0.0), vec3f(0.0, 1.0, 0.0), vec3f(0.0, 0.0, 1.0));
    if abs(basisDeterminant) > 0.000001 {
        normalMatrix = inverseTranspose3(basis);
    }
    let normal = normalize(normalMatrix * localNormal);
    let worldPosition = model * vec4f(localPosition, 1.0);
    let worldTangent = normalize(basis * localTangent);
    let viewBasis = upperLeft(view.viewMatrix);

    var out: Flat3DVertex;
    out.color = aColor * aVertexColor;
    out.worldPosition = worldPosition.xyz;
    out.viewPosition = (view.viewMatrix * worldPosition).xyz;
    out.viewNormal = normalize(viewBasis * normal);
    @if(ADA_TERRAIN) {
        // Reuse the terrain-unused tangent slot to stay below WebGPU's inter-stage variable limit.
        // X/Z already travel in TextureCoordinate; this packs the local normal and local height.
        out.viewTangent = vec4f(localNormal, localPosition.y);
    }
    @if(!ADA_TERRAIN) {
        out.viewTangent = vec4f(normalize(viewBasis * worldTangent), aTangent.w * orientation);
    }
    out.textureCoordinate = aTextureCoordinate;
    out.textureCoordinate1 = aTextureCoordinate1;
    out.textureFlags = aTextureFlags;
    out.shadowFlags = vec4f(aShadowFlags.x, max(0.0, aShadowFlags.y), aShadowFlags.z, aShadowFlags.w);
    out.material = vec4f(clamp(aMaterial.x, 0.04, 1.0), clamp(aMaterial.y, 0.0, 1.0), max(aMaterial.z, 0.0), aMaterial.w);
    out.modelOrientation = orientation;
    out.position = view.viewProjection * worldPosition;
    @if(ADA_WIREFRAME) {
        // WebGPU disallows pipeline depth bias on lines. Offset along view depth by a bounded scene distance,
        // then keep the original screen position. A fixed NDC offset can pull distant hidden edges through their occluder.
        let depthOffset = min(0.002, abs(out.viewPosition.z) * 0.01);
        let nearer = out.position.zw - sign(out.viewPosition.z) * depthOffset * view.projection[2].zw;
        if nearer.y > 0.0 && nearer.x >= 0.0 {
            out.position.z = min(out.position.z, out.position.w * (nearer.x / nearer.y));
        }
    }
    return out;
}

// ---------------------------------------------------------------------------------------------------------------------
// Fragment stage
// ---------------------------------------------------------------------------------------------------------------------

struct Flat3DOutput {
    @location(0) color: vec4f,
    @location(1) normalRoughness: vec4f,
    @location(2) viewPositionMetallic: vec4f,
    @location(3) indirectLighting: vec4f,
    @if(ADA_HYBRID_REFLECTION) @location(4) reflectionResponse: vec4f,
    @if(ADA_DIFFUSE_SURFACE && ADA_HYBRID_REFLECTION) @location(5) diffuseSurface: vec4f,
    @if(ADA_DIFFUSE_SURFACE && !ADA_HYBRID_REFLECTION) @location(4) diffuseSurface: vec4f,
    @builtin(frag_depth) depth: f32,
}

const PI: f32 = 3.14159265359;
const SHEEN_ALBEDO: f32 = 0.4;

// Per-fragment state. The GLSL kept these as globals; WGSL private variables are initialized per invocation.
var<private> Input: Flat3DVertex;
var<private> g_FrontFacing: bool;
var<private> g_PositionDx: vec3f;
var<private> g_PositionDy: vec3f;
var<private> g_UVDx: vec2f;
var<private> g_UVDy: vec2f;
var<private> g_UV1Dx: vec2f;
var<private> g_UV1Dy: vec2f;
// Clearcoat layer: x strength, y roughness. It sits on the geometric normal, not on the normal map.
var<private> g_Clearcoat: vec2f = vec2f(0.0);
var<private> g_CoatNormal: vec3f = vec3f(0.0, 0.0, 1.0);
// Reflectance of non-metals at normal incidence for this fragment: the material value times its specular textures.
var<private> g_Dielectric: vec3f = vec3f(0.04);
var<private> g_ReflectionResponse: vec3f = vec3f(0.0);
// Sheen layer (cloth): rgb color, w roughness. A black color turns it off.
var<private> g_Sheen: vec4f = vec4f(0.0);
// Anisotropy: strength, and the view-space tangent and bitangent of the stretched highlight.
var<private> g_Anisotropy: f32 = 0.0;
var<private> g_AnisotropyT: vec3f = vec3f(1.0, 0.0, 0.0);
var<private> g_AnisotropyB: vec3f = vec3f(0.0, 1.0, 0.0);
// UV shift from parallax occlusion mapping, applied to every material texture that uses the height map's UV set.
var<private> g_ParallaxDelta: vec2f = vec2f(0.0);

fn surfaceFrontFacing() -> bool {
    // Reflection reverses raster winding, while inverse-transpose normals still face physically outward.
    return select(g_FrontFacing, !g_FrontFacing, Input.modelOrientation < 0.0);
}

fn hasClearcoat() -> bool {
    @if(ADA_CLEARCOAT) {
        return g_Clearcoat.x > 0.0;
    }
    return false;
}

fn hasSheen() -> bool {
    @if(ADA_SHEEN) {
        return max(g_Sheen.r, max(g_Sheen.g, g_Sheen.b)) > 0.0;
    }
    return false;
}

fn hasAnisotropy() -> bool {
    @if(ADA_ANISOTROPY) {
        return g_Anisotropy > 0.0;
    }
    return false;
}

// Share of the base layer's light that survives the coat at this view angle.
fn coatTransmission(normalView: f32) -> f32 {
    return 1.0 - g_Clearcoat.x * fresnelSchlick(normalView, vec3f(0.04)).x;
}

// Share of the base layer's light that survives the sheen.
fn sheenTransmission() -> f32 {
    return 1.0 - max(g_Sheen.r, max(g_Sheen.g, g_Sheen.b)) * SHEEN_ALBEDO;
}

// A texture coordinate with the gradients a sample needs, so reads can sit in data-dependent branches.
struct MaterialUV {
    uv: vec2f,
    dx: vec2f,
    dy: vec2f,
}

fn transformedUV(setIndex: f32, matrix: vec4f, offset: vec2f) -> MaterialUV {
    let useSecond = setIndex > 0.5;
    var uv = select(Input.textureCoordinate, Input.textureCoordinate1, useSecond);
    let dx = select(g_UVDx, g_UV1Dx, useSecond);
    let dy = select(g_UVDy, g_UV1Dy, useSecond);
    // The parallax shift lives in mesh UV space, so it applies before the texture's own transform.
    if abs(setIndex - pbr.u_Parallax.y) < 0.5 {
        uv += g_ParallaxDelta;
    }
    return MaterialUV(
        vec2f(dot(matrix.xy, uv), dot(matrix.zw, uv)) + offset,
        vec2f(dot(matrix.xy, dx), dot(matrix.zw, dx)),
        vec2f(dot(matrix.xy, dy), dot(matrix.zw, dy))
    );
}

fn materialUV(setIndex: f32, slot: i32) -> MaterialUV {
    return transformedUV(setIndex, pbr.u_TextureTransforms[slot * 2], pbr.u_TextureTransforms[slot * 2 + 1].xy);
}

// UV of a layer texture (slot 0 to 7 in PBRLayerTexture order): its UV set, with the parallax shift, then its own transform.
fn layerUV(slot: i32) -> MaterialUV {
    let setIndex = pbr.u_LayerSets[slot >> 2u][slot & 3];
    return transformedUV(setIndex, pbr.u_LayerTransforms[slot * 2], pbr.u_LayerTransforms[slot * 2 + 1].xy);
}

fn sampleMaterial(tex: texture_2d<f32>, samp: sampler, coordinate: MaterialUV) -> vec4f {
    return textureSampleGrad(tex, samp, coordinate.uv, coordinate.dx, coordinate.dy);
}

fn contactVisibility(normal: vec3f, direction: vec3f, lightDistance: f32) -> f32 {
    let contact = surfaceLighting.u_Contact;
    let quality = surfaceLighting.u_ContactQuality;
    if contact.x < 0.5 || Input.shadowFlags.x < 0.5 || Input.viewPosition.z >= quality.y {
        return 1.0;
    }
    let steps = i32(quality.x);
    let reach = min(contact.y, lightDistance);
    let origin = Input.viewPosition + normal * contact.w;
    let size = vec2i(textureDimensions(u_ContactSceneDepth, 0));
    for (var i = 1; i <= 32; i++) {
        if i > steps {
            break;
        }
        let t = (f32(i) - 0.25) / f32(steps);
        let query = origin + direction * (reach * t);
        let clip = surfaceLighting.u_ContactProjection * vec4f(query, 1.0);
        if clip.w <= 0.0 {
            break;
        }
        let uv = clip.xy / clip.w * vec2f(0.5, -0.5) + vec2f(0.5);
        if any(uv <= vec2f(0.0)) || any(uv >= vec2f(1.0)) {
            break;
        }
        let depth = textureLoad(u_ContactSceneDepth, vec2i(uv * vec2f(size)), 0).r;
        if depth >= 1.0 {
            continue;
        }
        let surface = surfaceLighting.u_ContactInverseProjection * vec4f(uv * vec2f(2.0, -2.0) + vec2f(-1.0, 1.0), depth, 1.0);
        let gap = query.z - surface.z / surface.w;
        if gap > contact.w && gap < contact.z {
            let fade = 1.0 - smoothstep(quality.y * 0.8, quality.y, Input.viewPosition.z);
            return 1.0 - fade;
        }
    }
    return 1.0;
}

// Bit mask of the local lights that may reach this fragment. The tile comes from projecting the view-space
// position the same way the CPU bounded each light, so it holds for any backend's fragment coordinate origin.
fn localLightMask() -> u32 {
    let lightCount = i32(localLighting.u_LightCounts.y);
    let reachable = select((1u << u32(max(lightCount, 0))) - 1u, 0xFFFFFFFFu, lightCount >= 32);
    let info = lightTiles.u_TileInfo;
    if info.w < 0.5 {
        return reachable;
    }
    let clip = lightTiles.u_TileProjection * vec4f(Input.viewPosition, 1.0);
    if clip.w <= 0.0001 {
        return reachable;
    }
    let viewport = lightTiles.u_TileViewport;
    let pixel = viewport.xy + vec2f(clip.x / clip.w * 0.5 + 0.5, 0.5 - clip.y / clip.w * 0.5) * viewport.zw;
    let tile = clamp(vec2i(floor(pixel / info.x)), vec2i(0), vec2i(i32(info.y) - 1, i32(info.z) - 1));
    let index = tile.y * i32(info.y) + tile.x;
    return lightTileMasks.u_TileMasks[index >> 2u][index & 3] & reachable;
}

fn srgbToLinear(value: vec3f) -> vec3f {
    return mix(value / 12.92, pow((value + vec3f(0.055)) / 1.055, vec3f(2.4)), step(vec3f(0.04045), value));
}

fn distributionGGX(normal: vec3f, halfway: vec3f, roughness: f32) -> f32 {
    let alpha = roughness * roughness;
    let alphaSquared = alpha * alpha;
    let normalHalfway = max(dot(normal, halfway), 0.0);
    let denominator = normalHalfway * normalHalfway * (alphaSquared - 1.0) + 1.0;
    return alphaSquared / max(PI * denominator * denominator, 0.000001);
}

fn geometrySchlickGGX(normalDirection: f32, roughness: f32) -> f32 {
    let radius = roughness + 1.0;
    let k = radius * radius / 8.0;
    return normalDirection / max(normalDirection * (1.0 - k) + k, 0.000001);
}

fn geometrySmith(normal: vec3f, viewDirection: vec3f, lightDirection: vec3f, roughness: f32) -> f32 {
    return geometrySchlickGGX(max(dot(normal, viewDirection), 0.0), roughness)
        * geometrySchlickGGX(max(dot(normal, lightDirection), 0.0), roughness);
}

fn fresnelSchlick(cosine: f32, reflectanceAtNormal: vec3f) -> vec3f {
    return reflectanceAtNormal + (vec3f(1.0) - reflectanceAtNormal) * pow(clamp(1.0 - cosine, 0.0, 1.0), 5.0);
}

// Ray-marches the height map along the view ray. Returns the UV shift that makes the surface appear to have depth.
// Depth is measured in view units and converted to UV through the screen-space position/UV derivatives, so no
// tangent frame is needed.
fn parallaxDelta() -> vec2f {
    let parallax = pbr.u_Parallax;
    var normal = normalize(Input.viewNormal);
    let viewDirection = normalize(-Input.viewPosition);
    var facing = dot(normal, viewDirection);
    if facing < 0.0 {
        normal = -normal;
        facing = -facing;
    }
    let fadeDistance = parallax.w;
    let scale = parallax.x * (1.0 - smoothstep(fadeDistance * 0.5, fadeDistance, length(Input.viewPosition)));
    let useSecond = parallax.y > 0.5;
    let uv = select(Input.textureCoordinate, Input.textureCoordinate1, useSecond);
    let gradientX = select(g_UVDx, g_UV1Dx, useSecond);
    let gradientY = select(g_UVDy, g_UV1Dy, useSecond);
    let positionX = g_PositionDx;
    let positionY = g_PositionDy;
    let xx = dot(positionX, positionX);
    let xy = dot(positionX, positionY);
    let yy = dot(positionY, positionY);
    let determinantValue = xx * yy - xy * xy;
    if scale <= 0.0 || abs(determinantValue) < 1e-12 {
        return vec2f(0.0);
    }

    let shift = -(viewDirection - normal * facing) / max(facing, 0.08);
    let projected = vec2f(dot(shift, positionX), dot(shift, positionY));
    let coefficients = vec2f(yy * projected.x - xy * projected.y, xx * projected.y - xy * projected.x) / determinantValue;
    let uvPerDepth = (gradientX * coefficients.x + gradientY * coefficients.y) * scale;

    let maximumLayers = parallax.z;
    let layers = mix(maximumLayers, max(maximumLayers * 0.25, 4.0), clamp(facing, 0.0, 1.0));
    var previousDepth = 0.0;
    var previousGap = -(1.0 - textureSampleGrad(u_HeightTexture, u_BaseColorSampler, uv, gradientX, gradientY).r);
    var hitDepth = 1.0;
    for (var i = 1; i <= 64; i++) {
        if f32(i) > layers {
            break;
        }
        let depth = f32(i) / layers;
        let height = textureSampleGrad(u_HeightTexture, u_BaseColorSampler, uv + uvPerDepth * depth, gradientX, gradientY).r;
        let gap = depth - (1.0 - height);
        if gap >= 0.0 {
            hitDepth = mix(previousDepth, depth, previousGap / (previousGap - gap));
            break;
        }
        previousDepth = depth;
        previousGap = gap;
    }
    return uvPerDepth * hitDepth;
}

fn environmentUV(direction: vec3f) -> vec2f {
    let angle = ibl.u_IBLParameters.w;
    let rotated = mat2x2f(cos(angle), -sin(angle), sin(angle), cos(angle)) * direction.xz;
    return vec2f(atan2(rotated.y, rotated.x) / (2.0 * PI) + 0.5, asin(clamp(direction.y, -1.0, 1.0)) / PI + 0.5);
}

// A capture contains static geometry even when it lies behind the camera. Correct its finite-distance parallax.
fn probeDirection(position: vec3f, direction: vec3f) -> vec3f {
    if ibl.u_ProbePosition.w < 0.5 || any(position < ibl.u_ProbeMinimum.xyz) || any(position > ibl.u_ProbeMaximum.xyz) {
        return direction;
    }
    let nearZero = abs(direction) < vec3f(0.000001);
    let safeDirection = select(direction, vec3f(0.000001), nearZero);
    let boundary = select(ibl.u_ProbeMinimum.xyz, ibl.u_ProbeMaximum.xyz, direction >= vec3f(0.0));
    var travel = (boundary - position) / safeDirection;
    travel = select(travel, vec3f(1e20), nearZero);
    let projected = position + direction * min(travel.x, min(travel.y, travel.z)) - ibl.u_ProbePosition.xyz;
    return select(direction, normalize(projected), dot(projected, projected) > 0.000001);
}

fn samplePrefiltered(inputDirection: vec3f, roughness: f32) -> vec3f {
    let direction = probeDirection(Input.worldPosition, inputDirection);
    var uv = environmentUV(direction);
    let levels = max(ibl.u_IBLParameters.z, 2.0);
    let layer = roughness * (levels - 1.0);
    let lower = floor(layer);
    let upper = min(lower + 1.0, levels - 1.0);
    let texels = f32(textureDimensions(u_PrefilteredEnvironment, 0).y) / levels;
    uv.y = clamp(uv.y, 0.5 / texels, 1.0 - 0.5 / texels);
    let left = textureSampleLevel(u_PrefilteredEnvironment, u_IBLSampler, vec2f(uv.x, (lower + uv.y) / levels), 0.0).rgb;
    let right = textureSampleLevel(u_PrefilteredEnvironment, u_IBLSampler, vec2f(uv.x, (upper + uv.y) / levels), 0.0).rgb;
    return mix(left, right, layer - lower);
}

struct EnvironmentResult {
    color: vec3f,
    bakedPart: vec3f,
}

fn environmentLighting(
    normal: vec3f, viewDirection: vec3f, baseColor: vec3f, metallic: f32, roughness: f32, baked: vec4f
) -> EnvironmentResult {
    var bakedPart = vec3f(0.0);
    let inverseView = upperLeft(ibl.u_EnvironmentInverseView);
    let worldNormal = normalize(inverseView * normal);
    let worldView = normalize(inverseView * viewDirection);
    let ndotv = max(dot(normal, viewDirection), 0.0);
    let f0 = mix(g_Dielectric, baseColor, metallic);
    let fresnel = f0 + (max(vec3f(1.0 - roughness), f0) - f0) * pow(1.0 - ndotv, 5.0);
    let diffuseWeight = (vec3f(1.0) - fresnel) * (1.0 - metallic);
    let irradiance = textureSampleLevel(u_Irradiance, u_IBLSampler, environmentUV(worldNormal), 0.0).rgb;
    var reflectionNormal = worldNormal;
    if hasAnisotropy() {
        // Bend the reflection toward the stretched direction so the environment smears along it (Filament).
        let anisotropicTangent = cross(g_AnisotropyB, viewDirection);
        let anisotropicNormal = cross(anisotropicTangent, g_AnisotropyB);
        let bend = g_Anisotropy * clamp(5.0 * roughness, 0.0, 1.0);
        reflectionNormal = normalize(inverseView * normalize(mix(normal, anisotropicNormal, bend)));
    }
    let reflected = samplePrefiltered(reflect(-worldView, reflectionNormal), roughness);
    let lutSize = vec2f(textureDimensions(u_BRDF, 0));
    let lutUV = clamp(vec2f(ndotv, roughness), vec2f(0.5) / lutSize, vec2f(1.0) - vec2f(0.5) / lutSize);
    let lut = textureSampleLevel(u_BRDF, u_IBLSampler, lutUV, 0.0).rg;
    // Preserve the exact colored material response, including AO and transmission applied below. Anisotropy
    // uses a different ray direction, so its base lobe stays on the correctly integrated probe in this first slice.
    g_ReflectionResponse = select(f0 * lut.x + vec3f(lut.y), vec3f(0.0), hasAnisotropy());
    let iblIntensity = ibl.u_IBLParameters.y;
    var result = (diffuseWeight * irradiance * baseColor / PI + reflected * (f0 * lut.x + vec3f(lut.y))) * iblIntensity;
    var incident = vec3f(0.0);
    @if(ADA_LIGHTMAP || ADA_IRRADIANCE_GRID) {
        incident = mix(irradiance / PI * iblIntensity, baked.rgb, baked.a);
        result = diffuseWeight * incident * baseColor + reflected * (f0 * lut.x + vec3f(lut.y)) * iblIntensity;
        bakedPart = diffuseWeight * baseColor * baked.rgb * baked.a;
    }
    if hasSheen() {
        g_ReflectionResponse *= sheenTransmission();
        // Sheen under image-based lighting is approximated as a diffuse lobe with the average sheen albedo.
        result = result * sheenTransmission() + g_Sheen.rgb * SHEEN_ALBEDO * irradiance / PI * iblIntensity;
        @if(ADA_LIGHTMAP || ADA_IRRADIANCE_GRID) {
            result += g_Sheen.rgb * SHEEN_ALBEDO * (incident - irradiance / PI * iblIntensity);
            bakedPart = bakedPart * sheenTransmission() + g_Sheen.rgb * SHEEN_ALBEDO * baked.rgb * baked.a;
        }
    }
    if hasClearcoat() {
        g_ReflectionResponse *= coatTransmission(max(dot(g_CoatNormal, viewDirection), 0.0));
        // The coat reflects the environment along the geometric normal and dims the base layer beneath it.
        let coatWorldNormal = normalize(inverseView * g_CoatNormal);
        let coatNormalView = max(dot(g_CoatNormal, viewDirection), 0.0);
        let coatLutUV = clamp(vec2f(coatNormalView, g_Clearcoat.y), vec2f(0.5) / lutSize, vec2f(1.0) - vec2f(0.5) / lutSize);
        let coatLut = textureSampleLevel(u_BRDF, u_IBLSampler, coatLutUV, 0.0).rg;
        let coatReflected = samplePrefiltered(reflect(-worldView, coatWorldNormal), g_Clearcoat.y);
        result = result * coatTransmission(coatNormalView)
            + coatReflected * (0.04 * coatLut.x + coatLut.y) * g_Clearcoat.x * iblIntensity;
        bakedPart *= coatTransmission(coatNormalView);
    }
    return EnvironmentResult(result, bakedPart);
}

fn cotangentFrame(normal: vec3f, uvX: vec2f, uvY: vec2f) -> mat3x3f {
    let positionYPerpendicular = cross(g_PositionDy, normal);
    let positionXPerpendicular = cross(normal, g_PositionDx);
    let tangent = positionYPerpendicular * uvX.x + positionXPerpendicular * uvY.x;
    let bitangent = positionYPerpendicular * uvX.y + positionXPerpendicular * uvY.y;
    let scale = inverseSqrt(max(max(dot(tangent, tangent), dot(bitangent, bitangent)), 0.000001));
    return mat3x3f(tangent * scale, bitangent * scale, normal);
}

fn materialNormal() -> vec3f {
    let normal = normalize(Input.viewNormal);
    if Input.textureFlags.z < 0.5 {
        return normal;
    }

    let coordinate = materialUV(pbr.u_UVSets.z, 2);
    var tangentNormal = sampleMaterial(u_NormalTexture, u_NormalSampler, coordinate).xyz * 2.0 - vec3f(1.0);
    tangentNormal = vec3f(tangentNormal.xy * pbr.u_SurfaceProperties.x, tangentNormal.z);
    // Authored tangents follow the mesh UVs, so they only hold while the normal map's transform keeps its axes.
    let normalMatrix = pbr.u_TextureTransforms[4];
    let keepsTangents = abs(normalMatrix.y) < 0.0001 && abs(normalMatrix.z) < 0.0001 && normalMatrix.x > 0.0 && normalMatrix.w > 0.0;
    if Input.textureFlags.w > 0.5 && pbr.u_UVSets.z < 0.5 && keepsTangents {
        let tangent = normalize(Input.viewTangent.xyz - normal * dot(normal, Input.viewTangent.xyz));
        let bitangent = normalize(cross(normal, tangent)) * Input.viewTangent.w;
        return normalize(mat3x3f(tangent, bitangent, normal) * tangentNormal);
    }

    return normalize(cotangentFrame(normal, coordinate.dx, coordinate.dy) * tangentNormal);
}

fn cascadeVisibility(cascade: i32, normal: vec3f, lightDirection: vec3f) -> f32 {
    var shadowMatrix = directional.u_ShadowViewProjection;
    if cascade == 1 {
        shadowMatrix = directional.u_ShadowViewProjection1;
    } else if cascade > 1 {
        shadowMatrix = directional.u_ShadowViewProjection2;
    }
    let position = shadowMatrix * vec4f(Input.worldPosition, 1.0);
    let projected = position.xyz / position.w;
    let localUV = projected.xy * vec2f(0.5, -0.5) + vec2f(0.5);
    if projected.z < 0.0 || projected.z > 1.0 || any(localUV < vec2f(0.0)) || any(localUV > vec2f(1.0)) {
        return 1.0;
    }
    let atlas = directional.u_ShadowAtlas;
    let count = max(directional.u_CascadeSplits.w, 1.0);
    let uv = vec2f((localUV.x + f32(cascade)) / count, localUV.y);
    let minimum = vec2f(f32(cascade) / count, 0.0) + atlas.xy * 0.5;
    let maximum = vec2f(f32(cascade + 1) / count, 1.0) - atlas.xy * 0.5;
    let bias = directional.u_ShadowParameters.y + directional.u_ShadowParameters.z * (1.0 - max(dot(normal, lightDirection), 0.0));
    if surfaceLighting.u_ShadowFilter.x > 0.5 {
        return adaDirectionalShadowPCSS(
            u_DirectionalShadowTexture,
            uv, atlas.xy, minimum, maximum, projected.z - bias, shadowMatrix, surfaceLighting.u_ShadowFilter, count
        );
    }
    return adaDirectionalShadowPCF(
        u_DirectionalShadowTexture, uv, atlas.xy, minimum, maximum, projected.z - bias
    );
}

fn directionalShadow(normal: vec3f, lightDirection: vec3f) -> f32 {
    let splits = directional.u_CascadeSplits;
    if Input.shadowFlags.x < 0.5 || directional.u_ShadowParameters.x < 0.5 {
        return 1.0;
    }
    let depth = Input.viewPosition.z;
    if depth > splits.z {
        return 1.0;
    }
    let count = i32(splits.w);
    var cascade = select(select(2, 1, depth <= splits.y), 0, depth <= splits.x);
    cascade = min(cascade, count - 1);
    var visibility = cascadeVisibility(cascade, normal, lightDirection);
    if cascade < count - 1 {
        let edge = select(splits.y, splits.x, cascade == 0);
        let start = select(splits.x, 0.0, cascade == 0);
        let width = (edge - start) * directional.u_ShadowAtlas.z;
        if width > 0.0 && depth > edge - width {
            let next = cascadeVisibility(cascade + 1, normal, lightDirection);
            visibility = mix(visibility, next, smoothstep(edge - width, edge, depth));
        }
    }
    return visibility;
}

// The coat's own highlight for one light (rgb, already scaled by radiance and n.l) and the transmission of the
// base layer under it (a).
fn clearcoatDirect(viewDirection: vec3f, lightDirection: vec3f, radiance: vec3f) -> vec4f {
    let normal = g_CoatNormal;
    let nl = max(dot(normal, lightDirection), 0.0);
    let nv = max(dot(normal, viewDirection), 0.0);
    let transmission = coatTransmission(nv);
    if nl <= 0.0 || nv <= 0.0 {
        return vec4f(0.0, 0.0, 0.0, transmission);
    }
    let halfway = normalize(viewDirection + lightDirection);
    let fresnel = fresnelSchlick(max(dot(halfway, viewDirection), 0.0), vec3f(0.04)).x * g_Clearcoat.x;
    let distribution = distributionGGX(normal, halfway, g_Clearcoat.y);
    let geometry = geometrySmith(normal, viewDirection, lightDirection, g_Clearcoat.y);
    let specular = distribution * geometry * fresnel / max(4.0 * nv * nl, 0.0001);
    return vec4f(vec3f(specular) * max(radiance, vec3f(0.0)) * nl, transmission);
}

// Charlie sheen distribution (Estevez and Kulla) and the Neubelt visibility term, as in the glTF sheen specification.
fn sheenDistribution(roughness: f32, normalHalfway: f32) -> f32 {
    let alpha = roughness * roughness;
    let inverseAlpha = 1.0 / alpha;
    let sine2 = max(1.0 - normalHalfway * normalHalfway, 0.0078125);
    return (2.0 + inverseAlpha) * pow(sine2, inverseAlpha * 0.5) / (2.0 * PI);
}

fn sheenVisibility(normalLight: f32, normalView: f32) -> f32 {
    return clamp(1.0 / (4.0 * (normalLight + normalView - normalLight * normalView)), 0.0, 1.0);
}

fn evaluateDirect(
    normal: vec3f, viewDirection: vec3f, lightDirection: vec3f, baseColor: vec3f, metallic: f32, roughness: f32, radiance: vec3f
) -> vec3f {
    let nl = max(dot(normal, lightDirection), 0.0);
    let nv = max(dot(normal, viewDirection), 0.0);
    var base = vec3f(0.0);
    if nl > 0.0 && nv > 0.0 {
        let halfway = normalize(viewDirection + lightDirection);
        let f0 = mix(g_Dielectric, baseColor, metallic);
        let fresnel = fresnelSchlick(max(dot(halfway, viewDirection), 0.0), f0);
        var specular: vec3f;
        if hasAnisotropy() {
            // Anisotropic GGX: roughness stretches along the tangent, so the highlight streaks along the bitangent.
            let normalHalfway = max(dot(normal, halfway), 0.0);
            let alpha = roughness * roughness;
            let alphaT = mix(alpha, 1.0, g_Anisotropy * g_Anisotropy);
            let alphaB = alpha;
            let tangentHalfway = dot(g_AnisotropyT, halfway);
            let bitangentHalfway = dot(g_AnisotropyB, halfway);
            let denominator = tangentHalfway * tangentHalfway / (alphaT * alphaT)
                + bitangentHalfway * bitangentHalfway / (alphaB * alphaB) + normalHalfway * normalHalfway;
            let distribution = 1.0 / max(PI * alphaT * alphaB * denominator * denominator, 0.000001);
            let lambdaView = nl * length(vec3f(alphaT * dot(g_AnisotropyT, viewDirection), alphaB * dot(g_AnisotropyB, viewDirection), nv));
            let lambdaLight = nv * length(vec3f(alphaT * dot(g_AnisotropyT, lightDirection), alphaB * dot(g_AnisotropyB, lightDirection), nl));
            specular = fresnel * distribution * 0.5 / max(lambdaView + lambdaLight, 0.00001);
        } else {
            let distribution = distributionGGX(normal, halfway, roughness);
            let geometry = geometrySmith(normal, viewDirection, lightDirection, roughness);
            specular = distribution * geometry * fresnel / max(4.0 * nv * nl, 0.0001);
        }
        base = ((vec3f(1.0) - fresnel) * (1.0 - metallic) * baseColor / PI + specular) * max(radiance, vec3f(0.0)) * nl;
        if hasSheen() {
            let sheen = g_Sheen.rgb * sheenDistribution(g_Sheen.w, max(dot(normal, halfway), 0.0)) * sheenVisibility(nl, nv);
            base = base * sheenTransmission() + sheen * max(radiance, vec3f(0.0)) * nl;
        }
    }
    if !hasClearcoat() {
        return base;
    }
    let coat = clearcoatDirect(viewDirection, lightDirection, radiance);
    return base * coat.a + coat.rgb;
}

fn localPointFace(ray: vec3f) -> i32 {
    let a = abs(ray);
    if a.x >= a.y && a.x >= a.z {
        return select(1, 0, ray.x >= 0.0);
    }
    if a.y >= a.z {
        return select(3, 2, ray.y >= 0.0);
    }
    return select(5, 4, ray.z >= 0.0);
}

fn localShadowVisibility(light: LocalLight3D, lightDirection: vec3f, normal: vec3f) -> f32 {
    let slot = i32(light.innerShadow.w);
    if slot < 0 || slot >= 4 || Input.shadowFlags.x < 0.5 {
        return 1.0;
    }
    // View-space direction to the surface converted back to world-space for cube-face choice.
    let worldRay = upperLeft(ibl.u_EnvironmentInverseView) * (Input.viewPosition - light.positionRange.xyz);
    var face = 0;
    if light.directionOuter.w < 0.0 {
        face = localPointFace(worldRay);
    }
    let clip = localShadow.u_LocalShadowMatrices[slot * 6 + face] * vec4f(Input.worldPosition, 1.0);
    if clip.w <= 0.0 {
        return 1.0;
    }
    let ndc = clip.xyz / clip.w;
    if ndc.z < 0.0 || ndc.z > 1.0 || any(abs(ndc.xy) > vec2f(1.0)) {
        return 1.0;
    }
    let atlas = localShadow.u_LocalAtlas;
    let tileOrigin = vec2f(f32(face), f32(slot)) * atlas.z;
    let texel = atlas.xy;
    let uv = (tileOrigin + (ndc.xy * vec2f(0.5, -0.5) + vec2f(0.5)) * atlas.z) * texel;
    let lo = (tileOrigin + vec2f(0.5)) * texel;
    let hi = (tileOrigin + vec2f(atlas.z - 0.5)) * texel;
    let bias = light.innerShadow.y + light.innerShadow.z * (1.0 - max(dot(normal, lightDirection), 0.0));
    let shadowSize = vec2i(textureDimensions(u_LocalShadowTexture));
    var visibility = 0.0;
    for (var y = -1; y <= 1; y++) {
        for (var x = -1; x <= 1; x++) {
            let stored = adaNearestShadowDepth(u_LocalShadowTexture, shadowSize, clamp(uv + vec2f(f32(x), f32(y)) * texel, lo, hi));
            visibility += select(0.0, 1.0, ndc.z - bias <= stored);
        }
    }
    return visibility / 9.0;
}

fn additionalLighting(normal: vec3f, viewDirection: vec3f, baseColor: vec3f, metallic: f32, roughness: f32) -> vec3f {
    var result = vec3f(0.0);
    for (var i = 0; i < 3; i++) {
        if i >= i32(localLighting.u_LightCounts.x) {
            break;
        }
        result += evaluateDirect(
            normal, viewDirection, normalize(localLighting.u_AdditionalDirections[i].xyz), baseColor, metallic, roughness,
            localLighting.u_AdditionalRadiance[i].rgb * max(localLighting.u_AdditionalDirections[i].w, 0.0)
        );
    }
    var mask = localLightMask();
    for (var n = 0; n < 32; n++) {
        if mask == 0u {
            break;
        }
        let i = i32(firstTrailingBit(mask));
        mask &= mask - 1u;
        let light = localLighting.u_LocalLights[i];
        let delta = light.positionRange.xyz - Input.viewPosition;
        let lightDistance = length(delta);
        let range = light.positionRange.w;
        if lightDistance >= range || range <= 0.0 {
            continue;
        }
        let direction = delta / max(lightDistance, 0.00001);
        let ratio = lightDistance / range;
        let cutoff = max(0.0, 1.0 - ratio * ratio * ratio * ratio);
        var attenuation = cutoff * cutoff / max(lightDistance * lightDistance, 0.01);
        if light.directionOuter.w >= 0.0 {
            let cone = dot(normalize(light.directionOuter.xyz), -direction);
            attenuation *= smoothstep(light.directionOuter.w, light.innerShadow.x, cone);
        }
        if attenuation <= 0.0 {
            continue;
        }
        let contribution = evaluateDirect(
            normal, viewDirection, direction, baseColor, metallic, roughness,
            light.radianceIntensity.rgb * max(light.radianceIntensity.w, 0.0) * attenuation
        );
        // The shadow lookup (nine depth taps) only scales the contribution, so a light that adds nothing here
        // (facing away, or behind the surface) never needs it.
        if max(contribution.r, max(contribution.g, contribution.b)) <= 0.0 {
            continue;
        }
        var contact = 1.0;
        if light.innerShadow.w >= 0.0 {
            contact = contactVisibility(normal, direction, lightDistance);
        }
        result += contribution * localShadowVisibility(light, direction, normal) * contact;
    }
    return result;
}

fn visibilityDither(pixel: vec2f) -> f32 {
    let x = u32(floor(pixel.x)) % 4u;
    let y = u32(floor(pixel.y)) % 4u;
    var values = array<f32, 16>(0.0, 8.0, 2.0, 10.0, 12.0, 4.0, 14.0, 6.0, 3.0, 11.0, 1.0, 9.0, 15.0, 7.0, 13.0, 5.0);
    return (values[y * 4u + x] + 0.5) / 16.0;
}

// Debug visualizations selected by u_ShadowAtlas.w (see DebugView3D.mainPassMode). Mode 0 is normal shading.
fn heatRamp(value: f32) -> vec3f {
    let t = clamp(value, 0.0, 1.0);
    return clamp(vec3f(1.5 - abs(4.0 * t - 3.0), 1.5 - abs(4.0 * t - 2.0), 1.5 - abs(4.0 * t - 1.0)), vec3f(0.0), vec3f(1.0));
}

fn cascadeTint(normalLight: f32) -> vec3f {
    let shade = 0.35 + 0.65 * normalLight;
    let splits = directional.u_CascadeSplits;
    if Input.shadowFlags.x < 0.5 || directional.u_ShadowParameters.x < 0.5 {
        return vec3f(0.5) * shade;
    }
    let depth = Input.viewPosition.z;
    if depth > splits.z {
        return vec3f(0.18) * shade;
    }
    let count = i32(splits.w);
    let cascade = min(select(select(2, 1, depth <= splits.y), 0, depth <= splits.x), count - 1);
    let tint = select(select(vec3f(0.25, 0.4, 0.95), vec3f(0.2, 0.8, 0.3), cascade == 1), vec3f(0.9, 0.2, 0.2), cascade == 0);
    return tint * shade;
}

fn reachingLightCount() -> f32 {
    var count = select(0.0, 1.0, directional.u_LightDirectionIntensity.w > 0.0);
    count += f32(i32(localLighting.u_LightCounts.x));
    for (var i = 0; i < 32; i++) {
        if i >= i32(localLighting.u_LightCounts.y) {
            break;
        }
        let light = localLighting.u_LocalLights[i];
        let delta = light.positionRange.xyz - Input.viewPosition;
        let lightDistance = length(delta);
        let range = light.positionRange.w;
        if lightDistance >= range || range <= 0.0 {
            continue;
        }
        if light.directionOuter.w >= 0.0 {
            let cone = dot(normalize(light.directionOuter.xyz), -delta / max(lightDistance, 0.00001));
            if smoothstep(light.directionOuter.w, light.innerShadow.x, cone) <= 0.0 {
                continue;
            }
        }
        count += 1.0;
    }
    return count;
}

// ---------------------------------------------------------------------------------------------------------------------
// Terrain surface
// ---------------------------------------------------------------------------------------------------------------------

struct TerrainMaterialUniform {
    u_TerrainGrid: vec4f,
    u_TerrainTints: array<vec4f, 32>,
    u_TerrainSurfaces: array<vec4f, 32>,
    u_TerrainVariation: array<vec4f, 32>,
    u_TerrainVariationScale: array<vec4f, 32>,
}

struct TerrainNormalTransform {
    u_TerrainNormalToWorld: mat4x4f,
}

@if(ADA_TERRAIN) @group(0) @binding(51) var<uniform> terrain: TerrainMaterialUniform;
@if(ADA_TERRAIN) @group(0) @binding(52) var<uniform> terrainNormal: TerrainNormalTransform;

struct TerrainTexel {
    albedo: vec4f,
    normal: vec3f,
    orm: vec3f,
    height: f32,
}

@if(ADA_TERRAIN)
fn terrainHash(cell: vec2f, seed: u32) -> u32 {
    // Wrapping before conversion also gives stable nonnegative integer hashes for negative local coordinates.
    let wrapped = cell - vec2f(16777216.0) * floor(cell / vec2f(16777216.0));
    let p = vec2u(wrapped);
    var h = seed ^ (p.x * 0x9e3779b9u) ^ (p.y * 0x85ebca6bu);
    h ^= h >> 16u;
    h *= 0x7feb352du;
    h ^= h >> 15u;
    h *= 0x846ca68bu;
    return h ^ (h >> 16u);
}

@if(ADA_TERRAIN)
fn terrainRead(layer: i32, uv: vec2f, dx: vec2f, dy: vec2f, transform: mat2x2f, offset: vec2f) -> TerrainTexel {
    let q = transform * uv + offset;
    let qx = transform * dx;
    let qy = transform * dy;
    let albedo = textureSampleGrad(u_TerrainAlbedo, u_BaseColorSampler, q, layer, qx, qy);
    var normal = textureSampleGrad(u_TerrainNormal, u_BaseColorSampler, q, layer, qx, qy).xyz * 2.0 - vec3f(1.0);
    // For q=M*uv, tangent-space gradients and normals return through transpose(M), including reflection handedness.
    normal = vec3f(transpose(transform) * normal.xy, normal.z);
    let orm = textureSampleGrad(u_TerrainORM, u_BaseColorSampler, q, layer, qx, qy);
    return TerrainTexel(
        vec4f(srgbToLinear(albedo.rgb), albedo.a), normal, orm.rgb, select(0.5, orm.a, terrain.u_TerrainVariationScale[layer].w > 0.5)
    );
}

@if(ADA_TERRAIN)
fn terrainMacro(coordinate: vec2f, seed: u32) -> f32 {
    let cell = floor(coordinate);
    let f = smoothstep(vec2f(0.0), vec2f(1.0), fract(coordinate));
    let a = f32(terrainHash(cell, seed) & 65535u) / 65535.0;
    let b = f32(terrainHash(cell + vec2f(1.0, 0.0), seed) & 65535u) / 65535.0;
    let c = f32(terrainHash(cell + vec2f(0.0, 1.0), seed) & 65535u) / 65535.0;
    let d = f32(terrainHash(cell + vec2f(1.0), seed) & 65535u) / 65535.0;
    return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

@if(ADA_TERRAIN)
fn terrainCoarsest(layer: i32) -> TerrainTexel {
    let q = vec2f(0.5, 0.5);
    let albedo = textureSampleLevel(u_TerrainAlbedo, u_BaseColorSampler, q, layer, f32(textureNumLevels(u_TerrainAlbedo) - 1u));
    var normal = textureSampleLevel(u_TerrainNormal, u_BaseColorSampler, q, layer, f32(textureNumLevels(u_TerrainNormal) - 1u)).xyz * 2.0 - vec3f(1.0);
    let orm = textureSampleLevel(u_TerrainORM, u_BaseColorSampler, q, layer, f32(textureNumLevels(u_TerrainORM) - 1u));
    let flags = u32(terrain.u_TerrainVariation[layer].x);
    if (flags & 16u) != 0u {
        if (flags & 5u) != 0u {
            normal.x = 0.0;
        }
        if (flags & 6u) != 0u {
            normal.y = 0.0;
        }
    }
    return TerrainTexel(
        vec4f(srgbToLinear(albedo.rgb), albedo.a), normal, orm.rgb, select(0.5, orm.a, terrain.u_TerrainVariationScale[layer].w > 0.5)
    );
}

@if(ADA_TERRAIN)
fn terrainMacroColor(layer: i32, input: TerrainTexel, localPosition: vec2f) -> TerrainTexel {
    var value = input;
    let settings = terrain.u_TerrainVariation[layer];
    if settings.w > 0.0 {
        let seed = u32(settings.y) | (u32(settings.z) << 16u);
        let macroValue = terrainMacro(localPosition / terrain.u_TerrainVariationScale[layer].y, seed ^ 0x68bc21ebu);
        let tinted = clamp(value.albedo.rgb * (1.0 + (macroValue * 2.0 - 1.0) * settings.w), vec3f(0.0), vec3f(1.0));
        value.albedo = vec4f(tinted, value.albedo.a);
    }
    return value;
}

@if(ADA_TERRAIN)
fn terrainSample(layer: i32, uv: vec2f, dx: vec2f, dy: vec2f, localPosition: vec2f) -> TerrainTexel {
    let settings = terrain.u_TerrainVariation[layer];
    let flags = u32(settings.x);
    if terrain.u_TerrainVariationScale[layer].z > 0.5 {
        return terrainMacroColor(layer, terrainCoarsest(layer), localPosition);
    }
    if (flags & 16u) == 0u {
        return terrainRead(layer, uv, dx, dy, mat2x2f(1.0, 0.0, 0.0, 1.0), vec2f(0.0));
    }
    let seed = u32(settings.y) | (u32(settings.z) << 16u);
    let coordinate = uv / terrain.u_TerrainVariationScale[layer].x;
    let cell = floor(coordinate);
    let f = smoothstep(vec2f(0.0), vec2f(1.0), fract(coordinate));
    var result = TerrainTexel(vec4f(0.0), vec3f(0.0), vec3f(0.0), 0.0);
    for (var corner = 0; corner < 4; corner++) {
        let x = corner & 1;
        let y = corner >> 1u;
        let weight = select(f.x, 1.0 - f.x, x == 0) * select(f.y, 1.0 - f.y, y == 0);
        let random = terrainHash(cell + vec2f(f32(x), f32(y)), seed);
        let flipU = select(1.0, -1.0, (flags & 1u) != 0u && (random & 1u) != 0u);
        let flipV = select(1.0, -1.0, (flags & 2u) != 0u && (random & 2u) != 0u);
        var transform = mat2x2f(flipU, 0.0, 0.0, flipV);
        let rotation = select(0u, (random >> 2u) & 3u, (flags & 4u) != 0u);
        if rotation == 1u {
            transform = mat2x2f(0.0, 1.0, -1.0, 0.0) * transform;
        }
        if rotation == 2u {
            transform = transform * -1.0;
        }
        if rotation == 3u {
            transform = mat2x2f(0.0, -1.0, 1.0, 0.0) * transform;
        }
        let offset = select(vec2f(0.0), vec2f(f32((random >> 8u) & 255u), f32((random >> 16u) & 255u)) / 256.0, (flags & 8u) != 0u);
        let sampleValue = terrainRead(layer, uv, dx, dy, transform, offset);
        result.albedo += sampleValue.albedo * weight;
        result.normal += sampleValue.normal * weight;
        result.orm += sampleValue.orm * weight;
        result.height += sampleValue.height * weight;
    }
    return terrainMacroColor(layer, result, localPosition);
}

@if(ADA_TERRAIN)
fn terrainProjected(layer: i32, position: vec3f, dx: vec3f, dy: vec3f, geometric: vec3f, macroPosition: vec2f) -> TerrainTexel {
    var weights = pow(abs(geometric), vec3f(4.0));
    weights /= max(weights.x + weights.y + weights.z, 0.00001);
    var result = TerrainTexel(vec4f(0.0), vec3f(0.0), vec3f(0.0), 0.0);
    for (var axis = 0; axis < 3; axis++) {
        let weight = weights[axis];
        if weight <= 0.00001 {
            continue;
        }
        var uv = position.xy;
        var gradientX = dx.xy;
        var gradientY = dy.xy;
        if axis == 0 {
            uv = position.zy;
            gradientX = dx.zy;
            gradientY = dy.zy;
        } else if axis == 1 {
            uv = position.xz;
            gradientX = dx.xz;
            gradientY = dy.xz;
        }
        let value = terrainSample(layer, uv, gradientX, gradientY, macroPosition);
        let mapped = select(vec3f(0.0, 0.0, 1.0), normalize(value.normal), length(value.normal) > 0.00001);
        // Whiteout correction: every flat-map axis produces the same original geometric normal.
        var projected: vec3f;
        if axis == 0 {
            projected = vec3f(mapped.z * geometric.x, mapped.y + geometric.y, mapped.x + geometric.z);
        } else if axis == 1 {
            projected = vec3f(mapped.x + geometric.x, mapped.z * geometric.y, mapped.y + geometric.z);
        } else {
            projected = vec3f(mapped.x + geometric.x, mapped.y + geometric.y, mapped.z * geometric.z);
        }
        result.albedo += value.albedo * weight;
        result.normal += projected * weight;
        result.orm += value.orm * weight;
        result.height += value.height * weight;
    }
    result.normal = select(geometric, normalize(result.normal), length(result.normal) > 0.00001);
    return result;
}

struct AdaPBRSurface {
    baseColor: vec4f,
    normal: vec3f,
    roughness: f32,
    metallic: f32,
    opacity: f32,
    occlusion: f32,
    emission: vec3f,
}

@if(ADA_TERRAIN)
fn ada_material_surface() -> AdaPBRSurface {
    let grid0 = terrain.u_TerrainGrid;
    // Stable IDs are mapped to this generation's array slots on upload. Never interpolate indices.
    let volumeField = grid0.z < 0.0;
    var grid = select(max((Input.textureCoordinate - grid0.xy) * grid0.z, vec2f(0.0)), Input.textureCoordinate1, volumeField);
    let extent = vec2i(textureDimensions(u_MetallicRoughnessTexture, 0)) - vec2i(1);
    grid = min(grid, vec2f(extent));
    let start = select(vec2i(floor(grid)), vec2i(floor(grid / 2.0)) * 2, volumeField);
    let fraction = select(fract(grid), clamp(grid - vec2f(start), vec2f(0.0), vec2f(1.0)), volumeField);
    // Binding17 is a terrain-only vertical atlas: premixed tint/premultiplied roughness, then mask.
    // The shared neutral1x2 atlas keeps unpainted tiles allocation-free.
    let paintSize = vec2i(textureDimensions(u_HeightTexture, 0));
    let paintExtent = vec2i(paintSize.x, max(paintSize.y / 2, 1));
    var paintedSurface = vec4f(0.0);
    var paintedRoughnessMask = 0.0;
    var contributions: array<f32, 32>;
    for (var z = 0; z < 2; z++) {
        for (var x = 0; x < 2; x++) {
            if volumeField && x == 1 && z == 1 {
                continue;
            }
            let at = min(start + vec2i(x, z), extent);
            let ids = vec4i(round(textureLoad(u_MetallicRoughnessTexture, at, 0) * 255.0));
            let weights = textureLoad(u_NormalTexture, at, 0);
            var corner: f32;
            if volumeField {
                corner = select(select(max(0.0, 1.0 - fraction.x - fraction.y), fraction.y, z == 1), fraction.x, x == 1);
            } else {
                corner = select(fraction.x, 1.0 - fraction.x, x == 0) * select(fraction.y, 1.0 - fraction.y, z == 0);
            }
            let paintAt = min(at, paintExtent - vec2i(1));
            paintedSurface += textureLoad(u_HeightTexture, paintAt, 0) * corner;
            paintedRoughnessMask += textureLoad(u_HeightTexture, paintAt + vec2i(0, paintExtent.y), 0).r * corner;
            for (var channel = 0; channel < 4; channel++) {
                contributions[clamp(ids[channel], 0, 31)] += weights[channel] * corner;
            }
        }
    }
    var tint = vec4f(0.0);
    let geometric = normalize(Input.viewNormal);
    let localPosition = vec3f(Input.textureCoordinate.x, Input.viewTangent.w, Input.textureCoordinate.y);
    let localGeometric = normalize(Input.viewTangent.xyz);
    // Derivatives are evaluated unconditionally (at the top of the fragment stage), before per-layer and axis selection.
    let localGradientX = g_LocalPositionDx;
    let localGradientY = g_LocalPositionDy;
    let planarFrame = cotangentFrame(geometric, g_UVDx, g_UVDy);
    let localToViewNormal = inverse3(upperLeft(ibl.u_EnvironmentInverseView)) * upperLeft(terrainNormal.u_TerrainNormalToWorld);
    let normalTransformScale = max(length(localToViewNormal * localGeometric), 0.00001);
    var surface = vec2f(0.0);
    var normalSum = vec3f(0.0);
    var occlusion = 0.0;
    var total = 0.0;
    var layerTexels: array<TerrainTexel, 4>;
    var layerNormals: array<vec3f, 4>;
    var layerWeights: array<f32, 4>;
    var layerSlots: array<i32, 4>;
    var layerCount = 0;
    // Bilinear corners can introduce sixteen IDs; resolve the strongest four before shading.
    for (var outputSlot = 0; outputSlot < 4; outputSlot++) {
        var selected = 0;
        for (var slot = 1; slot < i32(grid0.w); slot++) {
            if contributions[slot] > contributions[selected] {
                selected = slot;
            }
        }
        let weight = contributions[selected];
        if weight <= 0.0 {
            break;
        }
        let coarse = terrain.u_TerrainVariationScale[selected].z > 0.5;
        let scale = select(terrain.u_TerrainSurfaces[selected].z, 1.0, coarse);
        var texel: TerrainTexel;
        var layerNormal: vec3f;
        if terrain.u_TerrainSurfaces[selected].w > 0.5 {
            texel = terrainProjected(
                selected,
                select(localPosition / scale, vec3f(0.0), coarse),
                select(localGradientX / scale, vec3f(0.0), coarse),
                select(localGradientY / scale, vec3f(0.0), coarse),
                localGeometric,
                Input.textureCoordinate
            );
            // Preserve the vertex-normalized/interpolated geometric baseline; transform only the map perturbation.
            layerNormal = geometric + localToViewNormal * (texel.normal - localGeometric) / normalTransformScale;
        } else {
            texel = terrainSample(
                selected,
                select(Input.textureCoordinate / scale, vec2f(0.0), coarse),
                select(g_UVDx / scale, vec2f(0.0), coarse),
                select(g_UVDy / scale, vec2f(0.0), coarse),
                Input.textureCoordinate
            );
            layerNormal = planarFrame * texel.normal;
        }
        layerTexels[outputSlot] = texel;
        layerNormals[outputSlot] = layerNormal;
        layerWeights[outputSlot] = weight;
        layerSlots[outputSlot] = selected;
        layerCount += 1;
        total += weight;
        contributions[selected] = 0.0;
    }
    let baseTotal = max(total, 0.00001);
    total = 0.0;
    for (var index = 0; index < layerCount; index++) {
        var weight = layerWeights[index] / baseTotal;
        // A bounded positive bias preserves equal-height ratios and the continuous zero-weight limit.
        // Missing maps supply exactly 0.5, so ordinary blending is unchanged (factor 1).
        weight *= exp2(8.0 * (layerTexels[index].height - 0.5));
        let selected = layerSlots[index];
        let texel = layerTexels[index];
        tint += terrain.u_TerrainTints[selected] * texel.albedo * weight;
        normalSum += layerNormals[index] * weight;
        surface += terrain.u_TerrainSurfaces[selected].xy * texel.orm.gb * weight;
        occlusion += texel.orm.r * weight;
        total += weight;
    }
    total = max(total, 0.00001);
    var normal = select(geometric, normalize(normalSum), length(normalSum) > 0.00001);
    if !surfaceFrontFacing() && pbr.u_SurfaceFlags.x > 0.5 {
        normal = -normal;
    }
    var baseColor = Input.color * tint / total;
    baseColor = vec4f(baseColor.rgb * paintedSurface.rgb, baseColor.a);
    let roughness = surface.x / total * (1.0 - paintedRoughnessMask) + paintedSurface.a;
    return AdaPBRSurface(
        baseColor, normal, clamp(roughness, 0.04, 1.0), clamp(surface.y / total, 0.0, 1.0), 1.0, clamp(occlusion / total, 0.0, 1.0), vec3f(0.0)
    );
}

@if(!ADA_TERRAIN && ADA_SHADER_GRAPH)
fn ada_material_surface() -> AdaPBRSurface {
    let graph = ada_graph_evaluate(Input.textureCoordinate);
    var baseColor = Input.color * graph.color;
    baseColor.a *= graph.alpha;
    if pbr.u_SurfaceProperties.w > 0.5 && pbr.u_SurfaceProperties.w < 1.5 && baseColor.a < pbr.u_SurfaceProperties.z {
        discard;
    }
    let opacity = select(1.0, baseColor.a, pbr.u_SurfaceProperties.w > 1.5);
    let geometric = normalize(Input.viewNormal);
    let tangentNormal = select(vec3f(0.0, 0.0, 1.0), normalize(graph.normal), length(graph.normal) > 0.00001);
    var normal: vec3f;
    if Input.textureFlags.w > 0.5 {
        let tangent = normalize(Input.viewTangent.xyz - geometric * dot(geometric, Input.viewTangent.xyz));
        let bitangent = normalize(cross(geometric, tangent)) * Input.viewTangent.w;
        normal = normalize(mat3x3f(tangent, bitangent, geometric) * tangentNormal);
    } else {
        normal = normalize(cotangentFrame(geometric, g_UVDx, g_UVDy) * tangentNormal);
    }
    if !surfaceFrontFacing() && pbr.u_SurfaceFlags.x > 0.5 {
        normal = -normal;
    }
    return AdaPBRSurface(
        baseColor, normal, clamp(graph.roughness, 0.04, 1.0), clamp(graph.metallic, 0.0, 1.0), opacity,
        clamp(graph.occlusion, 0.0, 1.0), max(graph.emission, vec3f(0.0))
    );
}

@if(!ADA_TERRAIN && !ADA_SHADER_GRAPH)
fn ada_material_surface() -> AdaPBRSurface {
    var baseColor = Input.color;
    if Input.textureFlags.x > 0.5 {
        let sampledBaseColor = sampleMaterial(u_BaseColorTexture, u_BaseColorSampler, materialUV(pbr.u_UVSets.x, 0));
        baseColor *= vec4f(srgbToLinear(sampledBaseColor.rgb), sampledBaseColor.a);
    }

    if pbr.u_SurfaceProperties.w > 0.5 && pbr.u_SurfaceProperties.w < 1.5 && baseColor.a < pbr.u_SurfaceProperties.z {
        discard;
    }
    let opacity = select(1.0, baseColor.a, pbr.u_SurfaceProperties.w > 1.5);
    var roughness = Input.material.x;
    var metallic = Input.material.y;
    if Input.textureFlags.y > 0.5 {
        let metallicRoughness = sampleMaterial(u_MetallicRoughnessTexture, u_MetallicRoughnessSampler, materialUV(pbr.u_UVSets.y, 1));
        roughness = clamp(roughness * metallicRoughness.g, 0.04, 1.0);
        metallic = clamp(metallic * metallicRoughness.b, 0.0, 1.0);
    }

    var normal = materialNormal();
    if !surfaceFrontFacing() && pbr.u_SurfaceFlags.x > 0.5 {
        normal = -normal;
    }
    return AdaPBRSurface(baseColor, normal, roughness, metallic, opacity, 1.0, vec3f(0.0));
}

var<private> g_LocalPositionDx: vec3f;
var<private> g_LocalPositionDy: vec3f;

@fragment
fn flat3d_fragment(input: Flat3DVertex, @builtin(front_facing) frontFacing: bool) -> Flat3DOutput {
    Input = input;
    g_FrontFacing = frontFacing;
    // Derivatives in uniform control flow; the shading code below reads these instead of calling dpdx/dpdy.
    g_PositionDx = dpdx(input.viewPosition);
    g_PositionDy = dpdy(input.viewPosition);
    g_UVDx = dpdx(input.textureCoordinate);
    g_UVDy = dpdy(input.textureCoordinate);
    g_UV1Dx = dpdx(input.textureCoordinate1);
    g_UV1Dy = dpdy(input.textureCoordinate1);
    g_LocalPositionDx = dpdx(vec3f(input.textureCoordinate.x, input.viewTangent.w, input.textureCoordinate.y));
    g_LocalPositionDy = dpdy(vec3f(input.textureCoordinate.x, input.viewTangent.w, input.textureCoordinate.y));

    var out: Flat3DOutput;
    if pbr.u_SurfaceFlags.z > 0.5 {
        g_ParallaxDelta = parallaxDelta();
    }
    if Input.shadowFlags.w > 0.0 && visibilityDither(input.position.xy) < Input.shadowFlags.w {
        discard;
    }
    @if(!ADA_WIREFRAME) {
        if pbr.u_SurfaceFlags.x < 0.5 && !surfaceFrontFacing() {
            discard;
        }
    }
    let surface = ada_material_surface();
    @if(ADA_WIREFRAME) {
        out.depth = input.position.z;
        out.color = vec4f(0.88, 0.93, 1.0, 1.0);
        out.normalRoughness = vec4f(surface.normal, surface.roughness);
        out.viewPositionMetallic = vec4f(Input.viewPosition, surface.metallic);
        out.indirectLighting = vec4f(0.0);
        @if(ADA_HYBRID_REFLECTION) {
            out.reflectionResponse = vec4f(0.0);
        }
        @if(ADA_DIFFUSE_SURFACE) {
            out.diffuseSurface = vec4f(0.0);
        }
        return out;
    }
    let baseColor = surface.baseColor;
    let opacity = surface.opacity;
    let roughness = surface.roughness;
    let metallic = surface.metallic;
    let normal = surface.normal;
    // Shading layers: each factor is multiplied by its texture when the material has one.
    g_Dielectric = pbr.u_Dielectric.rgb;
    @if(ADA_SPECULAR_TEXTURE) {
        g_Dielectric *= sampleMaterial(u_SpecularTexture, u_BaseColorSampler, layerUV(6)).a;
    }
    @if(ADA_SPECULAR_COLOR_TEXTURE) {
        g_Dielectric *= srgbToLinear(sampleMaterial(u_SpecularColorTexture, u_BaseColorSampler, layerUV(7)).rgb);
    }

    g_Sheen = vec4f(max(pbr.u_Sheen.rgb, vec3f(0.0)), clamp(pbr.u_Sheen.w, 0.07, 1.0));
    @if(ADA_SHEEN_COLOR_TEXTURE) {
        g_Sheen = vec4f(g_Sheen.rgb * srgbToLinear(sampleMaterial(u_SheenColorTexture, u_BaseColorSampler, layerUV(3)).rgb), g_Sheen.w);
    }
    @if(ADA_SHEEN_ROUGHNESS_TEXTURE) {
        g_Sheen.w = clamp(pbr.u_Sheen.w * sampleMaterial(u_SheenRoughnessTexture, u_BaseColorSampler, layerUV(4)).a, 0.07, 1.0);
    }

    g_Anisotropy = clamp(pbr.u_Anisotropy.x, 0.0, 1.0);
    var anisotropyDirection = vec2f(1.0, 0.0);
    @if(ADA_ANISOTROPY_TEXTURE) {
        // Red and green hold the direction in tangent space, blue scales the strength.
        let anisotropySample = sampleMaterial(u_AnisotropyTexture, u_BaseColorSampler, layerUV(5)).rgb;
        g_Anisotropy = clamp(g_Anisotropy * anisotropySample.b, 0.0, 1.0);
        let sampledDirection = anisotropySample.rg * 2.0 - vec2f(1.0);
        if dot(sampledDirection, sampledDirection) > 0.0001 {
            anisotropyDirection = normalize(sampledDirection);
        }
    }
    if hasAnisotropy() {
        var authored = Input.textureFlags.w > 0.5;
        @if(ADA_TERRAIN) {
            authored = false; // This slot packs local terrain data, not an authored tangent.
        }
        let frameUV = materialUV(pbr.u_UVSets.x, 0);
        var tangent = select(cotangentFrame(normalize(Input.viewNormal), frameUV.dx, frameUV.dy)[0], Input.viewTangent.xyz, authored);
        tangent = normalize(tangent - normal * dot(normal, tangent));
        let bitangent = normalize(cross(normal, tangent)) * select(1.0, Input.viewTangent.w, authored);
        // The rotation turns the direction, whether it comes from the texture or is the tangent itself.
        let rotationCosine = cos(pbr.u_Anisotropy.y);
        let rotationSine = sin(pbr.u_Anisotropy.y);
        let turned = vec2f(
            rotationCosine * anisotropyDirection.x - rotationSine * anisotropyDirection.y,
            rotationSine * anisotropyDirection.x + rotationCosine * anisotropyDirection.y
        );
        g_AnisotropyT = normalize(turned.x * tangent + turned.y * bitangent);
        g_AnisotropyB = normalize(cross(normal, g_AnisotropyT));
    }

    g_Clearcoat = vec2f(pbr.u_Coat.x, clamp(pbr.u_Coat.y, 0.04, 1.0));
    g_CoatNormal = normalize(Input.viewNormal);
    if !surfaceFrontFacing() && pbr.u_SurfaceFlags.x > 0.5 {
        g_CoatNormal = -g_CoatNormal;
    }
    @if(ADA_CLEARCOAT_TEXTURE) {
        g_Clearcoat.x *= sampleMaterial(u_ClearcoatTexture, u_BaseColorSampler, layerUV(0)).r;
    }
    @if(ADA_CLEARCOAT_ROUGHNESS_TEXTURE) {
        g_Clearcoat.y = clamp(pbr.u_Coat.y * sampleMaterial(u_ClearcoatRoughnessTexture, u_BaseColorSampler, layerUV(1)).g, 0.04, 1.0);
    }
    @if(ADA_CLEARCOAT_NORMAL_TEXTURE) {
        let coatUV = layerUV(2);
        var coatTangentNormal = sampleMaterial(u_ClearcoatNormalTexture, u_BaseColorSampler, coatUV).xyz * 2.0 - vec3f(1.0);
        coatTangentNormal = vec3f(coatTangentNormal.xy * pbr.u_LayerParameters.x, coatTangentNormal.z);
        g_CoatNormal = normalize(cotangentFrame(g_CoatNormal, coatUV.dx, coatUV.dy) * coatTangentNormal);
    }
    let viewDirection = normalize(-Input.viewPosition);
    let lightDirection = normalize(directional.u_LightDirectionIntensity.xyz);
    out.depth = input.position.z;

    if Input.shadowFlags.y > 0.0 {
        // The atmosphere is drawn before the planet. Keep its haze in the color target without preventing the opaque
        // planet from drawing.
        out.depth = 1.0;

        let dayFacing = smoothstep(-0.3, 0.55, dot(normal, lightDirection));
        let fresnelPower = mix(Input.shadowFlags.y + 1.5, Input.shadowFlags.y * 0.58, dayFacing);
        let fresnel = pow(clamp(1.0 - abs(dot(normal, viewDirection)), 0.0, 1.0), max(fresnelPower, 0.5));
        let alpha = clamp(baseColor.a * Input.shadowFlags.z * fresnel * mix(0.28, 1.0, dayFacing), 0.0, 0.88);
        let atmosphereColor = baseColor.rgb * mix(0.72, 1.2, dayFacing);

        out.color = vec4f(atmosphereColor, alpha);
        out.indirectLighting = vec4f(0.0, 0.0, 0.0, alpha);
        @if(ADA_HYBRID_REFLECTION) {
            out.reflectionResponse = vec4f(0.0, 0.0, 0.0, alpha);
        }
        out.normalRoughness = vec4f(normal, 1.0);
        out.viewPositionMetallic = vec4f(Input.viewPosition, 0.0);
        return out;
    }

    let normalLight = max(dot(normal, lightDirection), 0.0);
    let normalView = max(dot(normal, viewDirection), 0.0);

    let radiance = max(directional.u_LightRadianceAmbient.rgb, vec3f(0.0)) * max(directional.u_LightDirectionIntensity.w, 0.0);
    // The sun term is multiplied by n.l, so surfaces facing away from it skip the cascade lookups. The clearcoat
    // follows the geometric normal and can still be lit there.
    let coatLit = hasClearcoat();
    var shadowVisibility = 1.0;
    if normalLight > 0.0 || coatLit {
        shadowVisibility = directionalShadow(normal, lightDirection);
    }
    if surfaceLighting.u_ContactQuality.z > 0.5 {
        shadowVisibility *= contactVisibility(normal, lightDirection, surfaceLighting.u_Contact.y);
    }
    var distanceFieldVisibility = 1.0;
    let sdfTrace = distanceField.u_SDFTrace;
    if sdfTrace.w > 0.5 && surfaceLighting.u_ContactQuality.z > 0.5 && Input.shadowFlags.x > 0.5
        && (normalLight > 0.0 || coatLit) && (shadowVisibility > 0.0 || sdfTrace.w > 1.5) {
        var sdfNormal = Input.viewNormal;
        if !surfaceFrontFacing() && pbr.u_SurfaceFlags.x > 0.5 {
            sdfNormal = -sdfNormal;
        }
        let inverseView = upperLeft(ibl.u_EnvironmentInverseView);
        distanceFieldVisibility = adaDistanceFieldVisibility(
            Input.worldPosition, normalize(inverseView * sdfNormal), normalize(inverseView * lightDirection),
            distanceField.u_SDFCountsDistance.w
        );
        shadowVisibility *= distanceFieldVisibility;
    }
    var directLighting = evaluateDirect(normal, viewDirection, lightDirection, baseColor.rgb, metallic, roughness, radiance) * shadowVisibility;
    directLighting += additionalLighting(normal, viewDirection, baseColor.rgb, metallic, roughness);
    var ambient = baseColor.rgb * (1.0 - metallic) * max(directional.u_LightRadianceAmbient.w, 0.0);
    let baked = adaBakedDiffuse(
        Input.worldPosition, normalize(upperLeft(ibl.u_EnvironmentInverseView) * normal), Input.textureCoordinate1,
        pbr.u_LightmapScaleOffset, pbr.u_BakedParameters
    );
    var bakedPart = vec3f(0.0);
    if ibl.u_IBLParameters.x > 0.5 {
        let environment = environmentLighting(normal, viewDirection, baseColor.rgb, metallic, roughness, baked);
        ambient = environment.color;
        bakedPart = environment.bakedPart;
    } else if coatLit {
        ambient *= coatTransmission(max(dot(g_CoatNormal, viewDirection), 0.0));
    }
    @if(ADA_LIGHTMAP || ADA_IRRADIANCE_GRID) {
        if ibl.u_IBLParameters.x < 0.5 {
            let f0 = mix(g_Dielectric, baseColor.rgb, metallic);
            let fresnel = f0 + (max(vec3f(1.0 - roughness), f0) - f0) * pow(1.0 - normalView, 5.0);
            var bakedAmbient = (vec3f(1.0) - fresnel) * (1.0 - metallic) * baseColor.rgb * baked.rgb;
            if hasSheen() {
                bakedAmbient = bakedAmbient * sheenTransmission() + g_Sheen.rgb * SHEEN_ALBEDO * baked.rgb;
            }
            if coatLit {
                bakedAmbient *= coatTransmission(max(dot(g_CoatNormal, viewDirection), 0.0));
            }
            ambient = mix(ambient, bakedAmbient, baked.a);
            bakedPart = bakedAmbient * baked.a;
        }
    }
    var occlusion = 1.0;
    @if(ADA_SHADER_GRAPH || ADA_TERRAIN) {
        occlusion = surface.occlusion;
    }
    @if(!ADA_SHADER_GRAPH && !ADA_TERRAIN) {
        if pbr.u_SurfaceFlags.y > 0.5 {
            occlusion = sampleMaterial(u_OcclusionTexture, u_OcclusionSampler, materialUV(pbr.u_UVSets.w, 3)).r;
        }
    }
    ambient *= mix(1.0, occlusion, pbr.u_SurfaceProperties.y);
    @if(ADA_LIGHTMAP || ADA_IRRADIANCE_GRID) {
        // Geometry visibility is already baked. Material AO still affects runtime environment specular.
        ambient += bakedPart * (1.0 - mix(1.0, occlusion, pbr.u_SurfaceProperties.y));
    }
    g_ReflectionResponse *= mix(1.0, occlusion, pbr.u_SurfaceProperties.y);
    var emissiveVisibility = 1.0;
    let emissiveLightThreshold = Input.material.w;
    if emissiveLightThreshold >= 0.0 {
        emissiveVisibility = 1.0 - smoothstep(emissiveLightThreshold, emissiveLightThreshold + 0.16, normalLight);
    }
    var emissive = vec3f(0.0);
    @if(ADA_SHADER_GRAPH || ADA_TERRAIN) {
        emissive = surface.emission * emissiveVisibility;
    }
    @if(!ADA_SHADER_GRAPH && !ADA_TERRAIN) {
        emissive = srgbToLinear(sampleMaterial(u_EmissiveTexture, u_EmissiveSampler, materialUV(pbr.u_Emission.x, 4)).rgb)
            * pbr.u_EmissiveFactor.rgb * Input.material.z * emissiveVisibility;
    }

    out.color = vec4f(directLighting + ambient + emissive, opacity);
    if sdfTrace.w > 1.5 {
        out.color = vec4f(mix(vec3f(0.6, 0.025, 0.015), vec3f(0.025, 0.65, 0.08), distanceFieldVisibility), opacity);
    }
    @if(ADA_DIFFUSE_SURFACE) {
        let giF0 = mix(g_Dielectric, baseColor.rgb, metallic);
        let giFresnel = giF0 + (max(vec3f(1.0 - roughness), giF0) - giF0) * pow(1.0 - max(dot(normal, viewDirection), 0.0), 5.0);
        var diffuseWeight = (vec3f(1.0) - giFresnel) * (1.0 - metallic);
        if coatLit {
            diffuseWeight *= coatTransmission(max(dot(g_CoatNormal, viewDirection), 0.0));
        }
        out.diffuseSurface = vec4f(clamp(baseColor.rgb * diffuseWeight, vec3f(0.0), vec3f(1.0)), opacity);
    }
    let debugMode = directional.u_ShadowAtlas.w;
    if debugMode > 0.5 {
        var debugColor = vec3f(0.3);
        if debugMode < 1.5 {
            debugColor = adaLinearToSrgb(baseColor.rgb);
        } else if debugMode < 2.5 {
            debugColor = cascadeTint(normalLight);
        } else if debugMode < 3.5 {
            debugColor = heatRamp(reachingLightCount() / 8.0);
        }
        out.color = vec4f(select(debugColor, vec3f(0.025), debugMode > 4.5), opacity);
    }
    // Transparent surfaces attenuate the opaque indirect buffer but do not contribute to it.
    let transparent = pbr.u_SurfaceProperties.w > 1.5;
    out.indirectLighting = vec4f(select(ambient, vec3f(0.0), transparent), opacity);
    @if(ADA_HYBRID_REFLECTION) {
        out.reflectionResponse = vec4f(select(g_ReflectionResponse, vec3f(0.0), transparent), opacity);
    }
    out.normalRoughness = vec4f(normal, roughness);
    out.viewPositionMetallic = vec4f(Input.viewPosition, metallic);
    @if(ADA_PATH_TRACING_SURFACE && ADA_DIFFUSE_SURFACE && ADA_HYBRID_REFLECTION) {
        // Path-traced views start their paths at this surface: base colour and emission replace the
        // raster diffuse/specular responses, which screen-space GI and reflections do not use while tracing.
        out.diffuseSurface = vec4f(clamp(baseColor.rgb, vec3f(0.0), vec3f(1.0)), opacity);
        out.reflectionResponse = vec4f(select(emissive, vec3f(0.0), transparent), opacity);
    }
    return out;
}
