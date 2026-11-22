import Math

/// CPU copies of the immutable upload, shared with the raster field images.
@_spi(Internal)
public struct TerrainMaterialTracingField: Sendable {
    public let layerIDs: Image
    public let weights: Image
    public let surface: Image?
    public let parameters: [Vector4]

    public init(layerIDs: Image, weights: Image, surface: Image?, parameters: [Vector4]) {
        self.layerIDs = layerIDs
        self.weights = weights
        self.surface = surface
        self.parameters = parameters
    }
}

/// Immutable full-resolution material fields retained by one generated terrain tile.
/// Palette indices use normalized RGBA8 channels; shader reads always use texelFetch.
@_spi(Internal)
public final class TerrainMaterialBindings: Sendable {
    public static let binding = 51
    public let maps: TerrainMaterialTextureArrays
    public let layerIDs: Texture2D
    public let weights: Texture2D
    public let surface: Texture2D?
    public let parameters: any UniformBuffer
    public let tracingField: TerrainMaterialTracingField?

    public init(
        maps: TerrainMaterialTextureArrays,
        layerIDs: Texture2D,
        weights: Texture2D,
        parameters: any UniformBuffer,
        surface: Texture2D? = nil,
        tracingField: TerrainMaterialTracingField? = nil
    ) {
        self.maps = maps
        self.layerIDs = layerIDs
        self.weights = weights
        self.parameters = parameters
        self.surface = surface
        self.tracingField = tracingField
    }
}
