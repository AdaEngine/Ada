import Math

/// Ground sections clip operands in X/Z. Require their combined clipping
/// domain to contain a union operand before the editor can hide its source.
enum MeshTerrainCoverage {
    static func contains(_ operand: MeshTerrainBounds, in sections: [MeshTerrainBounds], remaining: inout Int) throws -> Bool {
        guard sections.count <= remaining else { throw TriangleGeometryError.budgetExceeded }
        remaining -= sections.count
        if sections.contains(where: {
            $0.minimum.x <= operand.minimum.x && $0.maximum.x >= operand.maximum.x &&
                $0.minimum.z <= operand.minimum.z && $0.maximum.z >= operand.maximum.z
        }) { return true }

        let intersecting = sections.filter {
            $0.maximum.x > operand.minimum.x && $0.minimum.x < operand.maximum.x &&
                $0.maximum.z > operand.minimum.z && $0.minimum.z < operand.maximum.z
        }.sorted { $0.minimum.z < $1.minimum.z }
        guard !intersecting.isEmpty else { return false }
        let cuts = Set([operand.minimum.x, operand.maximum.x] + intersecting.flatMap {
            [max(operand.minimum.x, $0.minimum.x), min(operand.maximum.x, $0.maximum.x)]
        }).sorted()
        // Coverage is constant between consecutive rectangle edges. Merge
        // the Z intervals for each slab so holes and partial seams are rejected.
        for (left, right) in zip(cuts, cuts.dropFirst()) {
            guard intersecting.count <= remaining else { throw TriangleGeometryError.budgetExceeded }
            remaining -= intersecting.count
            var coveredZ = operand.minimum.z
            for section in intersecting {
                if section.minimum.z > coveredZ { break }
                if section.minimum.x <= left && section.maximum.x >= right {
                    coveredZ = max(coveredZ, section.maximum.z)
                    if coveredZ >= operand.maximum.z { break }
                }
            }
            if coveredZ < operand.maximum.z { return false }
        }
        return true
    }
}
