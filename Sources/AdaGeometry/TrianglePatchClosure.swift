import Math

/// Explicit closure policy for a single-valued open ground patch. Closure faces
/// carry reserved provenance and are removed from visible/query/collision output.
/// Arbitrary open cave sheets are rejected instead of inventing inside semantics.
public enum TrianglePatchClosure {
    public static let closureSource = UInt32.max

    public static func closeGround(_ surface: TriangleSurface, below height: Float) throws -> TriangleSurface {
        try surface.validate()
        guard height.isFinite, !surface.positions.isEmpty, !surface.indices.isEmpty,
            surface.positions.allSatisfy({ $0.y > height }), !surface.faceSources.contains(closureSource)
        else { throw TriangleGeometryError.invalidInput }
        var columns: [Vector2: Float] = [:]
        for point in surface.positions {
            let key = Vector2(point.x, point.z)
            if let previous = columns[key], previous != point.y { throw TriangleGeometryError.invalidInput }
            columns[key] = point.y
        }
        var edges: [UInt64: (count: Int, first: UInt32, second: UInt32)] = [:]
        for start in stride(from: 0, to: surface.indices.count, by: 3) {
            let a = surface.positions[Int(surface.indices[start])], b = surface.positions[Int(surface.indices[start + 1])], c = surface.positions[Int(surface.indices[start + 2])]
            guard (b - a).cross(c - a).y > 0 else { throw TriangleGeometryError.invalidInput }
            for edge in 0..<3 {
                let first = surface.indices[start + edge], second = surface.indices[start + (edge + 1) % 3]
                let key = (UInt64(min(first, second)) << 32) | UInt64(max(first, second))
                let previous = edges[key]
                guard previous?.count ?? 0 < 2 else { throw TriangleGeometryError.nonManifold }
                edges[key] = ((previous?.count ?? 0) + 1, first, second)
            }
        }
        let boundary = edges.values.filter { $0.count == 1 }
        var next: [UInt32: UInt32] = [:]
        for edge in boundary {
            guard next.updateValue(edge.second, forKey: edge.first) == nil else { throw TriangleGeometryError.nonManifold }
        }
        guard let first = next.keys.min() else { throw TriangleGeometryError.invalidInput }
        var current = first, visited: Set<UInt32> = []
        repeat {
            guard visited.insert(current).inserted, let successor = next[current] else { throw TriangleGeometryError.nonManifold }
            current = successor
        } while current != first
        guard visited.count == next.count else { throw TriangleGeometryError.invalidInput }
        var result = surface
        let count = UInt32(surface.positions.count)
        result.positions += surface.positions.map { [$0.x, height, $0.z] }
        if !result.normals.isEmpty { result.normals += Array(repeating: [0, -1, 0], count: surface.positions.count) }
        if !result.textureCoordinates.isEmpty { result.textureCoordinates += surface.textureCoordinates }
        result.faceSources = surface.faceSources.isEmpty ? Array(repeating: 0, count: surface.indices.count / 3) : surface.faceSources
        result.faceIDs = surface.faceIDs.isEmpty ? Array(0..<UInt32(surface.indices.count / 3)) : surface.faceIDs
        func append(_ a: UInt32, _ b: UInt32, _ c: UInt32) {
            result.indices += [a, b, c]
            result.faceSources.append(closureSource); result.faceIDs.append(UInt32(result.faceIDs.count))
        }
        for start in stride(from: 0, to: surface.indices.count, by: 3) {
            append(surface.indices[start] + count, surface.indices[start + 2] + count, surface.indices[start + 1] + count)
        }
        for key in edges.keys.sorted() {
            guard let edge = edges[key], edge.count == 1 else { continue }
            append(edge.second, edge.first, edge.first + count)
            append(edge.second, edge.first + count, edge.second + count)
        }
        try result.validate()
        return result
    }

    public static func visibleSurface(_ surface: TriangleSurface) throws -> TriangleSurface {
        try surface.validate()
        guard !surface.faceSources.isEmpty else { return surface }
        var result = surface
        result.indices = []; result.faceSources = []; result.faceIDs = []
        for face in 0..<surface.indices.count / 3 where surface.faceSources[face] != closureSource {
            result.indices += surface.indices[(face * 3)..<(face * 3 + 3)]
            result.faceSources.append(surface.faceSources[face])
            result.faceIDs.append(surface.faceIDs.isEmpty ? UInt32(face) : surface.faceIDs[face])
        }
        // Unreferenced closure vertices must not enlarge runtime bounds or
        // leak the artificial bottom into later editing and query budgets.
        let used = Set(result.indices).sorted()
        var remap: [UInt32: UInt32] = [:]
        remap.reserveCapacity(used.count)
        for (index, original) in used.enumerated() { remap[original] = UInt32(index) }
        result.positions = used.map { surface.positions[Int($0)] }
        result.normals = surface.normals.isEmpty ? [] : used.map { surface.normals[Int($0)] }
        result.textureCoordinates = surface.textureCoordinates.isEmpty ? [] : used.map { surface.textureCoordinates[Int($0)] }
        result.indices = try result.indices.map {
            guard let index = remap[$0] else { throw TriangleGeometryError.invalidInput }
            return index
        }
        return result
    }
}
