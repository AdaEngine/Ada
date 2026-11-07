#if !WASM
    #if TERRAIN_NATIVE_IO_PROBE
        @testable import TerrainNativeIO
    #else
        @testable import AdaAssets
    #endif
    import Foundation
    import Testing

    @Suite("Terrain atomic platform persistence")
    struct TerrainAtomicPlatformTests {
        @Test("Replacing an existing manifest publishes readable new data and preserves the old region")
        func replacesExistingNativeManifest() async throws {
            let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            let directory = root.appendingPathComponent("AdaTerrainAtomic-\(UUID().uuidString)", isDirectory: true).standardizedFileURL
            try #require(directory.deletingLastPathComponent() == root)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let file = directory.appendingPathComponent("world.aterrain")
            let old = TerrainRegionAsset(
                x: 0,
                z: 0,
                tiles: [.init(x: 0, z: 0)],
                pages: [.init(x: 0, z: 0, samples: Array(repeating: 3, count: 4_096))]
            )
            let initial = try await TerrainAssetWriter.save([old], manifest: .init(), destination: file, maximumBytes: 1_024 * 1_024, onProgress: nil)
            let oldRef = try #require(initial.heightRegions.first)
            let changed = TerrainRegionAsset(
                x: 0,
                z: 0,
                tiles: old.tiles,
                pages: [.init(x: 0, z: 0, samples: Array(repeating: 9, count: 4_096))]
            )
            var replacementSucceeded = false
            var failureCode = 0
            do {
                let saved = try await TerrainAssetWriter.save(
                    [changed],
                    manifest: initial,
                    destination: file,
                    maximumBytes: 1_024 * 1_024,
                    onProgress: nil
                )
                let loaded = try TerrainManifestAsset(data: Data(contentsOf: file))
                #expect(loaded.heightRegions == saved.heightRegions)
                let newRef = try #require(loaded.heightRegions.first)
                let newRegion = try TerrainRegionAsset(data: Data(contentsOf: directory.appendingPathComponent(newRef.fileName)))
                #expect(newRegion.pages[0].samples[0] == 9)
                let retained = try TerrainRegionAsset(data: Data(contentsOf: directory.appendingPathComponent(oldRef.fileName)))
                #expect(retained.pages[0].samples[0] == 3)
                replacementSucceeded = true
            } catch {
                failureCode = (error as NSError).code
            }
            #expect(replacementSucceeded, "Atomic terrain manifest replacement must succeed (system error \(failureCode))")
        }
    }
#endif
