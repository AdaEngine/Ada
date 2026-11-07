import Foundation

/// Per-decode allocation admission shared by nested terrain tables. This context
/// belongs to one synchronous decoder and never crosses a concurrency boundary.
public final class MeshTerrainDecodingBudget {
    private var remaining: Int
    public init(maximumBytes: Int = 128 * 1_024 * 1_024) { remaining = max(0, maximumBytes) }
    fileprivate func reserve(_ count: Int, stride: Int) throws {
        guard count >= 0, stride > 0, count <= remaining / stride else { throw TriangleGeometryError.budgetExceeded }
        remaining -= count * stride
    }
    public static let key = CodingUserInfoKey(rawValue: "AdaMeshTerrain.decodedBytes")
}

public enum MeshTerrainDecoding {
    /// Checks known counts before reserving; also bounds streaming decoders whose
    /// unkeyed containers do not report a count.
    public static func list<Value: Decodable, Key: CodingKey>(_ type: Value.Type, key: Key,
                                                            in container: KeyedDecodingContainer<Key>, decoder: any Decoder,
                                                            maximum: Int) throws -> [Value] {
        var input = try container.nestedUnkeyedContainer(forKey: key)
        let budget = MeshTerrainDecodingBudget.key.flatMap { decoder.userInfo[$0] as? MeshTerrainDecodingBudget }
        if let count = input.count {
            guard count <= maximum else { throw TriangleGeometryError.budgetExceeded }
            try budget?.reserve(count, stride: max(1, MemoryLayout<Value>.stride))
        }
        var result: [Value] = []
        result.reserveCapacity(input.count ?? 0)
        while !input.isAtEnd {
            if result.count.isMultiple(of: 256) { try Task.checkCancellation() }
            guard result.count < maximum else { throw TriangleGeometryError.budgetExceeded }
            if input.count == nil { try budget?.reserve(1, stride: max(1, MemoryLayout<Value>.stride)) }
            result.append(try input.decode(type))
        }
        return result
    }
}
