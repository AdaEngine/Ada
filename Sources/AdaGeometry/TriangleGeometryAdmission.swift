import Math

/// Conservatively bounds broad-phase visits and intersection candidates before
/// entering the native kernel. Highly overlapping inputs fail admission instead of
/// allowing an unbounded Boolean scratch workload on the editor's worker pool.
enum TriangleGeometryAdmission {
    private struct Bounds {
        let low: Vector3
        let high: Vector3
    }

    static func validate(base: TriangleSurface, operand: TriangleSurface, budget: TriangleGeometryBudget) throws {
        guard budget.maximumInputTriangles > 0, budget.maximumInputTriangles <= 1_048_576,
            budget.maximumOutputTriangles > 0, budget.maximumOutputTriangles <= 1_048_576,
            budget.maximumBytes > 0, budget.maximumBytes <= 1_073_741_824,
            budget.maximumCandidatePairs > 0, budget.maximumCandidatePairs <= 16_777_216
        else { throw TriangleGeometryError.budgetExceeded }
        let vertexCount = base.positions.count + operand.positions.count
        let inputBytes = vertexCount * 160 + (base.indices.count + operand.indices.count) * 64
        guard inputBytes <= budget.maximumBytes else { throw TriangleGeometryError.budgetExceeded }
        let left = bounds(base), right = bounds(operand)
        var candidates = 0, visits = 0
        for first in left {
            if visits.isMultiple(of: 1_024) { try Task.checkCancellation() }
            for second in right {
                visits += 1
                guard visits <= budget.maximumCandidatePairs * 8 else { throw TriangleGeometryError.budgetExceeded }
                if second.low.x > first.high.x { break }
                if second.high.x < first.low.x || second.high.y < first.low.y || second.low.y > first.high.y ||
                    second.high.z < first.low.z || second.low.z > first.high.z { continue }
                candidates += 1
                guard candidates <= budget.maximumCandidatePairs, candidates <= (budget.maximumBytes - inputBytes) / 512 else {
                    throw TriangleGeometryError.budgetExceeded
                }
            }
        }
    }

    private static func bounds(_ surface: TriangleSurface) -> [Bounds] {
        stride(from: 0, to: surface.indices.count, by: 3).map { start in
            let a = surface.positions[Int(surface.indices[start])], b = surface.positions[Int(surface.indices[start + 1])], c = surface.positions[Int(surface.indices[start + 2])]
            return Bounds(low: [min(a.x, min(b.x, c.x)), min(a.y, min(b.y, c.y)), min(a.z, min(b.z, c.z))],
                          high: [max(a.x, max(b.x, c.x)), max(a.y, max(b.y, c.y)), max(a.z, max(b.z, c.z))])
        }.sorted { $0.low.x < $1.low.x }
    }
}
