import AdaAssets
import Foundation

// Import metadata is immutable. GPU lifetime and synchronization follow the base Texture contract.
/// A cube imported from a six-face horizontal strip (+X, -X, +Y, -Y, +Z, -Z).
/// Cube textures require a cube-sampling shader; existing 2D sprite/skybox slots accept panoramas instead.
public final class TextureCube: Texture, @unchecked Sendable {
    public let faceSize: Int
    public let mipmapLevelCount: Int

    public init(image: Image, settings: TextureImportSettings) throws {
        var settings = settings
        settings.dimension = .cube
        let prepared: ImportedTextureData
        if let imported = image.importedTextureData, imported.settings == settings {
            prepared = imported
        } else {
            prepared = try settings.prepare(image)
        }
        let descriptor = prepared.descriptor
        let device = unsafe RenderEngine.shared.createLocalRenderDevice()
        faceSize = descriptor.width
        mipmapLevelCount = descriptor.mipmapLevel
        super.init(
            gpuTexture: device.createTexture(from: descriptor),
            sampler: device.createSampler(from: descriptor.samplerDescription),
            textureType: .textureCube
        )
        assetMetaInfo = image.assetMetaInfo
    }

    public required convenience init(from decoder: any AssetDecoder) async throws {
        let image = try await Image(from: decoder)
        let settings = image.importedTextureData?.settings ?? TextureImportSettings()
        try self.init(image: image, settings: settings)
    }

    override public func encodeContents(with encoder: any AssetEncoder) async throws {
        throw AssetDecodingError.decodingProblem("Save the source strip and its .texture.json settings to persist a cube texture.")
    }
}
