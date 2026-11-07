/// Renderer-neutral indexed surface. Winding and unit normals point from negative to positive values.
public struct ScalarSurfaceMesh: Sendable {
    public let positions: [Vector3]
    public let normals: [Vector3]
    public let indices: [UInt32]
}

/// Fixed tetrahedral orientation. Adjacent grids must use the same choice.
public enum ScalarFieldSurfaceDiagonal: Equatable, Sendable {
    case risingXZ
    case fallingXZ
}

/// Smooth triangle extraction from a bounded scalar field. This does not render occupied voxel cubes.
public enum ScalarFieldSurface {
    /// Extracts the zero isosurface at Float sampling precision. The triangle budget also bounds
    /// temporary staging before coincident contact faces are removed. Empty fields return no triangles.
    public static func extract(
        _ grid: ScalarFieldGrid,
        maximumTriangles: Int = 262_144,
        diagonal: ScalarFieldSurfaceDiagonal = .risingXZ
    ) throws -> ScalarSurfaceMesh {
        guard maximumTriangles >= 0 else { throw ScalarFieldSurfaceError.outputBudgetExceeded }
        try Task.checkCancellation()
        var builder = ScalarSurfaceBuilder(grid: grid, maximumTriangles: maximumTriangles, diagonal: diagonal)
        return try builder.run()
    }
}

/// The six tetrahedra share the same face diagonals in every cell, including adjacent grids.
private struct ScalarSurfaceBuilder {
    private static let rising = [[0, 1, 3, 7], [0, 3, 2, 7], [0, 2, 6, 7], [0, 6, 4, 7], [0, 4, 5, 7], [0, 5, 1, 7]]
    private static let falling = rising.map { $0.map { $0 ^ 1 } }
    private let tetrahedra: [[Int]]
    let grid: ScalarFieldGrid
    let maximumTriangles: Int
    private var positions: [Vector3] = []
    private var normals: [Vector3] = []
    private var normalSums: [SIMD3<Double>] = []
    private var indices: [UInt32] = []
    private var vertices: [UInt64: UInt32] = [:]
    private var pointVertices: [Vector3: UInt32] = [:]
    private var collinearVertices: Set<UInt32> = []

    init(grid: ScalarFieldGrid, maximumTriangles: Int, diagonal: ScalarFieldSurfaceDiagonal) {
        self.grid = grid; self.maximumTriangles = maximumTriangles
        tetrahedra = diagonal == .risingXZ ? Self.rising : Self.falling
    }

    mutating func run() throws -> ScalarSurfaceMesh {
        let nx = Int(grid.cellCount.x), ny = Int(grid.cellCount.y), nz = Int(grid.cellCount.z)
        for z in 0..<nz {
            for y in 0..<ny {
                for x in 0..<nx {
                    if (x + nx * (y + ny * z)).isMultiple(of: 256) { try Task.checkCancellation() }
                    var ids = SIMD8<UInt32>(repeating: 0), values = SIMD8<Float>(repeating: 0)
                    var solid = 0
                    for corner in 0..<8 {
                        let px = x + (corner & 1), py = y + ((corner >> 1) & 1), pz = z + ((corner >> 2) & 1)
                        let index = (pz * (ny + 1) + py) * (nx + 1) + px
                        ids[corner] = UInt32(index); values[corner] = grid.values[index]
                        // A consistent solid tie suppresses internal zero-valued contact planes.
                        if values[corner] <= 0 { solid += 1 }
                    }
                    if solid == 0 || solid == 8 { continue }
                    for tetrahedron in tetrahedra { try extract(tetrahedron, ids: ids, values: values) }
                }
            }
        }
        return try finish()
    }

    private mutating func extract(_ tetrahedron: [Int], ids: borrowing SIMD8<UInt32>, values: borrowing SIMD8<Float>) throws {
        var inside = SIMD4<Int32>(repeating: 0), outside = SIMD4<Int32>(repeating: 0)
        var count = 0, exteriorCount = 0
        for corner in tetrahedron {
            if values[corner] <= 0 { inside[count] = Int32(corner); count += 1 } else { outside[exteriorCount] = Int32(corner); exteriorCount += 1 }
        }
        guard count > 0 && count < 4 else {
            return
        }
        let direction = double(point(ids[Int(outside[0])])) - double(point(ids[Int(inside[0])]))
        switch count {
        case 1:
            let a = vertex(Int(inside[0]), Int(outside[0]), ids: ids)
            let b = vertex(Int(inside[0]), Int(outside[1]), ids: ids)
            let c = vertex(Int(inside[0]), Int(outside[2]), ids: ids)
            try triangle(a, b, c, direction: direction)
        case 2:
            let a = vertex(Int(inside[0]), Int(outside[0]), ids: ids)
            let b = vertex(Int(inside[0]), Int(outside[1]), ids: ids)
            let c = vertex(Int(inside[1]), Int(outside[0]), ids: ids)
            let d = vertex(Int(inside[1]), Int(outside[1]), ids: ids)
            try triangle(a, b, c, direction: direction)
            try triangle(b, d, c, direction: direction)
        default:
            let a = vertex(Int(outside[0]), Int(inside[0]), ids: ids)
            let b = vertex(Int(outside[0]), Int(inside[1]), ids: ids)
            let c = vertex(Int(outside[0]), Int(inside[2]), ids: ids)
            try triangle(a, b, c, direction: direction)
        }
    }

