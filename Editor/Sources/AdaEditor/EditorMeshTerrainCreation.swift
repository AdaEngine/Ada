@_spi(AdaEngine) import AdaEngine
import Foundation
import Math

/// New resources remain private until the caller publishes one scene/history change.
enum EditorMeshTerrainCreation {
    struct File: Sendable {
        let url: URL
        let digest: Data
        let count: Int
    }
    struct Receipt: Sendable { let files: [File] }

    /// Changes resource references while sharing the unchanged compiled document with history.
    @concurrent
    static func forkResources(_ command: EditorTerrainStrokeCommand, from original: URL) async throws -> (URL, Receipt) {
        let cache = try await TerrainRegionCache.open(manifestAt: original.path)
        let previous = await cache.manifest
        guard previous.meshDocumentFileName != nil else { throw Failure.invalidDestination }
        let update = try EditorTerrainResourceWriter.planManifestUpdate(command, manifest: previous)
        let directory = original.deletingLastPathComponent()
        let file = directory.appendingPathComponent("edit-\(UUID().uuidString.lowercased()).aterrain")
        var created: [File] = []
        do {
            if let payload = update.payload { created.append(try stage(payload.data, at: directory.appendingPathComponent(payload.name))) }
            created.append(try stage(update.manifest.encodedData(), at: file))
            try Task.checkCancellation()
            return (file, .init(files: created))
        } catch {
            await discard(.init(files: created))
            throw error
        }
    }

    @concurrent
    static func fork(_ asset: MeshTerrainDocumentAsset, from original: URL) async throws -> (URL, Receipt) {
        _ = try asset.acceptedCompiledProduct()
        let cache = try await TerrainRegionCache.open(manifestAt: original.path)
        let previous = await cache.manifest
        guard previous.meshDocumentFileName != nil else { throw Failure.invalidDestination }
        let name = "mesh-\(UUID().uuidString.lowercased()).atmesh"
        let file = original.deletingLastPathComponent().appendingPathComponent("edit-\(UUID().uuidString.lowercased()).aterrain")
        let manifest = TerrainManifestAsset(spacing: previous.spacing, originX: previous.originX, originZ: previous.originZ,
            heightRegions: [], meshPrototypes: previous.meshPrototypes, materials: previous.materials, meshDocumentFileName: name)
        var created: [File] = []
        do {
            created.append(try stage(asset.encodedData(), at: file.deletingLastPathComponent().appendingPathComponent(name)))
            created.append(try stage(manifest.encodedData(), at: file))
            try Task.checkCancellation()
            return (file, Receipt(files: created))
        } catch {
            await discard(Receipt(files: created))
            throw error
        }
    }

    @concurrent
    static func create(at file: URL, noise: EditorTerrainNoise) async throws -> Receipt {
        try Task.checkCancellation()
        guard file.isFileURL, file.pathExtension.lowercased() == "aterrain" else { throw Failure.invalidDestination }
        var surface = try TriangleSurface.ground(size: [128, 128], cells: 64)
        for index in surface.positions.indices {
            if index.isMultiple(of: 256) { try Task.checkCancellation() }
            let point = surface.positions[index]
            surface.positions[index].y = noise.height(x: point.x, z: point.z)
        }
        surface.normals = []
        let bottom = (surface.positions.map(\.y).min() ?? 0) - 32
        let asset = try await MeshTerrainDocumentAsset(document: .init(sections: [.init(surface: surface, closure: .ground(bottomHeight: bottom))])).compiling()
        _ = try asset.acceptedCompiledProduct()
        let name = "mesh-\(UUID().uuidString.lowercased()).atmesh"
        let manifest = TerrainManifestAsset(heightRegions: [], meshDocumentFileName: name)
        var created: [File] = []
        do {
            created.append(try stage(asset.encodedData(), at: file.deletingLastPathComponent().appendingPathComponent(name)))
            created.append(try stage(manifest.encodedData(), at: file))
            try Task.checkCancellation()
            return Receipt(files: created)
        } catch {
            await discard(Receipt(files: created))
            throw error
        }
    }

    /// Preserve an external replacement instead of removing a file the user has since changed.
    @concurrent
    static func discard(_ receipt: Receipt) async {
        for file in receipt.files.reversed() {
            guard let handle = try? FileHandle(forReadingFrom: file.url) else { continue }
            let data = try? handle.read(upToCount: file.count + 1)
            try? handle.close()
            if let data, data.count == file.count, MeshTerrainContentKey.digest(data) == file.digest {
                try? FileManager.default.removeItem(at: file.url)
            }
        }
    }

    private static func stage(_ data: Data, at destination: URL) throws -> File {
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".ada-mesh-\(UUID().uuidString).tmp")
        try data.write(to: temporary, options: .withoutOverwriting)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let handle = try FileHandle(forWritingTo: temporary)
        do { try handle.synchronize(); try handle.close() }
        catch { try? handle.close(); throw error }
        try Task.checkCancellation()
        // A same-directory move publishes a complete, newly named immutable file;
        // Foundation refuses an existing destination. No old generation is replaced.
        try FileManager.default.moveItem(at: temporary, to: destination)
        return File(url: destination, digest: MeshTerrainContentKey.digest(data), count: data.count)
    }

    enum Failure: Error { case invalidDestination }
}
