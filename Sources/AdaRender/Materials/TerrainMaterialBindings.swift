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

    public init(maps: TerrainMaterialTextureArrays, layerIDs: Texture2D, weights: Texture2D, parameters: any UniformBuffer, surface: Texture2D? = nil) {
        self.maps = maps
        self.layerIDs = layerIDs
        self.weights = weights
        self.parameters = parameters
        self.surface = surface
    }
}
