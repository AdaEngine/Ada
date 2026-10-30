import AdaECS
@_spi(Internal) import AdaRender
import Math

/// One texture slot's UV transform: the first vector is the row-major 2x2 matrix, the second holds the offset.
public struct PBR3DTextureTransform: Sendable, Equatable {
    public let matrix: Vector4
    public let offset: Vector4

    init(_ transform: PBRTextureTransform?) {
        let transform = transform ?? .identity
        // glTF: uv' = T * R * S * uv with R = [[cos, sin], [-sin, cos]].
        let cosine = Math.cos(transform.rotation)
        let sine = Math.sin(transform.rotation)
        matrix = Vector4(
            cosine * transform.scale.x, sine * transform.scale.y,
            -sine * transform.scale.x, cosine * transform.scale.y
        )
        offset = Vector4(transform.offset.x, transform.offset.y, 0, 0)
    }
}

/// Per-draw material parameters; vertex instance data retains color and metal/rough factors.
public struct PBR3DUniform: Sendable, Equatable {
    public let emissiveFactor: Vector4
    public let properties: Vector4
    public let flags: Vector4
    public let coordinates: Vector4
    public let emission: Vector4
    /// Parallax: height scale, UV set, maximum ray-march layers and fade distance.
    public let parallax: Vector4
    /// UV transforms for base color, metallic/roughness, normal, occlusion and emission, in that order.
    public let transform0: PBR3DTextureTransform
    public let transform1: PBR3DTextureTransform
    public let transform2: PBR3DTextureTransform
    public let transform3: PBR3DTextureTransform
    public let transform4: PBR3DTextureTransform
    /// RGB is the reflectance of a non-metal at normal incidence, from the index of refraction and `KHR_materials_specular`.
    public let dielectric: Vector4
    /// X is the clearcoat strength and y its roughness.
    public let coat: Vector4
    /// RGB is the sheen color and w its roughness.
    public let sheen: Vector4
    /// X is the anisotropy strength and y its rotation in radians.
    public let anisotropy: Vector4
    /// UV sets (0 or 1) of the layer textures in `PBRLayerTexture` order: clearcoat to sheen color, then sheen roughness to specular color.
    public let layerSets0: Vector4
    public let layerSets1: Vector4
    /// UV transforms of the layer textures in `PBRLayerTexture` order.
    public let layerTransform0: PBR3DTextureTransform
    public let layerTransform1: PBR3DTextureTransform
    public let layerTransform2: PBR3DTextureTransform
    public let layerTransform3: PBR3DTextureTransform
    public let layerTransform4: PBR3DTextureTransform
    public let layerTransform5: PBR3DTextureTransform
    public let layerTransform6: PBR3DTextureTransform
    public let layerTransform7: PBR3DTextureTransform
    /// X is the clearcoat normal scale.
    public let layerParameters: Vector4
    public let lightmapScaleOffset: Vector4
    public let bakedParameters: Vector4

