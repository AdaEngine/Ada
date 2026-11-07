@_spi(Internal) import AdaRender

/// Private publication cursor; no tile can sample these arrays until every slice and mip is initialized.
struct TerrainMaterialUpload: Sendable {
    static let maximumBytesPerFrame = 1_048_576
    private let maps: TerrainPreparedMaterialMaps
    private let textures: [Texture2D]
    private var family = 0
    private var slice = 0
    private var level = 0

    init(maps: TerrainPreparedMaterialMaps) throws {
        self.maps = maps
        textures = try (0..<3).map { Texture2D(descriptor: try maps.arrayDescriptor(family: $0)) }
    }

    mutating func advance(metrics: TerrainMaterialUploadMetrics?) throws -> TerrainMaterialTextureArrays? {
        var remaining = Self.maximumBytesPerFrame
        while family < textures.count {
            let image = maps.families[family][slice][level]
            guard !image.data.isEmpty, image.data.count <= Self.maximumBytesPerFrame else { throw TerrainSourceError.meshBudgetExceeded }
            if image.data.count > remaining {
                return nil
            }
            try textures[family].uploadSubresource(.init(image: image, mipLevel: level, slice: slice))
            metrics?.record(bytes: image.data.count)
            remaining -= image.data.count
            level += 1
            if level == maps.families[family][slice].count {
                level = 0; slice += 1
                if slice == maps.families[family].count { slice = 0; family += 1 }
            }
        }
        return TerrainMaterialTextureArrays(sourceID: maps.id, albedo: textures[0], normal: textures[1], orm: textures[2], blendHeightLayers: maps.blendHeightLayers)
    }
}
