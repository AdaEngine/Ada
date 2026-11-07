import Math

extension TerrainVolumeField {
    /// Interpolates unnormalized central lattice gradients before normalization. Shared
    /// world positions therefore have identical normals regardless of brick ownership.
    /// Double intermediates retain gradients of sub-cell features and uneven Float axes.
    func canonicalNormals(for surface: ScalarSurfaceMesh, maximumWork: Int = 268_435_456) throws -> [Vector3] {
        var budget = try TerrainVolumeFieldWork(maximumWork)
        return try canonicalNormals(for: surface, budget: &budget)
    }

    func canonicalNormals(for surface: ScalarSurfaceMesh, budget: inout TerrainVolumeFieldWork) throws -> [Vector3] {
        var result: [Vector3] = []
        result.reserveCapacity(surface.positions.count)
        for index in surface.positions.indices {
            try budget.spend()
            let point = surface.positions[index]
            let (x, tx) = try normalAxis(point.x, axis: 0)
            let (y, ty) = try normalAxis(point.y, axis: 1)
            let (z, tz) = try normalAxis(point.z, axis: 2)
            var gradient = SIMD3<Double>.zero
            for corner in 0..<8 {
                let dx = corner & 1, dy = (corner >> 1) & 1, dz = (corner >> 2) & 1
                let weight = (dx == 0 ? 1 - tx : tx) * (dy == 0 ? 1 - ty : ty) * (dz == 0 ? 1 - tz : tz)
                if weight == 0 { continue }
                let address = SIMD3(x + dx, y + dy, z + dz)
                for axis in 0..<3 {
                    var minus = address, plus = address
                    minus[axis] -= 1; plus[axis] += 1
                    let low = normalPosition(minus), high = normalPosition(plus)
                    let distance = Double(high[axis]) - Double(low[axis])
                    guard distance > 0, distance.isFinite else { throw TerrainVolumeFieldError.invalidCoordinate }
                    let a = try sample(at: low, budget: &budget).value
                    let b = try sample(at: high, budget: &budget).value
                    gradient[axis] += weight * (Double(b) - Double(a)) / distance
                }
            }
            let length = (gradient.x * gradient.x + gradient.y * gradient.y + gradient.z * gradient.z).squareRoot()
            if length > 0, length.isFinite {
                result.append(Vector3(Float(gradient.x / length), Float(gradient.y / length), Float(gradient.z / length)))
            } else {
                // Coincident opposing sheets may have no unique field gradient.
                result.append(surface.normals[index])
            }
        }
        return result
    }

    private func normalPosition(_ address: SIMD3<Int>) -> Vector3 {
        document.origin + Vector3(Float(address.x), Float(address.y), Float(address.z)) * document.cellSize
    }

    private func normalAxis(_ point: Float, axis: Int) throws -> (Int, Double) {
        let approximate = ((Double(point) - Double(document.origin[axis])) / Double(document.cellSize)).rounded(.down)
        guard approximate.isFinite, (-1_048_580...1_048_580).contains(approximate) else { throw TerrainVolumeFieldError.invalidCoordinate }
        var index = Int(approximate)
        func position(_ index: Int) -> Float { document.origin[axis] + Float(index) * document.cellSize }
        // Exact Float lattice bracketing, including far-from-origin fractional spacing.
        for _ in 0..<4 {
            if position(index) > point { index -= 1 } else if position(index + 1) <= point { index += 1 } else { break }
        }
        let low = position(index), high = position(index + 1)
        guard low.isFinite, high.isFinite, low <= point, point < high else { throw TerrainVolumeFieldError.invalidCoordinate }
        return (index, (Double(point) - Double(low)) / (Double(high) - Double(low)))
    }
}
