import AdaAssets
import Foundation
import Math
import Testing

@Suite("Persistent ordered terrain volume operations")
struct TerrainVolumeDocumentTests {
    private func document() -> TerrainVolumeDocumentAsset {
        var matrix = Transform3D(translation: [-20, 3, 5], rotation: .identity, scale: [-2, 1, 0.5])
        matrix.y += matrix.x * 0.25
        return .init(
            cellSize: 0.5,
            origin: [-256, 0, 256],
            operations: [
                .init(operation: .subtract, operand: .primitive(.capsule(radius: 3, halfHeight: 8)), transform: matrix),
                .init(operation: .union, operand: .mesh(assetPath: "Models/ledge.glb", scene: 1), transform: matrix, layerID: 7, isEnabled: false)
            ],
            bricks: [.init(x: -1, y: 0, z: 2, fileName: "brick-a.atvolbrick"), .init(x: 0, y: 0, z: 2, fileName: "brick-b.atvolbrick")]
        )
    }

    @Test("Round trips preserve order, identity, source, full affine placement, precision and caches")
    func orderedRoundTrip() throws {
        let source = document(), bytes = try #require(try? source.encodedData(), "A valid volume operation document must encode")
        let decoded = try TerrainVolumeDocumentAsset(data: bytes)
        #expect(decoded.cellSize == 0.5 && decoded.origin == source.origin)
        #expect(decoded.operations == source.operations && decoded.bricks == source.bricks)
        #expect(try decoded.encodedData() == bytes)
        let reordered = TerrainVolumeDocumentAsset(cellSize: decoded.cellSize, origin: decoded.origin, operations: decoded.operations.reversed(), bricks: decoded.bricks)
        let reopened = try TerrainVolumeDocumentAsset(data: reordered.encodedData())
        #expect(reopened.operations.map(\.id) == source.operations.map(\.id).reversed())
        #expect(reopened.operations[0].layerID == 7 && !reopened.operations[0].isEnabled)
    }

    @Test("Unsafe references, duplicate cache addresses/names, identities and invalid fields cannot be persisted")
    func invalidAuthoredMetadata() throws {
        let source = document(), first = try #require(source.operations.first)
        let invalid: [TerrainVolumeDocumentAsset] = [
            .init(cellSize: 0), .init(cellSize: .infinity),
            .init(cellSize: 1, origin: [.nan, 0, 0]),
            .init(cellSize: 1, operations: [first, first]),
            .init(cellSize: 1, operations: [.init(operation: .union, operand: .mesh(assetPath: "../cave.glb", scene: nil))]),
            .init(cellSize: 1, operations: [.init(operation: .union, operand: .primitive(.sphere(radius: -1)))]),
            .init(cellSize: 1, operations: [.init(operation: .union, operand: .primitive(.sphere(radius: 1)), transform: .init(scale: [0, 1, 1]))]),
            .init(cellSize: 1, bricks: [.init(x: 0, y: 0, z: 0, fileName: "../brick.atvolbrick")]),
            .init(cellSize: 1, bricks: [.init(x: 0, y: 0, z: 0, fileName: "a.atvolbrick"), .init(x: 0, y: 0, z: 0, fileName: "b.atvolbrick")]),
            .init(cellSize: 1, bricks: [.init(x: 0, y: 0, z: 0, fileName: "A.atvolbrick"), .init(x: 1, y: 0, z: 0, fileName: "a.atvolbrick")]),
            .init(cellSize: 1, bricks: [.init(x: .max, y: 0, z: 0, fileName: "a.atvolbrick")])
        ]
        for value in invalid {
            #expect(throws: (any Error).self) { try value.validate() }
            #expect(throws: (any Error).self) { try value.encodedData() }
        }
    }

    @Test("Decode bounds operation/cache tables before attempting malformed child records")
    func decodeAdmission() throws {
        let bytes = try #require(try? document().encodedData(), "Valid metadata must encode before hostile input is constructed")
        let original = try #require(try JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        var operations = original; operations["operations"] = Array(repeating: NSNull(), count: 513)
        #expect(throws: TerrainVolumeAssetError.malformed("operation table exceeds 512 entries")) {
            try TerrainVolumeDocumentAsset(data: JSONSerialization.data(withJSONObject: operations))
        }
        var bricks = original; bricks["bricks"] = Array(repeating: NSNull(), count: 16_385)
        #expect(throws: TerrainVolumeAssetError.malformed("brick table exceeds 16384 entries")) {
            try TerrainVolumeDocumentAsset(data: JSONSerialization.data(withJSONObject: bricks))
        }
        var version = original; version["version"] = 42
        #expect(throws: TerrainVolumeAssetError.unsupportedVersion("42")) {
            try TerrainVolumeDocumentAsset(data: JSONSerialization.data(withJSONObject: version))
        }
        #expect(throws: TerrainVolumeAssetError.self) { try TerrainVolumeDocumentAsset(data: Data(repeating: 0, count: 4 * 1_024 * 1_024 + 1)) }
    }
}
