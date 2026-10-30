//
//  PBRMaterial.swift
//  AdaEngine
//
//  Created by v.prusakov on 04/21/26.
//

import AdaAssets
import AdaUtils
import Math

/// Scales, then rotates, then offsets the UV coordinates a PBR texture is sampled with (glTF `KHR_texture_transform`).
public struct PBRTextureTransform: Sendable, Equatable {
    public var offset: Vector2
    /// Counter-clockwise rotation in radians.
    public var rotation: Float
    public var scale: Vector2

    public static let identity = Self()

    public init(offset: Vector2 = .zero, rotation: Float = 0, scale: Vector2 = .one) {
        self.offset = offset
        self.rotation = rotation
        self.scale = scale
    }
}

/// A texture read by one of the material's shading layers, with the UV set and transform it is read with.
public struct PBRTextureBinding: Sendable {
    public var texture: Texture2D
    /// UV set (0 or 1).
    public var texCoord: Int
    public var transform: PBRTextureTransform
    /// Scale of the sampled value; only the clearcoat normal map uses it.
    public var scale: Float

    public init(texture: Texture2D, texCoord: Int = 0, transform: PBRTextureTransform = .identity, scale: Float = 1) {
        self.texture = texture
        self.texCoord = texCoord
        self.transform = transform
        self.scale = scale
    }
}

/// The textures of the shading layers and of the specular extension, and where they bind in the main shader.
///
/// They are read with the base color texture's sampler, because the main pass has no free sampler slots.
public enum PBRLayerTexture: Int, CaseIterable, Hashable, Sendable {
    /// Clearcoat strength (red).
    case clearcoat
    /// Clearcoat roughness (green).
    case clearcoatRoughness
    /// Tangent-space normal of the clearcoat layer.
    case clearcoatNormal
    /// Sheen color (RGB, sRGB).
    case sheenColor
    /// Sheen roughness (alpha).
    case sheenRoughness
    /// Anisotropy direction (red, green) and strength (blue).
    case anisotropy
    /// Specular strength (alpha).
    case specular
    /// Specular color (RGB, sRGB).
    case specularColor

    /// The texture binding in the main shader.
    public var binding: Int { 32 + rawValue }

    /// The feature bit that selects the shader variant declaring this texture.
    public var feature: PBRMaterial.ShaderFeatures { PBRMaterial.ShaderFeatures(rawValue: 1 << UInt32(3 + rawValue)) }

    var macro: String {
        switch self {
        case .clearcoat: "ADA_CLEARCOAT_TEXTURE"
        case .clearcoatRoughness: "ADA_CLEARCOAT_ROUGHNESS_TEXTURE"
        case .clearcoatNormal: "ADA_CLEARCOAT_NORMAL_TEXTURE"
        case .sheenColor: "ADA_SHEEN_COLOR_TEXTURE"
        case .sheenRoughness: "ADA_SHEEN_ROUGHNESS_TEXTURE"
        case .anisotropy: "ADA_ANISOTROPY_TEXTURE"
        case .specular: "ADA_SPECULAR_TEXTURE"
        case .specularColor: "ADA_SPECULAR_COLOR_TEXTURE"
        }
    }

    /// The layer a texture belongs to, if it only matters while that layer is on.
    fileprivate var layer: PBRMaterial.ShaderFeatures? {
        switch self {
        case .clearcoat, .clearcoatRoughness, .clearcoatNormal: .clearcoat
        case .sheenColor, .sheenRoughness: .sheen
        case .anisotropy: .anisotropy
        case .specular, .specularColor: nil
        }
    }
}

