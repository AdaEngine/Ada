@_spi(AdaEngine) import AdaEngine
import Foundation

/// Writes only private manifests and immutable payloads. The scene publishes their URI after runtime validation.
enum EditorTerrainResourceWriter {
    @concurrent
    static func apply(_ command: EditorTerrainStrokeCommand, to file: URL, manifest: TerrainManifestAsset) async throws {
        try Task.checkCancellation()
        switch command {
        case let .volume(operation):
            let cache = try await TerrainRegionCache.open(manifestAt: file.path)
            let previous = try await cache.loadVolumeResources()?.document
            let document = TerrainVolumeDocumentAsset(
                cellSize: previous?.cellSize ?? manifest.spacing,
                origin: previous?.origin ?? [manifest.originX, 0, manifest.originZ],
                operations: (previous?.operations ?? []) + [operation]
            )
            _ = try await AssetsManager.saveTerrainRegions([], manifest: manifest, at: file.path, mode: .update(removing: []), volume: .init(document: document, bricks: []))
        case .materials, .mesh, .texture:
            let update = try planManifestUpdate(command, manifest: manifest)
            if let payload = update.payload {
                try payload.data.write(to: file.deletingLastPathComponent().appendingPathComponent(payload.name), options: .withoutOverwriting)
            }
            try update.manifest.encodedData().write(to: file, options: .atomic)
        case let .region(coordinate):
            guard manifest.heightRegions.count <= 128 else { throw Failure.modelTooLarge }
            let cache = try await TerrainRegionCache.open(manifestAt: file.path)
            var regions: [TerrainRegionAsset] = []
            for reference in manifest.heightRegions {
                if let region = try await cache.loadRegion(at: .init(x: Int(reference.x), z: Int(reference.z))) { regions.append(region) }
            }
            let storage = try TerrainHeightStorage(regions: regions, spacing: manifest.spacing, origin: [manifest.originX, manifest.originZ])
            var target = coordinate
            while try storage.regionAsset(at: target)?.tiles.count == 16 { target = .init(x: target.x + 1, z: target.z) }
            _ = try storage.allocateRegion(at: target)
            guard let region = try storage.regionAsset(at: target) else { throw Failure.emptyRegion }
            _ = try await AssetsManager.saveTerrainRegions([region], manifest: manifest, at: file.path, mode: .update(removing: []))
        case let .generate(settings): try await EditorTerrainNoise.generate(settings, at: file, manifest: manifest)
        default: throw Failure.unsupported
        }
    }

    struct ManifestUpdate: Sendable {
        struct Payload: Sendable {
            let name: String
            let data: Data
        }
        let manifest: TerrainManifestAsset
        let payload: Payload?
    }

    static func planManifestUpdate(_ command: EditorTerrainStrokeCommand, manifest: TerrainManifestAsset) throws -> ManifestUpdate {
        try Task.checkCancellation()
        switch command {
        case let .materials(palette):
            return .init(manifest: replacing(manifest, materials: palette), payload: nil)
        case let .mesh(source):
            guard ["glb", "vox"].contains(source.pathExtension.lowercased()) else { throw Failure.selfContainedModel }
            let metadata = try source.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
            guard metadata.isRegularFile == true, metadata.isSymbolicLink != true,
                let count = metadata.fileSize, count > 0, count <= 32 * 1_024 * 1_024 else { throw Failure.modelTooLarge }
            let used = Set(manifest.meshPrototypes.map(\.id))
            guard let id = (UInt16(0)...UInt16(255)).first(where: { !used.contains($0) }) else { throw Failure.paletteFull }
            let name = "mesh-\(UUID().uuidString.lowercased()).\(source.pathExtension.lowercased())"
            let data = try boundedData(source, count: count, maximum: 32 * 1_024 * 1_024)
            if source.pathExtension.lowercased() == "glb" { try EditorModelAssetImporter.requireSelfContainedGLB(data) }
            let next = replacing(manifest, prototypes: manifest.meshPrototypes + [.init(id: id, assetPath: name)])
            return .init(manifest: next, payload: .init(name: name, data: data))
        case let .texture(source, layerID):
            guard ["png", "jpg", "jpeg"].contains(source.pathExtension.lowercased()) else { throw Failure.unsupported }
            let palette = manifest.materials ?? .init(layers: [], fallbackLayerID: layerID)
            guard palette.layers.count < 32 else { throw Failure.paletteFull }
            let metadata = try source.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
            guard metadata.isRegularFile == true, metadata.isSymbolicLink != true,
                let count = metadata.fileSize, count > 0, count <= 16 * 1_024 * 1_024 else { throw Failure.modelTooLarge }
            let name = "texture-\(UUID().uuidString.lowercased()).\(source.pathExtension.lowercased())"
            let data = try boundedData(source, count: count, maximum: 16 * 1_024 * 1_024)
            var layers = palette.layers.map { layer in
                TerrainLayerReference(
                    id: layer.id,
                    name: layer.name,
                    albedoPath: layer.id == layerID ? name : layer.albedoPath,
                    normalPath: layer.normalPath,
                    ormPath: layer.ormPath,
                    blendHeightPath: layer.blendHeightPath,
                    scale: layer.scale,
                    tint: layer.tint,
                    roughness: layer.roughness,
                    metallic: layer.metallic,
                    projection: layer.projection,
                    variation: layer.variation
                )
            }
            if !layers.contains(where: { $0.id == layerID }) {
                layers.append(.init(
                    id: layerID,
                    name: source.deletingPathExtension().lastPathComponent,
                    albedoPath: name,
                    scale: 4,
                    projection: .triplanar,
                    variation: .init(isEnabled: true)
                ))
            }
            let next = replacing(manifest, materials: .init(layers: layers, fallbackLayerID: palette.fallbackLayerID,
                interiorLayerID: palette.interiorLayerID, rules: palette.rules))
            return .init(manifest: next, payload: .init(name: name, data: data))
        default: throw Failure.unsupported
        }
    }

    private static func boundedData(_ source: URL, count: Int, maximum: Int) throws -> Data {
        // Bound the read even if an external file grows after the metadata check.
        let handle = try FileHandle(forReadingFrom: source)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maximum + 1) ?? Data()
        guard data.count == count, data.count <= maximum else { throw Failure.modelTooLarge }
        return data
    }

    private static func replacing(_ source: TerrainManifestAsset, materials: TerrainMaterialPalette? = nil, prototypes: [TerrainMeshPrototypeReference]? = nil) -> TerrainManifestAsset {
        .init(
            spacing: source.spacing,
            originX: source.originX,
            originZ: source.originZ,
            heightRegions: source.heightRegions,
            meshPrototypes: prototypes ?? source.meshPrototypes,
            materials: materials ?? source.materials,
            volumeFileName: source.volumeFileName,
            meshDocumentFileName: source.meshDocumentFileName
        )
    }

    enum Failure: Error { case selfContainedModel, modelTooLarge, paletteFull, emptyRegion, unsupported }
}
