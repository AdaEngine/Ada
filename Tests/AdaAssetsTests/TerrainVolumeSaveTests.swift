import AdaAssets
import Foundation
import Math
import Testing

@Suite("Atomic height and volume resource publication")
struct TerrainVolumeSaveTests {
    @Test("Manifest version four retains a portable volume document while legacy output remains compatible")
    func manifestReference() throws {
        let source = TerrainManifestAsset(volumeFileName: "volume-cache.atvolume"), bytes = try source.encodedData()
        let decoded = try TerrainManifestAsset(data: bytes)
        #expect(decoded.volumeFileName == source.volumeFileName)
        let json = try #require(try JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        #expect(json["version"] as? Int == 4)
        #expect(!(try TerrainManifestAsset().encodedData()).contains(Data("volumeFileName".utf8)))
    }

    @Test("Unsafe volume document paths and old-version volume fields are rejected")
    func invalidReferences() throws {
        for name in ["../a.atvolume", "/a.atvolume", "folder/a.atvolume", "a.atregion", "a:bad.atvolume"] {
            #expect(throws: TerrainManifestError.self) { try TerrainManifestAsset(volumeFileName: name).validate() }
        }
        let old = Data(#"{"version":3,"spacing":1,"originX":0,"originZ":0,"heightRegions":[],"volumeFileName":"a.atvolume"}"#.utf8)
        #expect(throws: TerrainManifestError.self) { try TerrainManifestAsset(data: old) }
    }

    #if !WASM
        private func directory() throws -> URL {
            let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            let result = root.appendingPathComponent("AdaVolumeSave-\(UUID().uuidString)", isDirectory: true).standardizedFileURL
            try #require(result.deletingLastPathComponent() == root)
            try FileManager.default.createDirectory(at: result, withIntermediateDirectories: true)
            return result
        }

        private func brick(x: Int32, value: Float = -1) -> TerrainVolumeBrickAsset {
            .init(
                x: x,
                y: 0,
                z: 0,
                values: Array(repeating: value, count: TerrainVolumeBrickAsset.sampleCount),
                materialTags: Array(repeating: 7, count: TerrainVolumeBrickAsset.sampleCount)
            )
        }

        private func document(bricks: [TerrainVolumeBrickReference] = []) -> TerrainVolumeDocumentAsset {
            .init(cellSize: 1, operations: [.init(operation: .subtract, operand: .primitive(.sphere(radius: 2)))], bricks: bricks)
        }

        private func saved(at file: URL) async throws -> TerrainManifestAsset {
            try await AssetsManager.saveTerrainRegions(
                [.init(x: 0, z: 0, tiles: [.init(x: 0, z: 0)], pages: [])],
                manifest: .init(materials: .init(layers: [.init(id: 7, name: "Stone")], fallbackLayerID: 7)),
                at: file.path,
                volume: .init(document: document(), bricks: [brick(x: 0), brick(x: 1)])
            )
        }

        @Test("The manifest publishes loadable height, ordered operations and exact independent brick generations")
        func publishesCompleteSet() async throws {
            let directory = try directory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let file = directory.appendingPathComponent("world.aterrain"), first = try await saved(at: file)
            let name = try #require(first.volumeFileName, "A volume save must publish its document reference")
            let reopened = try await AssetsManager.loadFresh(TerrainManifestAsset.self, at: file.path)
            #expect(reopened.volumeFileName == name && reopened.heightRegions.count == 1)
            let volume = try await AssetsManager.loadFresh(TerrainVolumeDocumentAsset.self, at: directory.appendingPathComponent(name).path)
            #expect(volume.operations.count == 1 && volume.operations[0].operation == .subtract)
            #expect(volume.bricks.count == 2)
            for ref in volume.bricks {
                let payload = try await AssetsManager.loadFresh(TerrainVolumeBrickAsset.self, at: directory.appendingPathComponent(ref.fileName).path)
                #expect(payload.x == ref.x && payload.y == ref.y && payload.z == ref.z)
                #expect(payload.values == brick(x: ref.x).values && payload.materialTags == brick(x: ref.x).materialTags)
            }
        }

        @Test("Incremental saves retain untouched bricks and height-only saves preserve the volume generation")
        func incrementalAndHeightOnly() async throws {
            let directory = try directory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let file = directory.appendingPathComponent("world.aterrain"), initial = try await saved(at: file)
            let name = try #require(initial.volumeFileName)
            let old = try await AssetsManager.loadFresh(TerrainVolumeDocumentAsset.self, at: directory.appendingPathComponent(name).path)
            let oldBytes = try Data(contentsOf: directory.appendingPathComponent(name))
            let next = try await AssetsManager.saveTerrainRegions(
                [],
                manifest: initial,
                at: file.path,
                mode: .update(removing: []),
                volume: .init(document: old, bricks: [brick(x: 0, value: -2)], mode: .update(removing: []))
            )
            let nextName = try #require(next.volumeFileName)
            let updated = try await AssetsManager.loadFresh(TerrainVolumeDocumentAsset.self, at: directory.appendingPathComponent(nextName).path)
            #expect(updated.bricks.first { $0.x == 1 } == old.bricks.first { $0.x == 1 })
            #expect(updated.bricks.first { $0.x == 0 } != old.bricks.first { $0.x == 0 })
            #expect(try Data(contentsOf: directory.appendingPathComponent(name)) == oldBytes)
            let heightOnly = try await AssetsManager.saveTerrainRegions([], manifest: next, at: file.path, mode: .update(removing: []))
            #expect(heightOnly.volumeFileName == nextName && heightOnly.heightRegions == initial.heightRegions)
            let removed = try #require(updated.bricks.first { $0.x == 1 })
            let reduced = try await AssetsManager.saveTerrainRegions(
                [],
                manifest: heightOnly,
                at: file.path,
                mode: .update(removing: []),
                volume: .init(document: updated, bricks: [], mode: .update(removing: [removed]))
            )
            let reducedName = try #require(reduced.volumeFileName)
            let reducedVolume = try await AssetsManager.loadFresh(TerrainVolumeDocumentAsset.self, at: directory.appendingPathComponent(reducedName).path)
            #expect(reducedVolume.bricks.count == 1 && reducedVolume.bricks[0].x == 0)
        }

        @Test("A combined staging budget rejection retains the complete prior manifest and files")
        func byteBudgetRollback() async throws {
            let directory = try directory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let file = directory.appendingPathComponent("world.aterrain"), initial = try await saved(at: file)
            let name = try #require(initial.volumeFileName)
            let volume = try await AssetsManager.loadFresh(TerrainVolumeDocumentAsset.self, at: directory.appendingPathComponent(name).path)
            let before = try Data(contentsOf: file), names = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
            let failure = await #expect(throws: TerrainSaveError.self) {
                try await AssetsManager.saveTerrainRegions(
                    [],
                    manifest: initial,
                    at: file.path,
                    mode: .update(removing: []),
                    volume: .init(document: volume, bricks: [brick(x: 0, value: -3)], mode: .update(removing: [])),
                    maximumStagedBytes: 1_000
                )
            }
            let error = try #require(failure)
            if case let .byteBudgetExceeded(limit) = error {
                #expect(limit == 1_000)
            } else { Issue.record("The combined resource budget must reject before filesystem staging") }
            #expect(try Data(contentsOf: file) == before)
            #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted() == names)
        }

