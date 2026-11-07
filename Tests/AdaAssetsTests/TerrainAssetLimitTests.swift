import AdaAssets
import Foundation
import Testing

@Suite("Terrain asset byte limits")
struct TerrainAssetLimitTests {
    private enum DecodeError: Error { case oversizedDataReachedDecoder }

    private struct LimitedAsset: Asset {
        var assetMetaInfo: AssetMetaInfo?
        let data: Data
        static let maximumEncodedBytes: Int? = 8

        init(from decoder: any AssetDecoder) async throws {
            guard decoder.assetData.count <= 8 else { throw DecodeError.oversizedDataReachedDecoder }
            data = decoder.assetData
        }
        func encodeContents(with encoder: any AssetEncoder) async throws { try encoder.encode(data) }
        static func extensions() -> [String] { ["terrain-limit-test"] }
    }

    @Test("Asset-specific byte caps reject oversized files before the asset decoder runs")
    func rejectsOversizedTerrainAsset() async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        let directory = root.appendingPathComponent("AdaTerrainLimit-\(UUID().uuidString)", isDirectory: true).standardizedFileURL
        try #require(directory.deletingLastPathComponent() == root)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("region.terrain-limit-test")
        try Data(repeating: 0, count: 16).write(to: file)
        await #expect(throws: AssetError.self) {
            try await AssetsManager.loadFresh(LimitedAsset.self, at: file.path)
        }
        try Data(repeating: 3, count: 8).write(to: file)
        let loaded = try await AssetsManager.loadFresh(LimitedAsset.self, at: file.path)
        #expect(loaded.data == Data(repeating: 3, count: 8))
    }
}
