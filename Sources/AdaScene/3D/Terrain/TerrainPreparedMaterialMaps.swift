import AdaAssets
@_spi(Internal) import AdaRender
import AdaUtils
import Foundation
import Math

/// CPU preparation is scoped to one immutable manifest, independent of tile residency and render LOD.
final class TerrainPreparedMaterialMaps: Sendable {
    let id = UUID()
    let families: [[[Image]]]
    let chargedBytes: Int
    let warnings: [String]
    let blendHeightLayers: Set<UInt16>

    init(families: [[[Image]]], chargedBytes: Int, warnings: [String], blendHeightLayers: Set<UInt16>) {
        self.families = families
        self.chargedBytes = chargedBytes
        self.warnings = warnings
        self.blendHeightLayers = blendHeightLayers
    }

    static func prepare(palette: TerrainMaterialPalette, cache: TerrainRegionCache, maximumBytes: Int) async throws -> TerrainPreparedMaterialMaps {
        let layers = palette.layers.sorted { $0.id < $1.id }
        var images: [[Image?]] = Array(repeating: [], count: 4)
        var encodedRemaining = 64 * 1_024 * 1_024
        var decodedRemaining = min(128 * 1_024 * 1_024, maximumBytes)
        var warnings: [String] = []
        var preparationBytes = 0
        for family in 0..<4 {
            for layer in layers {
                try Task.checkCancellation()
                let path = [layer.albedoPath, layer.normalPath, layer.ormPath, layer.blendHeightPath][family]
                guard let path else { images[family].append(nil); continue }
                do {
                    let encoded = try await cache.loadMaterialImage(path, encodedLimit: min(encodedRemaining, maximumBytes - preparationBytes))
                    encodedRemaining -= encoded.data.count
                    preparationBytes += encoded.data.count
                    let required = try Image.decodedImportByteCount(from: encoded.data)
                    guard required > 0, required <= decodedRemaining / 6, required <= (maximumBytes - preparationBytes) / 6 else { throw ModelImportLimitError.decodedBudgetExceeded }
                    decodedRemaining -= required * 6
                    preparationBytes += required * 6
                    let image = try ModelImportContext.$limits.withValue(.init(maximumEncodedBytes: encoded.data.count, maximumDecodedBytes: required)) {
                        try Image.decode(from: encoded.data)
                    }
                    images[family].append(image)
                } catch is CancellationError { throw CancellationError() } catch {
                    warnings.append("Terrain layer \(layer.id), \(path): \(error.localizedDescription)")
                    images[family].append(nil)
                }
            }
        }
        var families: [[[Image]]] = []
        var chargedBytes = preparationBytes
        for family in 0..<3 {
            let inputs = family == 2 ? images[2] + images[3] : images[family]
            let dimension = min(256, inputs.compactMap { $0 }.map { max($0.width, $0.height) }.max() ?? 1)
            // Full mip chain is < 2 * base. Six copies cover normalization, staging and both retained CPU/GPU generations.
            let charge = dimension * dimension * 4 * layers.count * 12
            guard charge <= maximumBytes - chargedBytes else { throw TerrainSourceError.meshBudgetExceeded }
            chargedBytes += charge
            var slices: [[Image]] = []
            for (index, image) in images[family].enumerated() {
                try Task.checkCancellation()
                let base: Image
                if let image {
                    base = try resize(image, dimension: dimension)
                } else {
                    let color: Color = family == 1 ? Color(0.5, 0.5, 1, 1) : .white
                    base = Image(width: dimension, height: dimension, color: color)
                }
                // Height uses the same coordinates and linear mip filtering as ORM, without another binding.
                let packed: Image
                if family == 2 {
                    let height = try images[3][index].map { try resize($0, dimension: dimension) }
                    var bytes = base.data
                    for pixel in 0..<(dimension * dimension) { bytes[pixel * 4 + 3] = height?.data[pixel * 4] ?? 128 }
                    packed = Image(width: dimension, height: dimension, data: bytes)
                } else { packed = base }
                slices.append(try ImageMipmaps.make(from: packed, colorSpace: family == 0 ? .sRGB : .linear, normalMap: family == 1))
            }
            families.append(slices)
        }
        let heightLayers = Set(layers.enumerated().compactMap { images[3][$0.offset] != nil ? $0.element.id : nil })
        return TerrainPreparedMaterialMaps(families: families, chargedBytes: chargedBytes, warnings: warnings, blendHeightLayers: heightLayers)
    }

    private static func resize(_ image: Image, dimension: Int) throws -> Image {
        guard let rgba = try ImageMipmaps.make(from: image, colorSpace: .linear, includeMipmaps: false).first else { throw ImageMipmaps.Error.invalidSource }
        if rgba.width == dimension, rgba.height == dimension {
            return rgba
        }
        var bytes = Data(count: dimension * dimension * 4)
        for y in 0..<dimension {
            try Task.checkCancellation()
            let sourceY = min(rgba.height - 1, y * rgba.height / dimension)
            for x in 0..<dimension {
                let sourceX = min(rgba.width - 1, x * rgba.width / dimension)
                for channel in 0..<4 { bytes[(y * dimension + x) * 4 + channel] = rgba.data[(sourceY * rgba.width + sourceX) * 4 + channel] }
            }
        }
        return Image(width: dimension, height: dimension, data: bytes)
    }

    func arrayDescriptor(family: Int) throws -> TextureDescriptor {
        guard families.count == 3, families.indices.contains(family),
            (1...32).contains(families[family].count), let first = families[family].first?.first,
            (1...256).contains(first.width), first.height == first.width, (1...9).contains(families[family][0].count)
        else { throw TerrainSourceError.changedDuringBuild }
        var descriptor = TextureDescriptor(
            width: first.width,
            height: first.height,
            pixelFormat: .rgba8,
            textureUsage: [.read],
            textureType: .texture2DArray,
            samplerDescription: .init(minFilter: .linear, magFilter: .linear, mipFilter: .linear, addressModeU: .repeat, addressModeV: .repeat)
        )
        descriptor.allowsBindingCache = false
        descriptor.arrayLength = families[family].count
        descriptor.mipmapLevel = families[family][0].count
        return descriptor
    }
}

struct TerrainMaterialImageAsset: Asset {
    static func extensions() -> [String] { [] }
    static var maximumEncodedBytes: Int? { ModelImportContext.limits?.maximumEncodedBytes }
    let data: Data
    var assetMetaInfo: AssetMetaInfo?

    init(from decoder: any AssetDecoder) async throws {
        data = decoder.assetData
    }

    func encodeContents(with encoder: any AssetEncoder) async throws {
        try encoder.encode(data)
    }
}