/// A material that uses Physically Based Rendering (PBR) to define its appearance.
public class PBRMaterial: Material, @unchecked Sendable {
    /// Optional fragment graph; lighting, skinning and render-pass configuration stay shared.
    public var graphMaterial: ShaderGraphMaterial? { didSet { uniformRevision &+= 1 } }
    public var effectiveAlphaMode: AlphaMode {
        switch graphMaterial?.program.renderSettings.mode {
        case .opaque: .opaque
        case .mask: .mask
        case .blend: .blend
        case nil: alphaMode
        }
    }
    public var effectiveAlphaCutoff: Float { graphMaterial?.program.renderSettings.alphaCutoff ?? alphaCutoff }
    public var effectiveDoubleSided: Bool { graphMaterial?.program.renderSettings.doubleSided ?? doubleSided }
    public var baseColorFactor: Vector4 = .one { didSet { uniformRevision &+= 1 } }
    public var baseColorTexture: Texture2D?
    public var metallicFactor: Float = 1
    public var roughnessFactor: Float = 1
    public var metallicRoughnessTexture: Texture2D?
    public var normalTexture: Texture2D?
    public var emissiveTexture: Texture2D?
    public var emissiveStrength: Float = 0
    public var emissiveFactor: Vector3 = .one { didSet { uniformRevision &+= 1 } }
    public var occlusionTexture: Texture2D? { didSet { uniformRevision &+= 1 } }
    public var occlusionStrength: Float = 1 { didSet { uniformRevision &+= 1 } }
    /// Linear incident diffuse lighting / pi on UV1. Static lighting replaces diffuse IBL, preserving its specular.
    public var lightmapTexture: Texture2D? { didSet { uniformRevision &+= 1 } }
    public var lightmapScaleOffset: Vector4 = [1, 1, 0, 0] { didSet { uniformRevision &+= 1 } }
    public var lightmapIntensity: Float = 1 { didSet { uniformRevision &+= 1 } }
    public var normalScale: Float = 1 { didSet { uniformRevision &+= 1 } }
    /// Height map for parallax occlusion mapping, read from the red channel (`1` is the top of the surface, `0` the
    /// deepest point). Use a linear (non-sRGB) texture. Parallax shifts every material texture that shares
    /// ``heightTextureCoordinate``, so the relief stays consistent with color, normal and occlusion maps.
    /// The shader has no free sampler slot, so the height map is read with the base color texture's sampler:
    /// give both the same address and filter modes.
    public var heightTexture: Texture2D? { didSet { uniformRevision &+= 1 } }
    /// Depth of the relief in world units, measured from the top of the surface. `0` disables parallax.
    public var heightScale: Float = 0.05 { didSet { uniformRevision &+= 1 } }
    /// UV set the height map is sampled with.
    public var heightTextureCoordinate: Int = 0 { didSet { uniformRevision &+= 1 } }
    /// Largest number of ray-march steps, used at grazing angles (a quarter of it is used head-on). Clamped to `4...64`.
    public var heightMaxLayers: Int = 32 { didSet { uniformRevision &+= 1 } }
    /// Camera distance in view units beyond which parallax has faded out completely. It fades over the last half.
    public var heightFadeDistance: Float = 30 { didSet { uniformRevision &+= 1 } }
    public enum AlphaMode: UInt8, Sendable { case opaque, mask, blend }
    public var alphaMode: AlphaMode = .opaque { didSet { uniformRevision &+= 1 } }
    public var alphaCutoff: Float = 0.5 { didSet { uniformRevision &+= 1 } }
    public var doubleSided = false { didSet { uniformRevision &+= 1 } }
    /// UV sets for base color, metallic/roughness, normal, occlusion, and emission.
    public var textureCoordinates: [Int] = [0, 0, 0, 0, 0] { didSet { uniformRevision &+= 1 } }
    /// A negative value emits everywhere. Non-negative values fade emission
    /// out as direct illumination rises above this threshold.
    public var emissiveLightThreshold: Float = -1
    /// UV transforms for base color, metallic/roughness, normal, occlusion, and emission.
    public var textureTransforms: [PBRTextureTransform] = Array(repeating: .identity, count: 5) { didSet { uniformRevision &+= 1 } }
    /// Index of refraction of the dielectric layer. The default 1.5 gives the usual 4% reflectance at normal incidence.
    public var ior: Float = 1.5 { didSet { uniformRevision &+= 1 } }
    /// Strength of the dielectric specular reflection (`KHR_materials_specular`).
    public var specularFactor: Float = 1 { didSet { uniformRevision &+= 1 } }
    /// Tint of the dielectric specular reflection (`KHR_materials_specular`).
    public var specularColorFactor: Vector3 = .one { didSet { uniformRevision &+= 1 } }
    /// Strength of a clear lacquer layer over the surface (`KHR_materials_clearcoat`); 0 turns the layer off.
    public var clearcoatFactor: Float = 0 { didSet { uniformRevision &+= 1 } }
    /// Roughness of the clearcoat layer, independent of the base layer's roughness.
    public var clearcoatRoughnessFactor: Float = 0 { didSet { uniformRevision &+= 1 } }
    /// Color of a soft fabric sheen over the surface (`KHR_materials_sheen`); black turns the layer off.
    public var sheenColorFactor: Vector3 = .zero { didSet { uniformRevision &+= 1 } }
    /// Roughness of the sheen layer.
    public var sheenRoughnessFactor: Float = 0 { didSet { uniformRevision &+= 1 } }
    /// How much highlights stretch (`KHR_materials_anisotropy`, 0 to 1); 0 keeps them round.
    public var anisotropyStrength: Float = 0 { didSet { uniformRevision &+= 1 } }
    /// Rotation of the stretch direction from the surface tangent, in radians.
    public var anisotropyRotation: Float = 0 { didSet { uniformRevision &+= 1 } }
    /// Textures of the clearcoat, sheen, anisotropy and specular layers. Each multiplies its layer's factor.
    public var layerTextures: [PBRLayerTexture: PBRTextureBinding] = [:] { didSet { uniformRevision &+= 1 } }

