import AdaAssets
import Foundation
import Testing

@Suite("Native volume brick resources")
struct TerrainVolumeBrickAssetTests {
    private func brick() -> TerrainVolumeBrickAsset {
        var values = (0..<TerrainVolumeBrickAsset.sampleCount).map { Float($0 % 137) - 70 }
        values[0] = -0.0; values[1] = .leastNonzeroMagnitude; values[values.count - 1] = .greatestFiniteMagnitude
        let tags = values.indices.map { $0.isMultiple(of: 3) ? UInt32(65_535) : $0.isMultiple(of: 2) ? UInt32(5) : .max }
        return .init(x: -2, y: 3, z: -4, values: values, materialTags: tags)
    }

    @Test("Native brick round trips exact density bits, signed coordinates and material IDs, including sliced Data")
    func exactRoundTrip() throws {
        let source = brick(), bytes = try #require(try? source.encodedData(), "A valid native volume brick must encode")
        #expect(bytes.count == TerrainVolumeBrickAsset.maximumEncodedBytes)
        var prefixed = Data([1, 2, 3]); prefixed.append(bytes)
        for data in [bytes, prefixed.dropFirst(3)] {
            let decoded = try TerrainVolumeBrickAsset(data: data)
            #expect(decoded.x == -2 && decoded.y == 3 && decoded.z == -4)
            #expect(decoded.values.map(\.bitPattern) == source.values.map(\.bitPattern))
            #expect(decoded.materialTags == source.materialTags)
            #expect(try decoded.encodedData() == bytes)
        }
    }

    @Test("Malformed native sizes, counts, versions and sample records fail before admission")
    func malformedWireData() throws {
        let bytes = try #require(try? brick().encodedData(), "A valid native volume brick must encode before corruption")
        var unknownVersion = bytes
        unknownVersion[7] = 57
        #expect(throws: TerrainVolumeAssetError.unsupportedVersion("09")) { try TerrainVolumeBrickAsset(data: unknownVersion) }
        var wrongCount = bytes
        wrongCount.replaceSubrange(20..<24, with: [255, 255, 255, 255])
        var nonfinite = bytes
        nonfinite.replaceSubrange(24..<28, with: [0, 0, 128, 127])
        var invalidTag = bytes
        invalidTag.replaceSubrange(28..<32, with: [0, 0, 1, 0])
        for malformed in [Data(bytes.dropLast()), bytes + Data([0]), wrongCount, nonfinite, invalidTag, Data()] {
            #expect(throws: TerrainVolumeAssetError.self) { try TerrainVolumeBrickAsset(data: malformed) }
        }
    }

    @Test("Invalid in-memory counts, coordinates, densities and material tags cannot be encoded")
    func malformedAuthoredData() throws {
        let source = brick()
        var nonfinite = source.values; nonfinite[99] = .nan
        var invalidTags = source.materialTags; invalidTags[99] = 65_536
        let invalid: [TerrainVolumeBrickAsset] = [
            .init(x: .max, y: 0, z: 0, values: source.values, materialTags: source.materialTags),
            .init(x: 0, y: 0, z: 0, values: [], materialTags: source.materialTags),
            .init(x: 0, y: 0, z: 0, values: source.values, materialTags: []),
            .init(x: 0, y: 0, z: 0, values: nonfinite, materialTags: source.materialTags),
            .init(x: 0, y: 0, z: 0, values: source.values, materialTags: invalidTags)
        ]
        for value in invalid {
            #expect(throws: TerrainVolumeAssetError.self) { try value.validate() }
            #expect(throws: TerrainVolumeAssetError.self) { try value.encodedData() }
        }
    }
}
