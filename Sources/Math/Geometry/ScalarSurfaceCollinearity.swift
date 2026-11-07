/// A rounded triangle can become a line while its neighbors retain different
/// subdivisions of that line. Insert those exact collinear vertices into the
/// neighboring faces rather than moving or deleting representable coordinates.
enum ScalarSurfaceCollinearity {
    static func conform(positions: [Vector3], candidates: Set<UInt32>, indices: inout [UInt32], maximumTriangles: Int) throws {
        guard !candidates.isEmpty, !indices.isEmpty else {
            return
        }
        let points = candidates.sorted()
        var remaining = 8_388_608
        var result: [UInt32] = []
        var pending: [(UInt32, UInt32, UInt32)] = []
        for start in stride(from: 0, to: indices.count, by: 3) {
            pending.append((indices[start], indices[start + 1], indices[start + 2]))
            while let triangle = pending.popLast() {
                let vertices = SIMD3(triangle.0, triangle.1, triangle.2)
                var split = false
                for edge in 0..<3 {
                    let a = vertices[edge], b = vertices[(edge + 1) % 3], c = vertices[(edge + 2) % 3]
                    let first = point(positions[Int(a)]), second = point(positions[Int(b)])
                    let direction = second - first
                    for vertex in points where vertex != a && vertex != b && vertex != c {
                        guard remaining > 0 else { throw ScalarFieldSurfaceError.topologyBudgetExceeded }
                        if remaining.isMultiple(of: 256) { try Task.checkCancellation() }
                        remaining -= 1
                        let candidate = point(positions[Int(vertex)])
                        guard ScalarTriangleGeometry.normal(positions[Int(a)], positions[Int(b)], positions[Int(vertex)]) == .zero else { continue }
                        let axis = abs(direction.x) >= abs(direction.y) && abs(direction.x) >= abs(direction.z) ? 0 : abs(direction.y) >= abs(direction.z) ? 1 : 2
                        guard candidate[axis] > min(first[axis], second[axis]), candidate[axis] < max(first[axis], second[axis]) else { continue }
                        guard result.count / 3 + pending.count + 2 <= maximumTriangles else { throw ScalarFieldSurfaceError.outputBudgetExceeded }
                        pending.append((a, vertex, c)); pending.append((vertex, b, c))
                        split = true
                        break
                    }
                    if split { break }
                }
                if !split {
                    guard result.count / 3 < maximumTriangles else { throw ScalarFieldSurfaceError.outputBudgetExceeded }
                    result.append(triangle.0); result.append(triangle.1); result.append(triangle.2)
                }
            }
        }
        indices = result
    }

    private static func point(_ value: Vector3) -> SIMD3<Double> { SIMD3(Double(value.x), Double(value.y), Double(value.z)) }
}
