import Math

/// Relaxes only the connected neighborhood of an operand's Boolean seam.
/// Vertices duplicated for shading attributes share one geometric displacement.
enum TriangleContactRelaxation {
    private struct Edge {
        let first: Int
        let second: Int
        let face: Int
        var opposite: Int?
    }

    private struct Topology {
        let points: [Vector3]
        let mapping: [Int]
        let normals: [Vector3]
        let edges: [Edge]
    }

    private struct Neighbor {
        let vertex: Int
        let length: Float
    }

    private struct Work {
        var remaining: Int
        mutating func charge(_ count: Int) throws {
            guard count <= remaining else { throw TriangleGeometryError.budgetExceeded }
            remaining -= count
        }
    }

    static func apply(_ input: TriangleSurface, operand: UInt32, options: MeshTerrainRounding, budget: TriangleGeometryBudget) throws -> TriangleSurface {
        guard !input.indices.isEmpty, !input.faceSources.isEmpty else { return input }
        let scratch = input.positions.count * 192 + input.indices.count * 128
        guard scratch <= budget.maximumBytes else { throw TriangleGeometryError.budgetExceeded }
        var work = Work(remaining: budget.maximumCandidatePairs)
        let topology = try makeTopology(input, work: &work)
        let (neighbors, distances) = try makeBand(topology, sources: input.faceSources, operand: operand, radius: options.radius, work: &work)
        let active = distances.indices.filter { distances[$0] < options.radius }
        guard !active.isEmpty else { return input }
        var points = topology.points
        for _ in 0..<3 {
            try Task.checkCancellation()
            var desired = points
            for vertex in active {
                let adjacent = neighbors[vertex]
                try work.charge(adjacent.count + 1)
                guard !adjacent.isEmpty else { continue }
                let mean = adjacent.reduce(Vector3.zero) { $0 + points[$1.vertex] } / Float(adjacent.count)
                let falloff = 1 - distances[vertex] / options.radius
                let offset = points[vertex] + (mean - points[vertex]) * (0.4 * falloff * falloff) - topology.points[vertex]
                let maximum = options.maximumDeviation * falloff
                let length = offset.length
                guard length.isFinite else { throw TriangleGeometryError.invalidInput }
                desired[vertex] = topology.points[vertex] + (length > maximum ? offset * (maximum / length) : offset)
            }
            // Back off a step rather than allowing a face to collapse or turn over.
            var accepted = false
            for _ in 0..<7 {
                if try validFaces(input, topology: topology, points: desired, work: &work) {
                    points = desired
                    accepted = true
                    break
                }
                for vertex in active { desired[vertex] = (desired[vertex] + points[vertex]) * 0.5 }
            }
            guard accepted else { throw TriangleGeometryError.invalidInput }
        }
        var result = input
        result.positions = topology.mapping.map { points[$0] }
        try updateNormals(&result, original: input, work: &work)
        return result
    }

    private static func makeTopology(_ surface: TriangleSurface, work: inout Work) throws -> Topology {
        try work.charge(surface.positions.count + surface.indices.count)
        var points: [Vector3] = [], mapping: [Int] = [], pointIDs: [Vector3: Int] = [:]
        for (index, position) in surface.positions.enumerated() {
            if index.isMultiple(of: 1_024) { try Task.checkCancellation() }
            if let id = pointIDs[position] { mapping.append(id) }
            else { pointIDs[position] = points.count; mapping.append(points.count); points.append(position) }
        }
        var table: [UInt64: Edge] = [:], normals: [Vector3] = []
        for face in 0..<surface.indices.count / 3 {
            if face.isMultiple(of: 1_024) { try Task.checkCancellation() }
            let start = face * 3
            let a = mapping[Int(surface.indices[start])], b = mapping[Int(surface.indices[start + 1])], c = mapping[Int(surface.indices[start + 2])]
            let normal = (points[b] - points[a]).cross(points[c] - points[a])
            guard normal.squaredLength.isFinite, normal.squaredLength > 0 else { throw TriangleGeometryError.invalidInput }
            normals.append(normal.normalized)
            for (first, second) in [(a, b), (b, c), (c, a)] {
                let key = (UInt64(min(first, second)) << 32) | UInt64(max(first, second))
                if var edge = table[key] {
                    guard edge.opposite == nil else { throw TriangleGeometryError.nonManifold }
                    edge.opposite = face
                    table[key] = edge
                } else { table[key] = .init(first: first, second: second, face: face) }
            }
        }
        let sortWork = table.count * max(1, Int.bitWidth - table.count.leadingZeroBitCount)
        try work.charge(sortWork)
        return .init(points: points, mapping: mapping, normals: normals, edges: table.keys.sorted().compactMap { table[$0] })
    }

