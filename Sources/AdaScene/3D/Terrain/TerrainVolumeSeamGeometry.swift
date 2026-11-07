@_spi(Internal) import AdaRender
import Math

/// A one-height-cell strip retains the neighbor's original boundary while its inner
/// edge conforms to the density tessellation. Both rendering and collision use it.
enum TerrainVolumeSeamGeometry {
    private struct Vertex {
        let position: Vector3
        let normal: Vector3
    }

    static func conform(
        positions: inout [Vector3],
        normals: inout [Vector3],
        indices: inout [UInt32],
        snapshot: TerrainHeightTileSnapshot,
        edges: TerrainLODEdges,
        maximumTriangles: Int
    ) throws -> Int {
        guard !edges.isEmpty else {
            return 0
        }
        let source = snapshot.meshDescriptor().positions.elements
        guard source.count == 4_225, snapshot.normals.count == source.count else { throw TerrainLODMeshError.invalidSnapshot }
        for index in 1...64 {
            guard source[index].x > source[index - 1].x, source[index * 65].z > source[(index - 1) * 65].z else {
                throw TerrainVolumeFieldError.invalidCoordinate
            }
        }
        let innerX0 = source[1].x, innerX1 = source[63].x, innerZ0 = source[65].z, innerZ1 = source[63 * 65].z
        func centroid(_ a: Vector3, _ b: Vector3, _ c: Vector3) -> SIMD3<Double> {
            SIMD3(
                (Double(a.x) + Double(b.x) + Double(c.x)) / 3,
                (Double(a.y) + Double(b.y) + Double(c.y)) / 3,
                (Double(a.z) + Double(b.z) + Double(c.z)) / 3
            )
        }
        func finite(_ point: Vector3) -> Bool { point.x.isFinite && point.y.isFinite && point.z.isFinite }
        func strip(_ point: SIMD3<Double>) -> Bool {
            (edges.contains(.minX) && point.x < Double(innerX0)) || (edges.contains(.maxX) && point.x > Double(innerX1))
                || (edges.contains(.minZ) && point.z < Double(innerZ0)) || (edges.contains(.maxZ) && point.z > Double(innerZ1))
        }
        // Float world increments need not be uniform. Bracket actual canonical samples
        // instead of reconstructing indices from one rounded coordinate difference.
        func bracket(_ value: Float, axis: Int) -> (Int, Float) {
            var low = 0, high = 64
            func coordinate(_ index: Int) -> Float { source[axis == 0 ? index : index * 65][axis] }
            while high - low > 1 {
                let middle = (low + high) / 2
                if value < coordinate(middle) { high = middle } else { low = middle }
            }
            let fraction = (Double(value) - Double(coordinate(low))) / (Double(coordinate(high)) - Double(coordinate(low)))
            return (low, Float(max(0, min(1, fraction))))
        }
        func inner(_ point: Vector3) -> Bool {
            (edges.contains(.minX) && point.x == innerX0) || (edges.contains(.maxX) && point.x == innerX1)
                || (edges.contains(.minZ) && point.z == innerZ0) || (edges.contains(.maxZ) && point.z == innerZ1)
        }
        func baseVertex(_ point: Vector3) -> Vertex {
            let (x, fx) = bracket(point.x, axis: 0), (z, fz) = bracket(point.z, axis: 2)
            let a = z * 65 + x
            let ids: SIMD3<Int>, weights: SIMD3<Float>
            if fx + fz <= 1 { ids = [a, a + 1, a + 65]; weights = [1 - fx - fz, fx, fz] } else {
                ids = [a + 66, a + 65, a + 1]; weights = [fx + fz - 1, 1 - fx, 1 - fz]
            }
            var height: Double = 0, normal = Vector3.zero
            for index in 0..<3 {
                height += Double(source[ids[index]].y) * Double(weights[index])
                normal += snapshot.normals[ids[index]] * weights[index]
            }
            return Vertex(position: [point.x, Float(height), point.z], normal: normal.normalized)
        }
        var retained: [UInt32] = []
        retained.reserveCapacity(indices.count)
        for offset in stride(from: 0, to: indices.count, by: 3) {
            if offset.isMultiple(of: 768) { try Task.checkCancellation() }
            let a = positions[Int(indices[offset])], b = positions[Int(indices[offset + 1])], c = positions[Int(indices[offset + 2])]
            let center = centroid(a, b, c)
            if !strip(center) { retained.append(contentsOf: indices[offset..<(offset + 3)]) }
        }
        indices = retained
        var points: Set<Vector3> = []
        for index in positions.indices where inner(positions[index]) {
            let vertex = baseVertex(positions[index])
            positions[index] = vertex.position; normals[index] = vertex.normal
        }
        for index in indices where inner(positions[Int(index)]) { points.insert(positions[Int(index)]) }
        let innerPoints = Array(points)
        var work = try TerrainVolumeFieldWork(4_194_304)
        var added = 0
        func append(_ a: Vertex, _ b: Vertex, _ c: Vertex) throws {
            guard finite(a.position), finite(b.position), finite(c.position), finite(a.normal), finite(b.normal), finite(c.normal) else {
                throw TerrainVolumeFieldError.invalidCoordinate
            }
            guard added < maximumTriangles, UInt64(positions.count) + 3 <= UInt64(UInt32.max) else { throw TerrainSourceError.meshBudgetExceeded }
            let offset = UInt32(positions.count)
            positions.append(contentsOf: [a.position, b.position, c.position])
            normals.append(contentsOf: [a.normal, b.normal, c.normal])
            indices.append(contentsOf: [offset, offset + 1, offset + 2]); added += 1
        }
        for z in 0..<64 {
            for x in 0..<64 {
                guard (edges.contains(.minX) && x == 0) || (edges.contains(.maxX) && x == 63)
                    || (edges.contains(.minZ) && z == 0) || (edges.contains(.maxZ) && z == 63) else { continue }
                let a = z * 65 + x
                for triangle in [[a, a + 65, a + 1], [a + 1, a + 65, a + 66]] {
                    var polygon: [Vertex] = []
                    for edge in 0..<3 {
                        let start = source[triangle[edge]], end = source[triangle[(edge + 1) % 3]]
                        polygon.append(Vertex(position: start, normal: snapshot.normals[triangle[edge]]))
                        let axis: Int
                        if start.x == end.x, inner(start), inner(end) { axis = 2 } else if start.z == end.z, inner(start), inner(end) { axis = 0 } else { continue }
                        var split: [(Float, Vector3)] = []
                        for point in innerPoints {
                            try work.spend()
                            guard (axis == 2 ? point.x == start.x : point.z == start.z) else { continue }
                            let fraction = (point[axis] - start[axis]) / (end[axis] - start[axis])
                            if fraction > 0, fraction < 1 { split.append((fraction, point)) }
                        }
                        for (_, point) in split.sorted(by: { $0.0 < $1.0 }) { polygon.append(baseVertex(point)) }
                    }
                    if polygon.count == 3 { try append(polygon[0], polygon[1], polygon[2]) } else {
                        let middle = centroid(source[triangle[0]], source[triangle[1]], source[triangle[2]])
                        let center = Vector3(Float(middle.x), Float(middle.y), Float(middle.z))
                        let normal = (snapshot.normals[triangle[0]] + snapshot.normals[triangle[1]] + snapshot.normals[triangle[2]]).normalized
                        let vertex = Vertex(position: center, normal: normal)
                        for index in polygon.indices { try append(vertex, polygon[index], polygon[(index + 1) % polygon.count]) }
                    }
                }
            }
        }
        try Task.checkCancellation()
        return added
    }
}
