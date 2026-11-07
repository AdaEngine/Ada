enum ScalarMeshValidation {
    private struct Edge {
        let first: Int
        var second: Int = -1
        var count: Int = 1
    }

    static func weld(_ positions: [Vector3], indices: [UInt32], transform: Transform3D, work: inout ScalarMeshWork) throws -> (points: [Vector3], indices: [UInt32]) {
        var vertices: [Vector3: UInt32] = [:], points: [Vector3] = []
        var remap = [UInt32](repeating: .max, count: positions.count)
        var result: [UInt32] = []
        result.reserveCapacity(indices.count)
        for source in indices {
            try work.spend()
            guard let sourceIndex = Int(exactly: source), sourceIndex < positions.count else { throw ScalarMeshSolidError.invalidMesh }
            if remap[sourceIndex] == .max {
                let point = positions[sourceIndex]
                guard point.x.isFinite, point.y.isFinite, point.z.isFinite else { throw ScalarMeshSolidError.invalidMesh }
                let value = (transform * Vector4(point, 1)).xyz
                guard value.x.isFinite, value.y.isFinite, value.z.isFinite else { throw ScalarMeshSolidError.invalidMesh }
                let index: UInt32
                if let existing = vertices[value] { index = existing } else {
                    index = UInt32(points.count); vertices[value] = index; points.append(value)
                }
                remap[sourceIndex] = index
            }
            result.append(remap[sourceIndex])
        }
        return (points, result)
    }

    static func topology(_ indices: [UInt32], vertexCount: Int, work: inout ScalarMeshWork) throws {
        var edges: [UInt64: Edge] = [:]
        for corner in indices.indices {
            try work.spend()
            let a = indices[corner], b = indices[end(corner)]
            guard a != b else { throw ScalarMeshSolidError.invalidMesh }
            let key = (UInt64(min(a, b)) << 32) | UInt64(max(a, b))
            if var edge = edges[key] {
                edge.count += 1; edge.second = corner; edges[key] = edge
            } else { edges[key] = .init(first: corner) }
        }
        guard edges.values.allSatisfy({ $0.count == 2 }) else { throw ScalarMeshSolidError.openOrNonManifold }
        var parents = Array(indices.indices)
        for edge in edges.values {
            try work.spend()
            guard indices[edge.first] != indices[edge.second] else { throw ScalarMeshSolidError.inconsistentWinding }
            try merge(edge.first, end(edge.second), parents: &parents, work: &work)
            try merge(end(edge.first), edge.second, parents: &parents, work: &work)
        }
        // Closed edges alone permit two independent face fans touching at one vertex.
        var fans = [Int](repeating: -1, count: vertexCount)
        for corner in indices.indices {
            let fan = try root(corner, parents: &parents, work: &work), vertex = Int(indices[corner])
            if fans[vertex] < 0 { fans[vertex] = fan } else if fans[vertex] != fan { throw ScalarMeshSolidError.openOrNonManifold }
        }
    }

    private static func merge(_ first: Int, _ second: Int, parents: inout [Int], work: inout ScalarMeshWork) throws {
        let a = try root(first, parents: &parents, work: &work), b = try root(second, parents: &parents, work: &work)
        parents[max(a, b)] = min(a, b)
    }

    private static func root(_ index: Int, parents: inout [Int], work: inout ScalarMeshWork) throws -> Int {
        var result = index
        while parents[result] != result { try work.spend(); result = parents[result] }
        var point = index
        while parents[point] != point {
            try work.spend()
            let next = parents[point]; parents[point] = result; point = next
        }
        return result
    }

    private static func end(_ corner: Int) -> Int { corner - corner % 3 + (corner + 1) % 3 }
}
