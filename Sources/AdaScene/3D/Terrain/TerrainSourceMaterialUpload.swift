import AdaAssets
@_spi(Internal) import AdaRender
import Foundation
import Math

enum TerrainSourceMaterialUpload {
    static func inverseSpacing(_ spacing: Float) throws -> Float {
        let inverse = 1 / spacing
        guard spacing.isFinite, spacing > 0, inverse.isFinite else {
            throw TerrainSourceError.resourceLoadingFailed("Terrain material fields require finite inverse sample spacing")
        }
        return inverse
    }

    /// Uses the existing per-tile upload allowance. LOD-only publication retains this immutable bundle.
    static func make(
        descriptor: MeshDescriptor,
        coordinate: TerrainTileCoordinate,
        storage: TerrainHeightStorage,
        palette: TerrainMaterialPalette,
        maps: TerrainMaterialTextureArrays,
        color: Vector4,
        device: RenderDevice,
        usesTriangleField: Bool = false
    ) throws -> PBRMaterial {
        try palette.validate()
        let gridScale = usesTriangleField ? 0 : try inverseSpacing(storage.spacing)
        let positions = descriptor.positions.elements
        let volume = usesTriangleField || descriptor[MeshDescriptor.textureCoordinates1] != nil
        let cells = storage.tileCellCounts(at: coordinate)
        guard volume || cells != nil, let first = positions.first,
            let ids = descriptor[TerrainSourceMaterials.layerIDs]?.elements,
            let weights = descriptor[TerrainSourceMaterials.weights]?.elements else { throw TerrainSourceError.changedDuringBuild }
        let triangles = (usesTriangleField ? descriptor.indicies.count : positions.count) / 3
        let columns = max(1, Int(ceil(Double(triangles).squareRoot())))
        let fieldWidth = volume ? columns * 2 : (cells?.x ?? 0) + 1
        let fieldHeight = volume ? max(1, (triangles + columns - 1) / columns) * 2 : (cells?.z ?? 0) + 1
        guard ids.count == fieldWidth * fieldHeight, weights.count == ids.count,
            volume || positions.count == ids.count else { throw TerrainSourceError.changedDuringBuild }
        let maximumCoordinate = positions.reduce(Double(0)) { max($0, abs(Double($1.x)), abs(Double($1.z))) }
        let maximumShaderCoordinate = Double(Float.greatestFiniteMagnitude) / 16
        let minimumShaderScale = Double(Float.leastNormalMagnitude)
        let layers = palette.layers.sorted { $0.id < $1.id }
        let slots = Dictionary(uniqueKeysWithValues: layers.enumerated().map { ($0.element.id, UInt8($0.offset)) })
        var idBytes = Data(count: ids.count * 4), weightBytes = Data(count: ids.count * 4)
        let maximumHeight = positions.reduce(Double(0)) { max($0, abs(Double($1.y))) }
        for index in ids.indices {
            for channel in 0..<4 {
                let id = ids[index][channel]
                guard id.isFinite, id >= 0, id <= Float(UInt16.max), id.rounded() == id else { throw TerrainSourceError.changedDuringBuild }
                let weight = weights[index][channel]
                guard weight.isFinite, (0...1).contains(weight), weight == 0 || slots[UInt16(id)] != nil else { throw TerrainSourceError.changedDuringBuild }
                idBytes[index * 4 + channel] = slots[UInt16(id)] ?? 0
                weightBytes[index * 4 + channel] = UInt8((weight * 255).rounded())
            }
        }
        func field(_ bytes: Data) -> Texture2D {
            var texture = TextureDescriptor(
                width: fieldWidth,
                height: fieldHeight,
                pixelFormat: .rgba8,
                textureUsage: [.read],
                textureType: .texture2D,
                image: Image(width: fieldWidth, height: fieldHeight, data: bytes)
            )
            texture.allowsBindingCache = false
            return Texture2D(descriptor: texture)
        }
        let idsTexture = field(idBytes)
        let weightsTexture = field(weightBytes)
        let surfaceTexture: Texture2D?
        let tintRows = descriptor[TerrainSourceMaterials.surfaceTint]?.elements
        let maskRows = descriptor[TerrainSourceMaterials.roughnessMask]?.elements
        if tintRows != nil || maskRows != nil {
            guard let tintRows, let maskRows, tintRows.count == ids.count, maskRows.count == ids.count else { throw TerrainSourceError.changedDuringBuild }
            var bytes = Data(count: ids.count * 8)
            for index in ids.indices {
                for channel in 0..<4 {
                    let value = tintRows[index][channel]
                    guard value.isFinite, (0...1).contains(value) else { throw TerrainSourceError.changedDuringBuild }
                    bytes[index * 4 + channel] = UInt8((value * 255).rounded())
                }
                let mask = maskRows[index]
                guard mask.isFinite, (0...1).contains(mask) else { throw TerrainSourceError.changedDuringBuild }
                bytes[ids.count * 4 + index * 4] = UInt8((mask * 255).rounded())
            }
            var texture = TextureDescriptor(
                width: fieldWidth,
                height: fieldHeight * 2,
                pixelFormat: .rgba8,
                textureUsage: [.read],
                textureType: .texture2D,
                image: Image(width: fieldWidth, height: fieldHeight * 2, data: bytes)
            )
            texture.allowsBindingCache = false
            surfaceTexture = Texture2D(descriptor: texture)
        } else { surfaceTexture = nil }
        // Exact std140 layout: one grid vector, then 32 tints, surface vectors, variation controls and variation scales.
        var parameters = [Vector4](repeating: .zero, count: 129)
        parameters[0] = volume ? [0, 0, -1, Float(layers.count)] : [first.x, first.z, gridScale, Float(layers.count)]
        for (index, layer) in layers.enumerated() {
            parameters[1 + index] = layer.tint
            parameters[33 + index] = [layer.roughness, layer.metallic, layer.scale, layer.projection == .triplanar ? 1 : 0]
            let variation = layer.variation
            var flags: UInt32 = 0
            if variation.isEnabled {
                flags = 16
                if variation.flipU { flags |= 1 }
                if variation.flipV { flags |= 2 }
                if variation.quarterTurns { flags |= 4 }
                if variation.randomOffset { flags |= 8 }
            }
            let seed = UInt32(truncatingIfNeeded: variation.seed) ^ (UInt32(truncatingIfNeeded: variation.seed >> 32) &* 0x9E37_79B9) ^ (UInt32(layer.id) &* 0x85EB_CA6B)
            // Double preflight avoids creating infinities (or flushed subnormals) in shader divisions and hash conversion.
            let projectionCoordinate = layer.projection == .triplanar ? max(maximumCoordinate, maximumHeight) : maximumCoordinate
            let unresolvedLayer = Double(layer.scale) < minimumShaderScale || projectionCoordinate / Double(layer.scale) > maximumShaderCoordinate
            let unresolvedMacro = Double(variation.macroScale) < minimumShaderScale || maximumCoordinate / Double(variation.macroScale) > maximumShaderCoordinate
            let macroStrength = variation.isEnabled && !unresolvedMacro ? variation.macroStrength : 0
            parameters[65 + index] = [Float(flags), Float(seed & 0xFFFF), Float(seed >> 16), macroStrength]
            parameters[97 + index] = [variation.cellScale, variation.macroScale, unresolvedLayer ? 1 : 0, maps.blendHeightLayers.contains(layer.id) ? 1 : 0]
        }
        let buffer = device.createUniformBuffer(Vector4.self, count: parameters.count, binding: TerrainMaterialBindings.binding)
        buffer.setElements(&parameters)
        let material = PBRMaterial()
        material.baseColorFactor = color
        material.terrainBindings = TerrainMaterialBindings(maps: maps, layerIDs: idsTexture, weights: weightsTexture, parameters: buffer, surface: surfaceTexture)
        return material
    }
}
