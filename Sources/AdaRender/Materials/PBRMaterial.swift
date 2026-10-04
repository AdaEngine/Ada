//
//  PBRMaterial.swift
//  AdaEngine
//
//  Created by v.prusakov on 04/21/26.
//

import AdaAssets
import AdaUtils
import Math

/// A material that uses Physically Based Rendering (PBR) to define its appearance.
public class PBRMaterial: Material, @unchecked Sendable {
    public var baseColorFactor: Vector4 = .one
    public var baseColorTexture: Texture2D?
    public var metallicFactor: Float = 1
    public var roughnessFactor: Float = 1
    public var metallicRoughnessTexture: Texture2D?
    public var normalTexture: Texture2D?
    public var emissiveTexture: Texture2D?
    public var emissiveStrength: Float = 0
    public var emissiveFactor: Vector3 = .one
    public var occlusionTexture: Texture2D?
    public var occlusionStrength: Float = 1
    public var normalScale: Float = 1
    public enum AlphaMode: UInt8, Sendable { case opaque, mask, blend }
    public var alphaMode: AlphaMode = .opaque
    public var alphaCutoff: Float = 0.5
    public var doubleSided = false
    /// UV sets for base color, metallic/roughness, normal, occlusion, and emission.
    public var textureCoordinates: [Int] = [0, 0, 0, 0, 0]
    /// A negative value emits everywhere. Non-negative values fade emission
    /// out as direct illumination rises above this threshold.
    public var emissiveLightThreshold: Float = -1

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