    /// The optional shading layers and layer textures a material needs. The main shader is compiled with only what a
    /// material uses; the empty set is the plain shader, which is also the only one that has a shader cache and a web build.
    public struct ShaderFeatures: OptionSet, Hashable, Sendable {
        public let rawValue: UInt32
        public init(rawValue: UInt32) { self.rawValue = rawValue }

        public static let clearcoat = Self(rawValue: 1 << 0)
        public static let sheen = Self(rawValue: 1 << 1)
        public static let anisotropy = Self(rawValue: 1 << 2)

        /// The draw's mesh has morph targets. A property of the draw, not of the material, so ``PBRMaterial/shaderFeatures``
        /// never contains it.
        public static let morph = Self(rawValue: 1 << 11)
        /// The geometry pass stores the base specular response for hybrid IBL/SSR replacement.
        public static let hybridReflection = Self(rawValue: 1 << 12)
        public static let diffuseSurface = Self(rawValue: 1 << 13)
        public static let lightmap = Self(rawValue: 1 << 14)
        public static let irradianceGrid = Self(rawValue: 1 << 15)

        /// Every layer, without textures.
        public static let all: ShaderFeatures = [.clearcoat, .sheen, .anisotropy]

        /// Preprocessor names that switch each layer and texture in this set on. Empty for the plain shader.
        public var enablingMacros: [String] {
            var macros: [String] = []
            if contains(.clearcoat) { macros.append("ADA_CLEARCOAT") }
            if contains(.sheen) { macros.append("ADA_SHEEN") }
            if contains(.anisotropy) { macros.append("ADA_ANISOTROPY") }
            if contains(.morph) { macros.append("ADA_MORPH") }
            if contains(.hybridReflection) { macros.append("ADA_HYBRID_REFLECTION") }
            if contains(.diffuseSurface) { macros.append("ADA_DIFFUSE_SURFACE") }
            if contains(.lightmap) { macros.append("ADA_LIGHTMAP") }
            if contains(.irradianceGrid) { macros.append("ADA_IRRADIANCE_GRID") }
            for texture in PBRLayerTexture.allCases where contains(texture.feature) {
                macros.append(texture.macro)
            }
            return macros
        }
    }

    /// The layers and textures this material currently uses, from its factor values and textures.
    public var shaderFeatures: ShaderFeatures {
        var features: ShaderFeatures = []
        if lightmapTexture != nil { features.insert(.lightmap) }
        if clearcoatFactor > 0 { features.insert(.clearcoat) }
        if max(sheenColorFactor.x, max(sheenColorFactor.y, sheenColorFactor.z)) > 0 { features.insert(.sheen) }
        if anisotropyStrength > 0 { features.insert(.anisotropy) }
        for texture in layerTextures.keys {
            // A layer texture scales its layer's factor, so with the layer off it changes nothing.
            if let layer = texture.layer, !features.contains(layer) { continue }
            features.insert(texture.feature)
        }
        return features
    }

    /// Changes whenever parameters in the shared PBR uniform snapshot are edited.
    @_spi(Internal) public private(set) var uniformRevision: UInt64 = 0

    public init() {
        // FIXME: (Vlad) We need a way to specify the shader for PBR material.
        // For now we use a dummy shader source.
        super.init(shaderSource: ShaderSource())
    }

    public required init(from assetDecoder: AssetDecoder) throws {
        let shaderSource = try ShaderSource(from: assetDecoder)
        super.init(shaderSource: shaderSource)
    }

    override public func collectDefines(for _: VertexDescriptor, keys _: Set<String>) -> [ShaderDefine] {
        var defines: [ShaderDefine] = []
        if baseColorTexture != nil {
            defines.append(ShaderDefine(name: "HAS_BASE_COLOR_TEXTURE", value: "1"))
        }
        if metallicRoughnessTexture != nil {
            defines.append(ShaderDefine(name: "HAS_METALLIC_ROUGHNESS_TEXTURE", value: "1"))
        }
        if normalTexture != nil {
            defines.append(ShaderDefine(name: "HAS_NORMAL_TEXTURE", value: "1"))
        }
        if emissiveTexture != nil {
            defines.append(ShaderDefine(name: "HAS_EMISSIVE_TEXTURE", value: "1"))
        }
        return defines
    }
}
