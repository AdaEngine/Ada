import AdaAssets
import Foundation
import Testing

@Suite("Terrain surface resources")
struct TerrainSurfaceAssetTests {
    @Test("Surface overrides and rule masks round trip through real independently loadable region resources")
    func surfaceAndMaskWireRoundTrip() async throws {
        let bytes = Self.fixture()
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        let directory = root.appendingPathComponent("TerrainSurface-" + UUID().uuidString, isDirectory: true).standardizedFileURL
        try #require(directory.deletingLastPathComponent() == root)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("paint.atregion")
        try bytes.write(to: file)
        let loaded = try #require(try? await AssetsManager.loadFresh(TerrainRegionAsset.self, at: file.path))
        #expect(loaded.x == -1 && loaded.z == 0 && loaded.tiles.isEmpty && loaded.instances.isEmpty)
        #expect(try loaded.encodedData() == bytes)
    }

    @Test("Surface sections reject unbounded counts, duplicate coordinates, invalid weights and truncation")
    func malformedSurfaceSections() throws {
        _ = try #require(try? TerrainRegionAsset(data: Self.fixture()))
        func rejects(_ bytes: Data) { #expect(throws: (any Error).self) { try TerrainRegionAsset(data: bytes) } }
        var bytes = Self.fixture()
        bytes.replaceSubrange(28..<32, with: [255, 255, 255, 255])
        rejects(bytes)
        bytes = Self.fixture()
        bytes.replaceSubrange(68..<72, with: [0, 0, 128, 127]) // Infinite first paint weight.
        rejects(bytes)
        bytes = Self.fixture()
        bytes[58] = 1 // Nonzero reserved sample word.
        rejects(bytes)
        bytes = Self.fixture()
        bytes.replaceSubrange(124..<128, with: [0, 0, 192, 127]) // NaN mask value.
        rejects(bytes)
        rejects(Self.fixture(surfaceCopies: 2))
        rejects(Self.fixture(maskCopies: 2))
        rejects(Data(Self.fixture().dropLast()))
        rejects(Self.fixture() + Data([0]))
    }

    private static func fixture(surfaceCopies: Int = 1, maskCopies: Int = 1) -> Data {
        var data = Data("ADATRN03".utf8)
        append(UInt32.max, to: &data) // Region X=-1.
        append(UInt32(0), to: &data)
        append(UInt32(2), to: &data)
        append(UInt32(0), to: &data)
        for (tag, count, stride) in [(3, surfaceCopies, 64), (4, maskCopies, 8)] {
            append(UInt16(tag), to: &data)
            append(UInt16(1), to: &data)
            append(UInt32(count), to: &data)
            append(UInt64(count * stride), to: &data)
        }
        for _ in 0..<surfaceCopies {
            data.append(contentsOf: [64, 255, 0, 0])
            for id: UInt16 in [7, 12, 0, 0] { append(id, to: &data) }
            for value: Float in [0.25, 0.75, 0, 0, 0.625, 0.2, 0.4, 0.6, 1, 0.75, 0.3, 0.5] { append(value.bitPattern, to: &data) }
            append(UInt32(0), to: &data)
        }
        for _ in 0..<maskCopies {
            data.append(contentsOf: [0, 255])
            append(UInt16(9), to: &data)
            append(Float(0.25).bitPattern, to: &data)
        }
        return data
    }

    private static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        for shift in stride(from: 0, to: T.bitWidth, by: 8) { data.append(UInt8(truncatingIfNeeded: value >> shift)) }
    }
}