    private static func makeBand(_ topology: Topology, sources: [UInt32], operand: UInt32, radius: Float, work: inout Work) throws
        -> (neighbors: [[Neighbor]], distances: [Float]) {
        let count = topology.points.count
        var neighbors = [[Neighbor]](repeating: [], count: count)
        var contact = [Bool](repeating: false, count: count), boundary = contact, sharp = contact
        try work.charge(topology.edges.count)
        for (index, edge) in topology.edges.enumerated() {
            if index.isMultiple(of: 1_024) { try Task.checkCancellation() }
            let length = (topology.points[edge.first] - topology.points[edge.second]).length
            guard length.isFinite, length > 0 else { throw TriangleGeometryError.invalidInput }
            neighbors[edge.first].append(.init(vertex: edge.second, length: length))
            neighbors[edge.second].append(.init(vertex: edge.first, length: length))
            let firstSource = sources[edge.face]
            guard let opposite = edge.opposite, firstSource != TrianglePatchClosure.closureSource,
                sources[opposite] != TrianglePatchClosure.closureSource else {
                boundary[edge.first] = true; boundary[edge.second] = true
                continue
            }
            let secondSource = sources[opposite]
            if firstSource != secondSource, firstSource == operand || secondSource == operand {
                contact[edge.first] = true; contact[edge.second] = true
            } else if topology.normals[edge.face].dot(topology.normals[opposite]) < 0.6 {
                sharp[edge.first] = true; sharp[edge.second] = true
            }
        }
        var distances = [Float](repeating: .infinity, count: count), queue: [Int] = []
        for index in 0..<count where contact[index] && !boundary[index] { distances[index] = 0; queue.append(index) }
        var cursor = 0
        // Relax distances in deterministic edge order. Every visit is charged,
        // including duplicate entries if a shorter path supersedes a queued one.
        while cursor < queue.count {
            if cursor.isMultiple(of: 1_024) { try Task.checkCancellation() }
            let vertex = queue[cursor]
            cursor += 1
            try work.charge(neighbors[vertex].count + 1)
            for neighbor in neighbors[vertex] where !boundary[neighbor.vertex] && (!sharp[neighbor.vertex] || contact[neighbor.vertex]) {
                let distance = distances[vertex] + neighbor.length
                if distance < radius, distance < distances[neighbor.vertex] {
                    distances[neighbor.vertex] = distance
                    queue.append(neighbor.vertex)
                }
            }
        }
        return (neighbors, distances)
    }

    private static func validFaces(_ surface: TriangleSurface, topology: Topology, points: [Vector3], work: inout Work) throws -> Bool {
        try work.charge(surface.indices.count)
        for face in topology.normals.indices {
            if face.isMultiple(of: 1_024) { try Task.checkCancellation() }
            let start = face * 3
            let a = points[topology.mapping[Int(surface.indices[start])]], b = points[topology.mapping[Int(surface.indices[start + 1])]]
            let c = points[topology.mapping[Int(surface.indices[start + 2])]]
            let normal = (b - a).cross(c - a)
            if !normal.squaredLength.isFinite || normal.dot(topology.normals[face]) <= 0 { return false }
        }
        return true
    }

    private static func updateNormals(_ result: inout TriangleSurface, original: TriangleSurface, work: inout Work) throws {
        guard !result.normals.isEmpty else { return }
        try work.charge(result.indices.count * 2 + result.positions.count)
        var dirty = [Bool](repeating: false, count: result.positions.count)
        for start in stride(from: 0, to: result.indices.count, by: 3) {
            let a = Int(result.indices[start]), b = Int(result.indices[start + 1]), c = Int(result.indices[start + 2])
            if result.positions[a] != original.positions[a] || result.positions[b] != original.positions[b] || result.positions[c] != original.positions[c] {
                dirty[a] = true; dirty[b] = true; dirty[c] = true
            }
        }
        var sums = [Vector3](repeating: .zero, count: result.positions.count)
        for start in stride(from: 0, to: result.indices.count, by: 3) {
            if start.isMultiple(of: 3_072) { try Task.checkCancellation() }
            let a = Int(result.indices[start]), b = Int(result.indices[start + 1]), c = Int(result.indices[start + 2])
            guard dirty[a] || dirty[b] || dirty[c] else { continue }
            let normal = (result.positions[b] - result.positions[a]).cross(result.positions[c] - result.positions[a])
            sums[a] += normal; sums[b] += normal; sums[c] += normal
        }
        for index in dirty.indices where dirty[index] && sums[index].squaredLength > 0 { result.normals[index] = sums[index].normalized }
    }
}
