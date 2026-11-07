import AdaAssets
import Foundation
import Testing

#if !WASM
    @Suite("Stable volume save generations")
    struct TerrainVolumeSaveReuseTests {
        private func brick(_ x: Int32) -> TerrainVolumeBrickAsset {
            .init(
                x: x,
                y: 0,
                z: 0,
                values: Array(repeating: 2, count: TerrainVolumeBrickAsset.sampleCount),
                materialTags: Array(repeating: TerrainVolumeBrickAsset.unassignedMaterial, count: TerrainVolumeBrickAsset.sampleCount)
            )
        }

        @Test("Unchanged replacement or incremental input retains its document and canonical cache table", arguments: [false, true])
        func unchangedGeneration(replaceAll: Bool) async throws {
            let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            let directory = root.appendingPathComponent("AdaVolumeReuse-\(UUID().uuidString)", isDirectory: true).standardizedFileURL
            try #require(directory.deletingLastPathComponent() == root)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let file = directory.appendingPathComponent("world.aterrain")
            let initial = try await AssetsManager.saveTerrainRegions(
                [],
                manifest: .init(),
                at: file.path,
                volume: .init(document: .init(cellSize: 1), bricks: [brick(0), brick(1)])
            )
            let name = try #require(initial.volumeFileName)
            let baseline = try await AssetsManager.loadFresh(TerrainVolumeDocumentAsset.self, at: directory.appendingPathComponent(name).path)
            let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted(), bytes = try Data(contentsOf: file)
            let mode: TerrainVolumeSaveMode = replaceAll ? .replaceAll : .update(removing: [])
            let next = try await AssetsManager.saveTerrainRegions(
                [],
                manifest: initial,
                at: file.path,
                mode: .update(removing: []),
                volume: .init(document: baseline, bricks: replaceAll ? [brick(1), brick(0)] : [brick(0)], mode: mode)
            )
            #expect(next.volumeFileName == name)
            let nextName = try #require(next.volumeFileName)
            let reopened = try await AssetsManager.loadFresh(TerrainVolumeDocumentAsset.self, at: directory.appendingPathComponent(nextName).path)
            #expect(reopened.bricks == baseline.bricks)
            #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted() == names)
            #expect(try Data(contentsOf: file) == bytes)
        }
    }
#endif