    public init(material: PBRMaterial?, descriptor _: VertexDescriptor) {
        func coordinate(_ slot: Int) -> Int {
            guard let material, material.textureCoordinates.indices.contains(slot) else {
                return 0
            }
            return material.textureCoordinates[slot]
        }
        func transform(_ slot: Int) -> PBR3DTextureTransform {
            PBR3DTextureTransform(material?.textureTransforms.indices.contains(slot) == true ? material?.textureTransforms[slot] : nil)
        }
        emissiveFactor = Vector4(material?.emissiveFactor ?? .one, 0)
        properties = Vector4(material?.normalScale ?? 1, material?.occlusionStrength ?? 1, material?.effectiveAlphaCutoff ?? 0.5, Float(material?.effectiveAlphaMode.rawValue ?? 0))
        let heightScale = material?.heightTexture != nil ? max(finiteRenderValue(material?.heightScale ?? 0, fallback: 0, range: 0...1000), 0) : 0
        flags = Vector4(material?.effectiveDoubleSided ?? true ? 1 : 0, material?.occlusionTexture != nil ? 1 : 0, heightScale > 0 ? 1 : 0, 0)
        coordinates = Vector4(Float(coordinate(0)), Float(coordinate(1)), Float(coordinate(2)), Float(coordinate(3)))
        emission = Vector4(Float(coordinate(4)), material?.baseColorFactor.w ?? 1, 1, 0)
        parallax = Vector4(
            heightScale,
            Float(min(max(material?.heightTextureCoordinate ?? 0, 0), 1)),
            Float(min(max(material?.heightMaxLayers ?? 32, 4), 64)),
            finiteRenderValue(material?.heightFadeDistance ?? 30, fallback: 30, range: 0.1...100000)
        )
        transform0 = transform(0)
        transform1 = transform(1)
        transform2 = transform(2)
        transform3 = transform(3)
        transform4 = transform(4)
        dielectric = Vector4(Self.dielectricReflectance(material), 0)
        coat = Vector4(
            finiteRenderValue(material?.clearcoatFactor ?? 0, fallback: 0, range: 0...1),
            finiteRenderValue(material?.clearcoatRoughnessFactor ?? 0, fallback: 0, range: 0...1),
            0,
            0
        )
        let sheenColor = material?.sheenColorFactor ?? .zero
        sheen = Vector4(
            finiteRenderValue(sheenColor.x, fallback: 0, range: 0...1),
            finiteRenderValue(sheenColor.y, fallback: 0, range: 0...1),
            finiteRenderValue(sheenColor.z, fallback: 0, range: 0...1),
            finiteRenderValue(material?.sheenRoughnessFactor ?? 0, fallback: 0, range: 0...1)
        )
        anisotropy = Vector4(
            finiteRenderValue(material?.anisotropyStrength ?? 0, fallback: 0, range: 0...1),
            finiteRenderValue(material?.anisotropyRotation ?? 0, fallback: 0, range: -100...100),
            0,
            0
        )
        func layer(_ texture: PBRLayerTexture) -> PBRTextureBinding? { material?.layerTextures[texture] }
        func layerSet(_ texture: PBRLayerTexture) -> Float { Float(min(max(layer(texture)?.texCoord ?? 0, 0), 1)) }
        func layerTransform(_ texture: PBRLayerTexture) -> PBR3DTextureTransform { PBR3DTextureTransform(layer(texture)?.transform) }
        layerSets0 = Vector4(layerSet(.clearcoat), layerSet(.clearcoatRoughness), layerSet(.clearcoatNormal), layerSet(.sheenColor))
        layerSets1 = Vector4(layerSet(.sheenRoughness), layerSet(.anisotropy), layerSet(.specular), layerSet(.specularColor))
        layerTransform0 = layerTransform(.clearcoat)
        layerTransform1 = layerTransform(.clearcoatRoughness)
        layerTransform2 = layerTransform(.clearcoatNormal)
        layerTransform3 = layerTransform(.sheenColor)
        layerTransform4 = layerTransform(.sheenRoughness)
        layerTransform5 = layerTransform(.anisotropy)
        layerTransform6 = layerTransform(.specular)
        layerTransform7 = layerTransform(.specularColor)
        layerParameters = Vector4(finiteRenderValue(layer(.clearcoatNormal)?.scale ?? 1, fallback: 1, range: 0...100), 0, 0, 0)
        lightmapScaleOffset = material?.lightmapScaleOffset ?? [1, 1, 0, 0]
        bakedParameters = [finiteRenderValue(material?.lightmapIntensity ?? 1, fallback: 1, range: 0...16), 0, 0, 0]
    }

    /// Reflectance at normal incidence of the dielectric layer: ((ior - 1) / (ior + 1))^2 tinted and scaled by the
    /// specular parameters, capped at 1. The defaults give exactly 0.04.
    static func dielectricReflectance(_ material: PBRMaterial?) -> Vector3 {
        let ior = material.map { $0.ior.isFinite ? max($0.ior, 1) : 1.5 } ?? 1.5
        let base = ((ior - 1) / (ior + 1)) * ((ior - 1) / (ior + 1))
        let strength = material.map { $0.specularFactor.isFinite ? max($0.specularFactor, 0) : 1 } ?? 1
        let tint = material?.specularColorFactor ?? .one
        func channel(_ value: Float) -> Float {
            min(base * (value.isFinite ? max(value, 0) : 1), 1) * strength
        }
        return Vector3(channel(tint.x), channel(tint.y), channel(tint.z))
    }