        @Test("Cancellation after an actual staged brick write preserves the old complete generation")
        func cancelledBrickWrite() async throws {
            let directory = try directory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let file = directory.appendingPathComponent("world.aterrain"), initial = try await saved(at: file)
            let name = try #require(initial.volumeFileName)
            let volume = try await AssetsManager.loadFresh(TerrainVolumeDocumentAsset.self, at: directory.appendingPathComponent(name).path)
            let before = try Data(contentsOf: file), names = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted(), gate = VolumeSaveGate()
            let task = Task {
                try await AssetsManager.saveTerrainRegions(
                    [],
                    manifest: initial,
                    at: file.path,
                    mode: .update(removing: []),
                    volume: .init(document: volume, bricks: [brick(x: 0, value: -4)], mode: .update(removing: [])),
                    onProgress: { count, _ in if count == 1 { await gate.pause() } }
                )
            }
            await gate.waitForPause()
            #expect(try Data(contentsOf: file) == before)
            #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".atvolbrick") }.count > 2)
            task.cancel(); await gate.resume()
            await #expect(throws: CancellationError.self) { try await task.value }
            #expect(try Data(contentsOf: file) == before)
            #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted() == names)
        }
    #endif
}

private actor VolumeSaveGate {
    private var paused = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var release: CheckedContinuation<Void, Never>?

    func pause() async {
        paused = true
        for waiter in waiting { waiter.resume() }
        waiting.removeAll()
        await withCheckedContinuation { release = $0 }
    }
    func waitForPause() async {
        guard !paused else {
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }
    func resume() { release?.resume(); release = nil }
}
