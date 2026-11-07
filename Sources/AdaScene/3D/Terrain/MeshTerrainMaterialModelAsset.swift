@_spi(Internal) import AdaAssets
import AdaRender

/// Reads a portable source dependency without creating GPU geometry for its unused meshes.
struct MeshTerrainMaterialModelAsset: Asset {
    let materials: [Material]
    let bytes: Int
    var assetMetaInfo: AssetMetaInfo?

    static var maximumEncodedBytes: Int? { ModelImportContext.limits?.maximumEncodedBytes }
    static func extensions() -> [String] { ["glb", "gltf"] }

    init(from decoder: any AssetDecoder) async throws {
        var model = try NativeGLTFLoader().load(data: decoder.assetData, allowExternalResources: false)
        materials = try ModelAsset3D.makeMaterialsAccounting(&model)
        guard let usage = model.importFootprint else { throw ModelImportLimitError.invalidLimits }
        bytes = usage.decodedBytes + usage.encodedBytes
    }

    func encodeContents(with _: any AssetEncoder) async throws {
        throw AssetError.message("Mesh Terrain uses original imported materials as read-only dependencies.")
    }
}
