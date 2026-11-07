import Foundation
import Math

/// Portable operation history and independently addressable last-valid density caches.
public struct TerrainVolumeDocumentAsset: Asset {
    public static let maximumEncodedBytes: Int? = 4 * 1_024 * 1_024
    public static let maximumOperations = 512
    public static let maximumBricks = 16_384
    public var assetMetaInfo: AssetMetaInfo?
    public let cellSize: Float
    public let origin: Vector3
    public let operations: [TerrainVolumeOperation]
    public let bricks: [TerrainVolumeBrickReference]

    private struct Address: Hashable {
        let x: Int32
        let y: Int32
        let z: Int32
    }

    private struct Payload: Codable {
        let version: Int
        let cellSize: Float
        let origin: Vector3
        let operations: [TerrainVolumeOperation]
        let bricks: [TerrainVolumeBrickReference]

        private enum CodingKeys: CodingKey { case version, cellSize, origin, operations, bricks }

        init(_ document: TerrainVolumeDocumentAsset) {
            version = 1; cellSize = document.cellSize; origin = document.origin; operations = document.operations; bricks = document.bricks
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            version = try container.decode(Int.self, forKey: .version)
            guard version == 1 else { throw TerrainVolumeAssetError.unsupportedVersion(String(version)) }
            cellSize = try container.decode(Float.self, forKey: .cellSize)
            origin = try container.decode(Vector3.self, forKey: .origin)
            try TerrainVolumeDocumentAsset.validateConfiguration(cellSize: cellSize, origin: origin)
            func list<Value: Decodable>(_ type: Value.Type, key: CodingKeys, maximum: Int, label: String) throws -> [Value] {
                var input = try container.nestedUnkeyedContainer(forKey: key)
                if let count = input.count, count > maximum { throw TerrainVolumeAssetError.malformed("\(label) table exceeds \(maximum) entries") }
                var result: [Value] = []
                result.reserveCapacity(input.count ?? 0)
                while !input.isAtEnd {
                    if result.count.isMultiple(of: 256) { try Task.checkCancellation() }
                    guard result.count < maximum else { throw TerrainVolumeAssetError.malformed("\(label) table exceeds \(maximum) entries") }
                    result.append(try input.decode(type))
                }
                return result
            }
            operations = try list(TerrainVolumeOperation.self, key: .operations, maximum: maximumOperations, label: "operation")
            bricks = try list(TerrainVolumeBrickReference.self, key: .bricks, maximum: maximumBricks, label: "brick")
        }
    }

    public init(cellSize: Float, origin: Vector3 = .zero, operations: [TerrainVolumeOperation] = [], bricks: [TerrainVolumeBrickReference] = []) {
        self.cellSize = cellSize; self.origin = origin; self.operations = operations; self.bricks = bricks
    }

    public init(data: Data) throws {
        try Task.checkCancellation()
        guard data.count <= (Self.maximumEncodedBytes ?? 0) else { throw TerrainVolumeAssetError.malformed("volume document encoded byte budget exceeded") }
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        self.init(cellSize: payload.cellSize, origin: payload.origin, operations: payload.operations, bricks: payload.bricks)
        try validate()
    }

    public func encodedData() throws -> Data {
        try validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let bytes = try encoder.encode(Payload(self))
        guard bytes.count <= (Self.maximumEncodedBytes ?? 0) else { throw TerrainVolumeAssetError.malformed("volume document encoded byte budget exceeded") }
        try Task.checkCancellation()
        return bytes
    }

    public func validate() throws {
        try Task.checkCancellation()
        try Self.validateConfiguration(cellSize: cellSize, origin: origin)
        guard operations.count <= Self.maximumOperations else { throw TerrainVolumeAssetError.malformed("operation table exceeds 512 entries") }
        guard bricks.count <= Self.maximumBricks else { throw TerrainVolumeAssetError.malformed("brick table exceeds 16384 entries") }
        var ids: Set<UUID> = []
        for operation in operations {
            try Task.checkCancellation()
            try operation.validate()
            guard ids.insert(operation.id).inserted else { throw TerrainVolumeAssetError.malformed("duplicate volume operation identity") }
        }
        var addresses: Set<Address> = [], names: Set<String> = []
        for brick in bricks {
            try Task.checkCancellation()
            try Self.validateReference(brick)
            guard addresses.insert(.init(x: brick.x, y: brick.y, z: brick.z)).inserted, names.insert(brick.fileName.lowercased()).inserted else {
                throw TerrainVolumeAssetError.malformed("duplicate volume brick address or file name")
            }
        }
    }

    private static func validateConfiguration(cellSize: Float, origin: Vector3) throws {
        let extent = Float(1_048_576) * cellSize
        guard cellSize.isFinite, cellSize > 0, extent.isFinite else { throw TerrainVolumeAssetError.malformed("invalid volume lattice precision") }
        for axis in 0..<3 {
            guard origin[axis].isFinite, (origin[axis] - extent).isFinite, (origin[axis] + extent).isFinite else {
                throw TerrainVolumeAssetError.malformed("invalid volume lattice origin")
            }
        }
    }

    private static func validateReference(_ brick: TerrainVolumeBrickReference) throws {
        guard (-32_768..<32_768).contains(brick.x), (-32_768..<32_768).contains(brick.y), (-32_768..<32_768).contains(brick.z) else {
            throw TerrainVolumeAssetError.malformed("volume brick address is outside the supported lattice")
        }
        let bytes = brick.fileName.utf8
        func alphanumeric(_ byte: UInt8) -> Bool { (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte) }
        guard !bytes.isEmpty, bytes.count <= 128, brick.fileName.hasSuffix(".atvolbrick"), let first = bytes.first, alphanumeric(first),
            bytes.allSatisfy({ alphanumeric($0) || $0 == 45 || $0 == 46 || $0 == 95 })
        else { throw TerrainVolumeAssetError.malformed("volume brick file must be an ASCII basename ending in .atvolbrick, at most 128 bytes") }
    }
    public init(from assetDecoder: any AssetDecoder) async throws { try self.init(data: assetDecoder.assetData) }
    public func encodeContents(with assetEncoder: any AssetEncoder) async throws { try assetEncoder.encode(encodedData()) }
    public static func extensions() -> [String] { ["atvolume"] }
}
