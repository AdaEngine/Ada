/// Coordinate rounding can turn an almost tangent triangle across its sampled plane.
/// Restore coherent winding through ordinary edges, retaining the area-weighted
/// outward orientation of each connected sheet before separating contact fans.
enum ScalarSurfaceOrientation {
    static func repair(positions: [Vector3], indices: inout [UInt32]) throws {
        var heads: [UInt64: Int] = [:]
        var next = [Int](repeating: -1, count: indices.count)
        for edge in indices.indices {
            if edge.isMultiple(of: 256) { try Task.checkCancellation() }
            let a = indices[edge], b = indices[end(edge)]
            let key = (UInt64(min(a, b)) << 32) | UInt64(max(a, b))
            next[edge] = heads[key] ?? -1; heads[key] = edge
        }
        var adjacent = [Int](repeating: -1, count: indices.count)
        for first in heads.values {
            let second = next[first]
            if second >= 0 && next[second] < 0 {
                adjacent[first] = second; adjacent[second] = first
            }
        }
        var signs = [Int8](repeating: 0, count: indices.count / 3)
        var queue: [Int] = []
        for seed in signs.indices where signs[seed] == 0 {
            queue.removeAll(keepingCapacity: true)
            signs[seed] = 1; queue.append(seed)
            var cursor = 0, vote = 0.0
            while cursor < queue.count {
                if cursor.isMultiple(of: 256) { try Task.checkCancellation() }
                let face = queue[cursor], start = face * 3
                cursor += 1
                vote += Double(signs[face]) * area(start, positions: positions, indices: indices)
                for edge in start..<(start + 3) where adjacent[edge] >= 0 {
                    let other = adjacent[edge], neighbor = other / 3
                    let sign = indices[edge] == indices[other] ? -signs[face] : signs[face]
                    if signs[neighbor] == 0 {
                        signs[neighbor] = sign; queue.append(neighbor)
                    } else if signs[neighbor] != sign {
                        throw ScalarFieldSurfaceError.unsupportedTopology
                    }
                }
            }
            let orientation: Int8 = vote < 0 ? -1 : 1
            for face in queue where signs[face] * orientation < 0 {
                indices.swapAt(face * 3 + 1, face * 3 + 2)
            }
        }
    }

    private static func end(_ edge: Int) -> Int { edge - edge % 3 + (edge + 1) % 3 }

    private static func area(_ start: Int, positions: [Vector3], indices: [UInt32]) -> Double {
        let a = positions[Int(indices[start])], b = positions[Int(indices[start + 1])], c = positions[Int(indices[start + 2])]
        let cross = ScalarTriangleGeometry.normal(a, b, c)
        return (cross.x * cross.x + cross.y * cross.y + cross.z * cross.z).squareRoot()
    }
}
