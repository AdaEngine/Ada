import AdaAssets
import Foundation
import Testing

@Suite("Retained terrain volume publication integrity")
struct TerrainVolumeSaveIntegrityTests {
    #if !WASM
        private func brick(_ x: Int32, value: Float = -1) -> TerrainVolumeBrickAsset {
            .init(
                x: x,
                y: 0,
                z: 0,
                values: Array(repeating: value, count: TerrainVolumeBrickAsset.sampleCount),
                materialTags: Array(repeating: 7, count: TerrainVolumeBrickAsset.sampleCount)
            )
        }

        private func fixture(operationLayer: Bool = false) async throws -> (URL, TerrainManifestAsset, TerrainVolumeDocumentAsset) {
            let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            let folder = root.appendingPathComponent("TerrainVolumeIntegrity-" + UUID().uuidString).standardizedFileURL
            try #require(folder.deletingLastPathComponent() == root)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent("world.aterrain")
            let operations: [TerrainVolumeOperation] = operationLayer ? [.init(operation: .union, operand: .primitive(.sphere(radius: 1)), layerID: 7)] : []
            let manifest = try await AssetsManager.saveTerrainRegions(
                [],
                manifest: .init(materials: .init(layers: [.init(id: 7, name: "Rock")], fallbackLayerID: 7)),
                at: file.path,
                volume: .init(document: .init(cellSize: 1, operations: operations), bricks: [brick(0), brick(1)])
            )
            let document = try await AssetsManager.loadFresh(TerrainVolumeDocumentAsset.self, at: folder.appendingPathComponent(try #require(manifest.volumeFileName)).path)
            return (file, manifest, document)
        }

        @Test("Volume-only incremental saves reject stale roots before staging and immediately before publication", arguments: [false, true])
        func staleRoot(duringProgress: Bool) async throws {
            let (file, baseline, document) = try await fixture()
            let folder = file.deletingLastPathComponent()
            defer { try? FileManager.default.removeItem(at: folder) }
            let newer = try TerrainManifestAsset(
                spacing: 2,
                heightRegions: baseline.heightRegions,
                materials: baseline.materials,
                volumeFileName: baseline.volumeFileName
            ).encodedData()
            if !duringProgress { try newer.write(to: file) }
            let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
            let result = try? await AssetsManager.saveTerrainRegions(
                [],
                manifest: baseline,
                at: file.path,
                volume: .init(document: document, bricks: [brick(0, value: -2)], mode: .update(removing: [])),
                onProgress: { _, _ in if duringProgress { try? newer.write(to: file) } }
            )
            #expect(result == nil, "A volume update requires the original published manifest even when heights use replaceAll")
            #expect(try Data(contentsOf: file) == newer)
            #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted() == names)
        }

        @Test("Untouched missing, truncated and wrongly addressed cached bricks prevent publication", arguments: [0, 1, 2])
        func damagedRetained(kind: Int) async throws {
            let (file, baseline, document) = try await fixture()
            let folder = file.deletingLastPathComponent()
            defer { try? FileManager.default.removeItem(at: folder) }
            let retained = try #require(document.bricks.first { $0.x == 1 })
            let payload = folder.appendingPathComponent(retained.fileName)
            if kind == 0 {
                try FileManager.default.removeItem(at: payload)
            } else if kind == 1 {
                try Data([1, 2, 3]).write(to: payload)
            } else {
                try brick(2).encodedData().write(to: payload)
            }
            let bytes = try Data(contentsOf: file), names = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
            let result = try? await AssetsManager.saveTerrainRegions(
                [],
                manifest: baseline,
                at: file.path,
                volume: .init(document: document, bricks: [brick(0, value: -2)], mode: .update(removing: []))
            )
            #expect(result == nil, "An incremental generation must retain only complete correctly addressed bricks")
            #expect(try Data(contentsOf: file) == bytes)
            #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted() == names)
        }

        @Test("Preserved volume operations and cached material tags must exist in the resulting palette", arguments: [false, true])
        func removedPalette(operationLayer: Bool) async throws {
            let (file, baseline, _) = try await fixture(operationLayer: operationLayer)
            let folder = file.deletingLastPathComponent()
            defer { try? FileManager.default.removeItem(at: folder) }
            let bytes = try Data(contentsOf: file), names = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
            let removed = TerrainManifestAsset(volumeFileName: baseline.volumeFileName)
            let result = try? await AssetsManager.saveTerrainRegions([], manifest: removed, at: file.path)
            #expect(result == nil, "Height-only saving must validate retained operation and cached material references")
            #expect(try Data(contentsOf: file) == bytes)
            #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted() == names)
        }
    #endif
}
