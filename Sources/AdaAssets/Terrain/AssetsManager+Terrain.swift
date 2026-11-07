import AdaUtils
import Foundation

extension AssetsManager {
    #if !WASM
        @AssetActor private static var activeTerrainWrites: Set<String> = []
    #endif

    /// Saves height regions, committing the manifest only after all changed region files are ready.
    /// The default replaces the complete set. Incremental mode retains untouched references and checks
    /// the supplied baseline against disk before staging and committing. Old generations remain readable.
    /// Optional volume changes stage their bricks and operation document in the same transaction.
    /// A Mesh Terrain manifest cannot be replaced by this height and volume writer.
    /// The byte budget covers supplied encoded regions/bricks and resulting metadata.
    @AssetActor
    public static func saveTerrainRegions(
        _ regions: [TerrainRegionAsset],
        manifest: TerrainManifestAsset,
        at path: String,
        mode: TerrainRegionSaveMode = .replaceAll,
        volume: TerrainVolumeSave? = nil,
        maximumStagedBytes: Int = 128 * 1_024 * 1_024,
        onProgress: (@Sendable (Int, Int) async -> Void)? = nil
    ) async throws -> TerrainManifestAsset {
        #if WASM
            throw AssetError.message("Terrain asset saving requires a native writable project directory")
        #else
            var destination = try resolveWritableAssetPath(at: path).url
            var storedPath = path
            if destination.pathExtension.isEmpty {
                destination.appendPathExtension("aterrain")
                let componentStart = path.lastIndex(where: { $0 == "/" || $0 == "\\" }).map { path.index(after: $0) } ?? path.startIndex
                let queryStart = path[componentStart...].firstIndex(of: "#") ?? path.endIndex
                storedPath.insert(contentsOf: ".aterrain", at: queryStart)
            }
            guard destination.isFileURL, destination.pathExtension.lowercased() == "aterrain" else {
                throw AssetError.message("Terrain manifest destination must be a local .aterrain file")
            }
            let directory = destination.deletingLastPathComponent().resolvingSymlinksInPath()
            let key = directory.appendingPathComponent(destination.lastPathComponent).standardizedFileURL.path
                .precomposedStringWithCanonicalMapping.lowercased()
            guard activeTerrainWrites.insert(key).inserted else { throw TerrainSaveError.saveInProgress }
            defer { activeTerrainWrites.remove(key) }
            var updated = try await TerrainAssetWriter.save(
                regions,
                manifest: manifest,
                destination: destination,
                mode: mode,
                volume: volume,
                maximumBytes: maximumStagedBytes,
                onProgress: onProgress
            )
            updated.assetMetaInfo = AssetMetaInfo(assetId: .init(), assetPath: storedPath, assetName: destination.lastPathComponent, bundlePath: nil)
            return updated
        #endif
    }
}
