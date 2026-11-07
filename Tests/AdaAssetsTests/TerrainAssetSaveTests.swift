import AdaAssets
import Foundation
import Testing

@Suite("Terrain staged persistence")
struct TerrainAssetSaveTests {
    private actor SaveGate {
        var paused = false
        var waiting: [CheckedContinuation<Void, Never>] = []
        var release: CheckedContinuation<Void, Never>?

        func pause() async {
            paused = true
            for waiter in waiting { waiter.resume() }
            waiting.removeAll()
            await withCheckedContinuation { release = $0 }
        }

        func waitForPause() async {
            if paused {
                return
            }
            await withCheckedContinuation { waiting.append($0) }
        }

        func resume() { release?.resume(); release = nil }
    }

    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        let directory = root.appendingPathComponent("AdaTerrainSave-\(UUID().uuidString)", isDirectory: true).standardizedFileURL
        try #require(directory.deletingLastPathComponent() == root)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func region(x: Int32 = 0, height: Float = 3) -> TerrainRegionAsset {
        .init(x: x, z: 0, tiles: [.init(x: 0, z: 0)], pages: [.init(x: 0, z: 0, samples: Array(repeating: height, count: 4_096))])
    }

    @Test("Saving creates portable region files and a loadable manifest, preserving the previous resource generation")
    func savesCompleteSet() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("world.aterrain")
        let layout = TerrainManifestAsset(spacing: 2, originX: -8, originZ: 12)
        let initial = try await AssetsManager.saveTerrainRegions([region()], manifest: layout, at: file.path)
        let previousReference = try #require(initial.heightRegions.first)
        let previousFile = directory.appendingPathComponent(previousReference.fileName)
        let previousBytes = try Data(contentsOf: previousFile)
        let saved = try await AssetsManager.saveTerrainRegions([region(height: 9), region(x: -1)], manifest: initial, at: file.path)
        #expect(saved.heightRegions.count == 2)
        let loaded = try await AssetsManager.loadFresh(TerrainManifestAsset.self, at: file.path)
        #expect(loaded.heightRegions == saved.heightRegions)
        #expect(loaded.spacing == 2 && loaded.originX == -8 && loaded.originZ == 12)
        for ref in loaded.heightRegions {
            let asset = try await AssetsManager.loadFresh(TerrainRegionAsset.self, at: directory.appendingPathComponent(ref.fileName).path)
            #expect(asset.x == ref.x && asset.z == ref.z)
            #expect(asset.pages[0].samples[0] == (ref.x == 0 ? 9 : 3))
        }
        #expect(try Data(contentsOf: previousFile) == previousBytes)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).allSatisfy { !$0.hasSuffix(".tmp") })
    }

    @Test("Cancellation after a real region write retains the previous manifest and removes unpublished files")
    func cancelledSaveRetainsOldSet() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("world.aterrain")
        let oldRegion = directory.appendingPathComponent("old.atregion")
        try region(height: 5).encodedData().write(to: oldRegion)
        let oldManifest = TerrainManifestAsset(heightRegions: [.init(x: 0, z: 0, fileName: "old.atregion")])
        let oldBytes = try oldManifest.encodedData()
        try oldBytes.write(to: file)
        let updated = region(height: 9)
        let request = Task {
            try await AssetsManager.saveTerrainRegions(
                [updated],
                manifest: oldManifest,
                at: file.path,
                onProgress: { _, _ in
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            )
        }
        await #expect(throws: CancellationError.self) { try await request.value }
        #expect(try Data(contentsOf: file) == oldBytes)
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        #expect(names == ["old.atregion", "world.aterrain"])
        let old = try await AssetsManager.loadFresh(TerrainRegionAsset.self, at: oldRegion.path)
        #expect(old.pages[0].samples[0] == 5)
    }

    @Test("Byte limits and invalid inputs are rejected before any staged file is published")
    func rejectsBeforeWriting() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("world.aterrain")
        let layout = TerrainManifestAsset()
        let valid = region()
        await #expect(throws: (any Error).self) {
            try await AssetsManager.saveTerrainRegions([valid], manifest: layout, at: file.path, maximumStagedBytes: 0)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
        let invalid = region(x: 1, height: .infinity)
        await #expect(throws: (any Error).self) { try await AssetsManager.saveTerrainRegions([valid, invalid], manifest: layout, at: file.path) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    @Test("Saving a local edit reuses unchanged region files and keeps their stable resource references")
    func reusesUnchangedRegion() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("world.aterrain")
        let initial = try await AssetsManager.saveTerrainRegions([region(), region(x: 1)], manifest: .init(), at: file.path)
        let unchanged = try #require(initial.heightRegions.first { $0.x == 1 })
        let changed = try #require(initial.heightRegions.first { $0.x == 0 })
        let saved = try await AssetsManager.saveTerrainRegions([region(height: 9), region(x: 1)], manifest: initial, at: file.path)
        #expect(saved.heightRegions.first { $0.x == 1 } == unchanged)
        #expect(saved.heightRegions.first { $0.x == 0 } != changed)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).count == 4)
        let asset = try await AssetsManager.loadFresh(TerrainRegionAsset.self, at: directory.appendingPathComponent(unchanged.fileName).path)
        #expect(asset.pages[0].samples[0] == 3)
    }

    @Test("An automatically appended manifest extension is preserved in the returned reloadable asset reference")
    func extensionlessReferenceReloads() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let requested = directory.appendingPathComponent("world")
        let actual = directory.appendingPathComponent("world.aterrain")
        let saved = try await AssetsManager.saveTerrainRegions([region()], manifest: .init(spacing: 2), at: requested.path)
        #expect(saved.assetMetaInfo?.assetPath == actual.path)
        #expect(saved.assetMetaInfo?.assetAbsolutePath == actual)
        let handle = AssetHandle(saved)
        try await handle.load()
        #expect(handle.isLoaded)
        #expect(handle.asset.spacing == 2)
    }

    @Test("Overlapping saves to one manifest fail explicitly and release their reservation after completion")
    func rejectsOverlappingSaves() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("world.aterrain")
        let gate = SaveGate()
        let original = region()
        let changed = region(height: 9)
        let first = Task {
            try await AssetsManager.saveTerrainRegions(
                [original],
                manifest: .init(),
                at: file.path,
                onProgress: { _, _ in await gate.pause() }
            )
        }
        await gate.waitForPause()
        await #expect(throws: TerrainSaveError.self) { try await AssetsManager.saveTerrainRegions([changed], manifest: .init(), at: file.path) }
        await gate.resume()
        let initial = try await first.value
        let saved = try await AssetsManager.saveTerrainRegions([changed], manifest: initial, at: file.path)
        let ref = try #require(saved.heightRegions.first)
        let loaded = try await AssetsManager.loadFresh(TerrainRegionAsset.self, at: directory.appendingPathComponent(ref.fileName).path)
        #expect(loaded.pages[0].samples[0] == 9)
    }
}

