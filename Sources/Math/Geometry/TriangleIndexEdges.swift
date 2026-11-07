/// Line-list indices retaining triangle order, so a selected triangle range maps
/// directly to twice that range in the edge buffer. Shared edges remain repeated.
public enum TriangleIndexEdges {
    public static func make(from indices: [UInt32], maximumIndices: Int = 6_291_456) -> [UInt32]? {
        guard maximumIndices >= 0, indices.count.isMultiple(of: 3), indices.count <= maximumIndices / 2 else { return nil }
        var result: [UInt32] = []
        result.reserveCapacity(indices.count * 2)
        for index in stride(from: 0, to: indices.count, by: 3) {
            let first = indices[index], second = indices[index + 1], third = indices[index + 2]
            result.append(contentsOf: [first, second, second, third, third, first])
        }
        return result
    }
}
