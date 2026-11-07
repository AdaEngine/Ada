import AdaAssets
import Foundation
import Testing

@Suite("Volume brick loader and admission")
struct TerrainVolumeBrickLoadingTests {
    private func brick() -> TerrainVolumeBrickAsset {
        .init(
            x: -32_768,
            y: 32_767,
            z: 0,
            values: Array(repeating: -0.5, count: TerrainVolumeBrickAsset.sampleCount),
            materialTags: Array(repeating: TerrainVolumeBrickAsset.unassignedMaterial, count: TerrainVolumeBrickAsset.sampleCount)
        )
    }

    #if !WASM
        @Test("A typed asset load reads an independently stored brick through AssetsManager")
        func typedNativeLoad() async throws {
            let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            let directory = root.appendingPathComponent("AdaVolumeBrick-\(UUID().uuidString)", isDirectory: true).standardizedFileURL
            try #require(directory.deletingLastPathComponent() == root)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let source = brick(), file = directory.appendingPathComponent("density.atvolbrick")
            try source.encodedData().write(to: file)
            let loaded = try await AssetsManager.loadFresh(TerrainVolumeBrickAsset.self, at: file.path)
            #expect(loaded.x == -32_768 && loaded.y == 32_767 && loaded.z == 0)
            #expect(loaded.values == source.values && loaded.materialTags == source.materialTags)
        }
    #endif

    @Test("Header magic and out-of-range signed brick addresses cannot enter the cache")
    func invalidHeader() throws {
        let bytes = try brick().encodedData()
        var magic = bytes; magic[0] = 0
        var coordinate = bytes; coordinate.replaceSubrange(8..<12, with: [0, 128, 0, 0])
        for invalid in [magic, coordinate] {
            #expect(throws: TerrainVolumeAssetError.self) { try TerrainVolumeBrickAsset(data: invalid) }
        }
    }

    @Test("A cancelled resource decode or encode does not return partial volume data")
    func cancellation() async throws {
        let source = brick(), bytes = try source.encodedData(), gate = VolumeBrickGate()
        let work = Task {
            await gate.wait()
            return try TerrainVolumeBrickAsset(data: bytes)
        }
        work.cancel(); await gate.open()
        await #expect(throws: CancellationError.self) { try await work.value }
        let encodingGate = VolumeBrickGate()
        let encoding = Task {
            await encodingGate.wait()
            return try source.encodedData()
        }
        encoding.cancel(); await encodingGate.open()
        await #expect(throws: CancellationError.self) { try await encoding.value }
    }
}

private actor VolumeBrickGate {
    private var opened = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        guard !opened else {
            return
        }
        await withCheckedContinuation { continuation = $0 }
    }

    func open() { opened = true; continuation?.resume(); continuation = nil }
}