extension TerrainAssetSaveTests {
    @Test("Incremental saves retain unloaded references within a changed-payload byte budget")
    func updatesOnlyLoadedRegion() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("world.aterrain")
        let initial = try await AssetsManager.saveTerrainRegions([region(), region(x: 1), region(x: 2)], manifest: .init(), at: file.path)
        let untouched = initial.heightRegions.filter { $0.x != 0 }
        let saved = try await AssetsManager.saveTerrainRegions(
            [region(height: 12)],
            manifest: initial,
            at: file.path,
            mode: .update(removing: []),
            maximumStagedBytes: 20_000
        )
        #expect(saved.heightRegions.count == 3)
        #expect(saved.heightRegions.filter { $0.x != 0 } == untouched)
        let loaded = try await AssetsManager.loadFresh(TerrainManifestAsset.self, at: file.path)
        #expect(loaded.heightRegions == saved.heightRegions)
        for ref in untouched {
            let value = try await AssetsManager.loadFresh(TerrainRegionAsset.self, at: directory.appendingPathComponent(ref.fileName).path)
            #expect(value.pages[0].samples[0] == 3)
        }
    }

    @Test("Incremental deletion and addition retain other regions and previous generation files")
    func updatesWithExplicitRemoval() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("world.aterrain")
        let initial = try await AssetsManager.saveTerrainRegions([region(), region(x: 1), region(x: 2)], manifest: .init(), at: file.path)
        let removed = try #require(initial.heightRegions.first { $0.x == 1 })
        let saved = try await AssetsManager.saveTerrainRegions([region(x: -1)], manifest: initial, at: file.path, mode: .update(removing: [removed]))
        #expect(Set(saved.heightRegions.map(\.x)) == [-1, 0, 2])
        #expect(saved.heightRegions.first { $0.x == 0 } == initial.heightRegions.first { $0.x == 0 })
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent(removed.fileName).path))
    }

    @Test("Incremental saves reject a stale baseline before staging resources")
    func rejectsStaleIncrementalSave() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("world.aterrain")
        let initial = try await AssetsManager.saveTerrainRegions([region(), region(x: 1)], manifest: .init(), at: file.path)
        _ = try await AssetsManager.saveTerrainRegions([region(height: 8), region(x: 1)], manifest: initial, at: file.path)
        let before = try Data(contentsOf: file)
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        var rejected = false
        do {
            _ = try await AssetsManager.saveTerrainRegions([region(height: 12)], manifest: initial, at: file.path, mode: .update(removing: []))
        } catch is TerrainSaveError { rejected = true }
        #expect(rejected)
        #expect(try Data(contentsOf: file) == before)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted() == names)
    }

    @Test("Incremental removal validation rejects mismatched, duplicate and simultaneously replaced references")
    func rejectsInvalidIncrementalRemoval() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("world.aterrain")
        let initial = try await AssetsManager.saveTerrainRegions([region(), region(x: 1)], manifest: .init(), at: file.path)
        let ref = try #require(initial.heightRegions.first { $0.x == 0 })
        let invalid = TerrainRegionReference(x: ref.x, z: ref.z, fileName: "different.atregion")
        let before = try Data(contentsOf: file)
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        for removals in [[invalid], [ref, ref], [ref]] {
            var rejected = false
            do {
                _ = try await AssetsManager.saveTerrainRegions([region(height: 12)], manifest: initial, at: file.path, mode: .update(removing: removals))
            } catch is TerrainSaveError { rejected = true }
            #expect(rejected)
            #expect(try Data(contentsOf: file) == before)
            #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted() == names)
        }
    }
}

