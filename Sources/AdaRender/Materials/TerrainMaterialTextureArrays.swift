import Foundation

/// Shared immutable array textures for one source palette generation.
@_spi(Internal)
public final class TerrainMaterialTextureArrays: Sendable {
    public let sourceID: UUID
    public let albedo: Texture2D
    public let normal: Texture2D
    public let orm: Texture2D
    public let blendHeightLayers: Set<UInt16>

    public init(sourceID: UUID, albedo: Texture2D, normal: Texture2D, orm: Texture2D, blendHeightLayers: Set<UInt16> = []) {
        self.sourceID = sourceID
        self.albedo = albedo
        self.normal = normal
        self.orm = orm
        self.blendHeightLayers = blendHeightLayers
    }
}