    /// A bit-exact view of every field, so equal material values share one buffer even for -0 and NaN.
    var bitPatterns: [SIMD4<UInt32>] {
        func bits(_ vector: Vector4) -> SIMD4<UInt32> {
            SIMD4(vector.x.bitPattern, vector.y.bitPattern, vector.z.bitPattern, vector.w.bitPattern)
        }
        return [
            bits(emissiveFactor), bits(properties), bits(flags), bits(coordinates), bits(emission), bits(parallax),
            bits(transform0.matrix), bits(transform0.offset), bits(transform1.matrix), bits(transform1.offset),
            bits(transform2.matrix), bits(transform2.offset), bits(transform3.matrix), bits(transform3.offset),
            bits(transform4.matrix), bits(transform4.offset), bits(dielectric), bits(coat), bits(sheen), bits(anisotropy), bits(layerSets0), bits(layerSets1),
            bits(layerTransform0.matrix), bits(layerTransform0.offset), bits(layerTransform1.matrix), bits(layerTransform1.offset),
            bits(layerTransform2.matrix), bits(layerTransform2.offset), bits(layerTransform3.matrix), bits(layerTransform3.offset),
            bits(layerTransform4.matrix), bits(layerTransform4.offset), bits(layerTransform5.matrix), bits(layerTransform5.offset),
            bits(layerTransform6.matrix), bits(layerTransform6.offset), bits(layerTransform7.matrix), bits(layerTransform7.offset),
            bits(layerParameters),
            bits(lightmapScaleOffset), bits(bakedParameters),
        ]
    }
}

/// Shares immutable parameter buffers by value. A material edit selects a new
/// buffer, preserving constants already referenced by in-flight draws.
public struct PBR3DUniforms: Resource {
    public static let binding = 15
    private struct Key: Hashable {
        let words: [SIMD4<UInt32>]

        init(_ value: PBR3DUniform) {
            words = value.bitPatterns
        }
    }
    private struct Entry { let buffer: any UniformBuffer; var frame: Int }
    private struct MaterialEntry {
        // Retain owners until an unused frame, preventing identifier reuse.
        let owner: Material
        let revision: UInt64?
        let buffer: any UniformBuffer
        let key: Key
        var frame: Int
    }
    private var entries: [Key: Entry] = [:]
    private var materialBuffers: [ObjectIdentifier: MaterialEntry] = [:]
    private var frame = 0

    public init() {}

    public mutating func beginFrame() {
        for (key, entry) in entries where entry.frame != frame { entries.removeValue(forKey: key) }
        for (key, entry) in materialBuffers where entry.frame != frame { materialBuffers.removeValue(forKey: key) }
        frame &+= 1
    }

    public mutating func write(material: Material, descriptor: VertexDescriptor, device: RenderDevice) {
        let identity = ObjectIdentifier(material)
        let pbr = material as? PBRMaterial
        let revision = pbr?.uniformRevision
        if var entry = materialBuffers[identity], entry.revision == revision {
            if entry.frame != frame {
                entry.frame = frame
                materialBuffers[identity] = entry
                entries[entry.key] = Entry(buffer: entry.buffer, frame: frame)
            }
            return
        }
        let uniform = PBR3DUniform(material: pbr, descriptor: descriptor)
        let key = Key(uniform)
        if var entry = entries[key] {
            if entry.frame != frame {
                entry.frame = frame
                entries[key] = entry
            }
            materialBuffers[identity] = MaterialEntry(owner: material, revision: revision, buffer: entry.buffer, key: key, frame: frame)
        } else {
            let buffer = device.createUniformBuffer(PBR3DUniform.self, binding: Self.binding)
            buffer.setData(uniform)
            entries[key] = Entry(buffer: buffer, frame: frame)
            materialBuffers[identity] = MaterialEntry(owner: material, revision: revision, buffer: buffer, key: key, frame: frame)
        }
    }

    public func buffer(for material: Material) -> (any UniformBuffer)? {
        guard let entry = materialBuffers[ObjectIdentifier(material)], entry.frame == frame else { return nil }
        return entry.buffer
    }
}
