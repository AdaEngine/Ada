import AdaAssets
@_spi(Internal) import AdaRender
import Foundation
import Math

extension ModelAsset3D {
    private struct TextureKey: Hashable { let index: Int; let sRGB: Bool }

    static func makeMaterials(_ result: GLTFImportResult) throws -> [Material] {
        var textures: [TextureKey: Texture2D] = [:]
        func texture(_ index: Int?, sRGB: Bool) throws -> Texture2D? {
            guard let index else {
                return nil
            }
            let key = TextureKey(index: index, sRGB: sRGB)
            if let value = textures[key] {
                return value
            }
            guard result.textures.indices.contains(index) else { throw AssetError.message("Invalid texture index") }
            let source = result.textures[index]
            guard result.images.indices.contains(source.source), let data = result.images[source.source].data else {
                throw AssetError.message("Texture \(index) has no image data")
            }
            let image = try Image.decode(from: data)
            let input = source.sampler.flatMap { result.samplers.indices.contains($0) ? result.samplers[$0] : nil } ?? .init()
            let sampler = samplerDescriptor(input)
            let levels = try ImageMipmaps.make(from: image, colorSpace: sRGB ? .sRGB : .linear, includeMipmaps: sampler.mipFilter != .notMipmapped)
            let value = Texture2D(descriptor: TextureDescriptor(
                width: image.width,
                height: image.height,
                pixelFormat: .rgba8,
                textureUsage: [.read],
                textureType: .texture2D,
                mipmapLevel: levels.count,
                image: levels[0],
                debugLabel: "glTF Texture \(index)",
                samplerDescription: sampler
            ))
            for (level, mip) in levels.enumerated() where level > 0 {
                unsafe mip.data.withUnsafeBytes { bytes in
                    guard let base = bytes.baseAddress else {
                        return
                    }
                    unsafe value.replaceRegion(RectInt(x: 0, y: 0, width: mip.width, height: mip.height), mipmapLevel: level, withBytes: base, bytesPerRow: mip.width * 4)
                }
            }
            textures[key] = value
            return value
        }
        let materials: [Material] = try result.materials.map { source in
            let material = PBRMaterial()
            material.baseColorFactor = source.baseColorFactor
            material.metallicFactor = source.metallicFactor
            material.roughnessFactor = source.roughnessFactor
            material.normalScale = source.normalScale
            material.occlusionStrength = source.occlusionStrength
            material.emissiveFactor = source.emissiveFactor
            material.emissiveStrength = source.emissiveStrength
            material.alphaCutoff = source.alphaCutoff
            material.doubleSided = source.doubleSided
            material.textureCoordinates = source.textureCoordinates
            switch source.alphaMode {
            case .opaque: material.alphaMode = .opaque
            case .mask: material.alphaMode = .mask
            case .blend: material.alphaMode = .blend
            }
            material.baseColorTexture = try texture(source.baseColorTextureIndex, sRGB: true)
            material.metallicRoughnessTexture = try texture(source.metallicRoughnessTextureIndex, sRGB: false)
            material.normalTexture = try texture(source.normalTextureIndex, sRGB: false)
            material.occlusionTexture = try texture(source.occlusionTextureIndex, sRGB: false)
            material.emissiveTexture = try texture(source.emissiveTextureIndex, sRGB: true)
            return material
        }
        return materials.isEmpty ? [PBRMaterial()] : materials
    }

    private static func samplerDescriptor(_ source: GLTFImportResult.Sampler) -> SamplerDescriptor {
        func address(_ value: Int) -> SamplerAddressMode {
            switch value {
            case 10497: return .repeat
            case 33648: return .mirroredRepeat
            default: return .clampToEdge
            }
        }
        let minFilter: SamplerMinMagFilter = [9728, 9984, 9986].contains(source.minFilter) ? .nearest : .linear
        let mip: SamplerMipFilter = switch source.minFilter {
        case 9728, 9729: .notMipmapped
        case 9984, 9985: .nearest
        default: .linear
        }
        return SamplerDescriptor(
            minFilter: minFilter,
            magFilter: source.magFilter == 9728 ? .nearest : .linear,
            mipFilter: mip,
            addressModeU: address(source.wrapS),
            addressModeV: address(source.wrapT)
        )
    }
}
