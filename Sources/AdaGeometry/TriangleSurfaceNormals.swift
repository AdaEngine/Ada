import Math

enum TriangleSurfaceNormals {
    /// Recomputes normals only on attribute vertices incident to changed faces.
    /// Indices and duplicated attribute rows continue to distinguish UV and hard-normal seams.
    static func refresh(_ result: inout TriangleSurface, original: TriangleSurface) throws {
        guard !result.normals.isEmpty else { return }
        var dirty = [Bool](repeating: false, count: result.positions.count)
        for start in stride(from: 0, to: result.indices.count, by: 3) {
            if start.isMultiple(of: 768) { try Task.checkCancellation() }
            let a = Int(result.indices[start]), b = Int(result.indices[start + 1]), c = Int(result.indices[start + 2])
            if result.positions[a] != original.positions[a] || result.positions[b] != original.positions[b] || result.positions[c] != original.positions[c] {
                dirty[a] = true; dirty[b] = true; dirty[c] = true
            }
        }
        var sums = [Vector3](repeating: .zero, count: result.positions.count)
        for start in stride(from: 0, to: result.indices.count, by: 3) {
            if start.isMultiple(of: 768) { try Task.checkCancellation() }
            let a = Int(result.indices[start]), b = Int(result.indices[start + 1]), c = Int(result.indices[start + 2])
            guard dirty[a] || dirty[b] || dirty[c] else { continue }
            let normal = (result.positions[b] - result.positions[a]).cross(result.positions[c] - result.positions[a])
            sums[a] += normal; sums[b] += normal; sums[c] += normal
        }
        for index in dirty.indices where dirty[index] && sums[index].squaredLength.isFinite && sums[index].squaredLength > 0 {
            result.normals[index] = sums[index].normalized
        }
    }
}