extension TerrainAssetSaveTests {
    @Test("A manifest replaced during incremental progress is preserved and unpublished payloads are cleaned")
    func detectsProgressTimeReplacement() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("world.aterrain")
        let initial = try await AssetsManager.saveTerrainRegions([region(), region(x: 1)], manifest: .init(), at: file.path)
        let external = try TerrainManifestAsset(spacing: 2, heightRegions: initial.heightRegions).encodedData()
        let beforeNames = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        var rejected = false
        do {
            _ = try await AssetsManager.saveTerrainRegions(
                [region(height: 12)],
                manifest: initial,
                at: file.path,
                mode: .update(removing: []),
                onProgress: { _, _ in try? external.write(to: file, options: .atomic) }
            )
        } catch TerrainSaveError.staleManifest { rejected = true }
        #expect(rejected)
        #expect(try Data(contentsOf: file) == external)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted() == beforeNames)
    }

    @Test("Cancellation of an incremental save retains unloaded references and their previous-generation files")
    func cancelledIncrementalSave() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("world.aterrain")
        let initial = try await AssetsManager.saveTerrainRegions([region(), region(x: 1)], manifest: .init(), at: file.path)
        let before = try Data(contentsOf: file)
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        let request = Task {
            try await AssetsManager.saveTerrainRegions(
                [region(height: 12)],
                manifest: initial,
                at: file.path,
                mode: .update(removing: []),
                onProgress: { _, _ in withUnsafeCurrentTask { $0?.cancel() } }
            )
        }
        await #expect(throws: CancellationError.self) { try await request.value }
        #expect(try Data(contentsOf: file) == before)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted() == names)
    }
}