    private mutating func vertex(_ a: Int, _ b: Int, ids: borrowing SIMD8<UInt32>) -> UInt32 {
        let lower = min(ids[a], ids[b]), upper = max(ids[a], ids[b])
        let first = grid.values[Int(lower)], second = grid.values[Int(upper)]
        let endpoint = first == 0 ? lower : second == 0 ? upper : nil
        let key = endpoint.map { (UInt64($0) << 32) | UInt64($0) } ?? ((UInt64(lower) << 32) | UInt64(upper))
        if let existing = vertices[key] {
            return existing
        }
        let position: Vector3
        if let endpoint {
            position = point(endpoint)
        } else {
            // Interpolate from the closer endpoint using its own density ratio.
            // This avoids subtracting a fraction rounded to one for tiny near-zero features.
            let near = abs(first) <= abs(second) ? lower : upper
            let far = near == lower ? upper : lower
            let ratio = abs(Double(grid.values[Int(near)])) / (abs(Double(first)) + abs(Double(second)))
            let start = double(point(near)), end = double(point(far))
            let value = start + (end - start) * ratio
            position = Vector3(Float(value.x), Float(value.y), Float(value.z))
        }
        // Different crossed edges can round onto the same grid endpoint. Weld their
        // representable positions before discarding precision-collapsed triangles.
        if let existing = pointVertices[position] {
            vertices[key] = existing
            return existing
        }
        // At most seven canonical edge directions per node on a grid with <= 33^3 nodes.
        let index = UInt32(positions.count)
        positions.append(position)
        vertices[key] = index
        pointVertices[position] = index
        return index
    }

    private mutating func triangle(_ a: UInt32, _ b: UInt32, _ c: UInt32, direction: SIMD3<Double>) throws {
        guard a != b && a != c && b != c else {
            return
        }
        let normal = ScalarTriangleGeometry.normal(positions[Int(a)], positions[Int(b)], positions[Int(c)])
        let squared = normal.x * normal.x + normal.y * normal.y + normal.z * normal.z
        guard squared > 0 else {
            collinearVertices.insert(a); collinearVertices.insert(b); collinearVertices.insert(c)
            return
        }
        guard indices.count / 3 < maximumTriangles else { throw ScalarFieldSurfaceError.outputBudgetExceeded }
        indices.append(a)
        if normal.x * direction.x + normal.y * direction.y + normal.z * direction.z < 0 {
            indices.append(c); indices.append(b)
        } else { indices.append(b); indices.append(c) }
    }

    private mutating func accumulate(_ index: UInt32, normal: SIMD3<Double>, fallback: Vector3) {
        normalSums[Int(index)] += normal
        if normals[Int(index)] == .zero { normals[Int(index)] = fallback }
    }

    private mutating func finish() throws -> ScalarSurfaceMesh {
        try ScalarSurfaceCollinearity.conform(positions: positions, candidates: collinearVertices, indices: &indices, maximumTriangles: maximumTriangles)
        try ScalarSurfaceTopology.cancelCoincidentFaces(&indices)
        guard !indices.isEmpty else {
            return .init(positions: [], normals: [], indices: [])
        }
        try ScalarSurfaceOrientation.repair(positions: positions, indices: &indices)
        try ScalarSurfaceFans.separate(positions: &positions, indices: &indices)
        try prepareNormals()
        // Exact-zero endpoints and precision-collapsed triangles can leave unused cached vertices.
        var remap = [UInt32](repeating: .max, count: positions.count)
        for index in indices { remap[Int(index)] = 0 }
        var count = 0
        for index in positions.indices where remap[index] != .max {
            if index.isMultiple(of: 256) { try Task.checkCancellation() }
            let sum = normalSums[index], squared = sum.x * sum.x + sum.y * sum.y + sum.z * sum.z
            let normal: Vector3
            if squared > 0 {
                let value = sum / squared.squareRoot()
                normal = Vector3(Float(value.x), Float(value.y), Float(value.z))
            } else { normal = normals[index] }
            positions[count] = positions[index]; normals[count] = normal; remap[index] = UInt32(count)
            count += 1
        }
        positions.removeLast(positions.count - count); normals.removeLast(normals.count - count)
        for index in indices.indices { indices[index] = remap[Int(indices[index])] }
        return .init(positions: positions, normals: normals, indices: indices)
    }

    private mutating func prepareNormals() throws {
        normals = Array(repeating: .zero, count: positions.count)
        normalSums = Array(repeating: .zero, count: positions.count)
        for index in stride(from: 0, to: indices.count, by: 3) {
            if index.isMultiple(of: 768) { try Task.checkCancellation() }
            let a = indices[index], b = indices[index + 1], c = indices[index + 2]
            let normal = ScalarTriangleGeometry.normal(positions[Int(a)], positions[Int(b)], positions[Int(c)])
            let squared = normal.x * normal.x + normal.y * normal.y + normal.z * normal.z
            guard squared > 0 else { continue }
            let unit = normal / squared.squareRoot()
            let fallback = Vector3(Float(unit.x), Float(unit.y), Float(unit.z))
            accumulate(a, normal: normal, fallback: fallback)
            accumulate(b, normal: normal, fallback: fallback)
            accumulate(c, normal: normal, fallback: fallback)
        }
    }

    private func point(_ index: UInt32) -> Vector3 {
        let sx = Int(grid.cellCount.x) + 1, sy = Int(grid.cellCount.y) + 1
        let value = Int(index), x = value % sx, y = (value / sx) % sy, z = value / sx / sy
        return grid.position(x: x, y: y, z: z)
    }

    private func double(_ value: Vector3) -> SIMD3<Double> { SIMD3(Double(value.x), Double(value.y), Double(value.z)) }
}
