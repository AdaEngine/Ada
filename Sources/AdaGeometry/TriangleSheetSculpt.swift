import Math

enum TriangleSheetSculpt {
    private struct Edge: Hashable {
        let first: Int
        let second: Int

        init(_ a: Int, _ b: Int) {
            first = min(a, b)
            second = max(a, b)
        }
    }

    private struct Topology {
        var positions: [Vector3] = []
        var vertices: [Int] = []
        var pinned: [Bool] = []
        var neighbors: [[Int]] = []
        var seed: [Int] = []
    }

    static func apply(_ stamp: MeshTerrainSurfaceSculpt, to input: TriangleSurface, budget: TriangleGeometryBudget) throws -> TriangleSurface {
        guard stamp.strength > 0, !input.indices.isEmpty else { return input }
        let bytes = input.positions.count * 176 + input.indices.count * 92
        guard bytes <= budget.maximumBytes else { throw TriangleGeometryError.budgetExceeded }
        // Build one local, orientation- and provenance-filtered graph. Never
        // bridge disconnected surfaces merely because they are close in space.
        let axis = stamp.normal.normalized
        let topology = try topology(input, stamp: stamp, axis: axis, maximumWork: budget.maximumCandidatePairs)
        guard !topology.seed.isEmpty else { return input }
        var queue: [Int] = [], seen = [Bool](repeating: false, count: topology.positions.count)
        func enqueue(_ vertex: Int) {
            let distance = (topology.positions[vertex] - stamp.center).length
            guard !seen[vertex], distance < stamp.radius else { return }
            seen[vertex] = true
            queue.append(vertex)
        }
        for vertex in topology.seed { enqueue(vertex) }
        var cursor = 0
        var offsets = [Vector3](repeating: .zero, count: topology.positions.count)
        while cursor < queue.count {
            if cursor.isMultiple(of: 256) { try Task.checkCancellation() }
            let vertex = queue[cursor]
            cursor += 1
            let neighbors = topology.neighbors[vertex]
            for next in neighbors { enqueue(next) }
            guard !topology.pinned[vertex] else { continue }
            let position = topology.positions[vertex]
            let distance = (position - stamp.center).length
            let t = 1 - distance / stamp.radius
            let blend = t * t * (3 - 2 * t) * stamp.strength
            let delta: Float
            switch stamp.operation {
            case .smooth:
                guard !neighbors.isEmpty else { continue }
                let sum = neighbors.reduce(Float(0)) { $0 + (topology.positions[$1] - position).dot(axis) }
                delta = sum / Float(neighbors.count)
            case let .flatten(point): delta = (point - position).dot(axis)
            }
            guard delta.isFinite else { throw TriangleGeometryError.invalidInput }
            offsets[vertex] = axis * (min(64, max(-64, delta)) * blend)
        }
        guard offsets.contains(where: { $0 != .zero }) else { return input }
        var result = input
        var amount: Float = 1
        for _ in 0..<7 {
            result.positions = topology.vertices.map { topology.positions[$0] + offsets[$0] * amount }
            if try hasUnflippedFaces(result, comparedTo: input) {
                try TriangleSurfaceNormals.refresh(&result, original: input)
                return result
            }
            amount *= 0.5
        }
        throw TriangleGeometryError.invalidInput
    }

    private static func topology(_ input: TriangleSurface, stamp: MeshTerrainSurfaceSculpt, axis: Vector3, maximumWork: Int) throws -> Topology {
        guard input.positions.count + input.indices.count * 12 <= maximumWork else { throw TriangleGeometryError.budgetExceeded }
        var result = Topology()
        var welded: [Vector3: Int] = [:]
        for point in input.positions {
            if result.vertices.count.isMultiple(of: 256) { try Task.checkCancellation() }
            let index = welded[point] ?? result.positions.count
            if index == result.positions.count {
                welded[point] = index
                result.positions.append(point)
            }
            result.vertices.append(index)
        }
        result.pinned = Array(repeating: false, count: result.positions.count)
        result.neighbors = Array(repeating: [], count: result.positions.count)
        var best = stamp.radius * stamp.radius
        var edges = Set<Edge>()
        for face in 0..<input.indices.count / 3 {
            if face.isMultiple(of: 256) { try Task.checkCancellation() }
            let start = face * 3
            let a = result.vertices[Int(input.indices[start])]
            let b = result.vertices[Int(input.indices[start + 1])]
            let c = result.vertices[Int(input.indices[start + 2])]
            let source = input.faceSources.isEmpty ? 0 : input.faceSources[face]
            if source == TrianglePatchClosure.closureSource {
                result.pinned[a] = true; result.pinned[b] = true; result.pinned[c] = true
            }
            guard source == stamp.sourceID else { continue }
            let first = result.positions[a], second = result.positions[b], third = result.positions[c]
            let normal = (second - first).cross(third - first)
            let length = normal.length
            guard length.isFinite, length > 0, normal.dot(axis) > length * 0.05 else { continue }
            let distance = squaredDistance(stamp.center, from: first, second, third, unitNormal: normal / length)
            if distance < best { best = distance; result.seed = [a, b, c] }
            for edge in [Edge(a, b), Edge(b, c), Edge(c, a)] where edges.insert(edge).inserted {
                result.neighbors[edge.first].append(edge.second)
                result.neighbors[edge.second].append(edge.first)
            }
        }
        return result
    }

    private static func squaredDistance(_ point: Vector3, from a: Vector3, _ b: Vector3, _ c: Vector3, unitNormal: Vector3) -> Float {
        let height = (point - a).dot(unitNormal)
        let projected = point - unitNormal * height
        if (b - a).cross(projected - a).dot(unitNormal) >= 0, (c - b).cross(projected - b).dot(unitNormal) >= 0,
            (a - c).cross(projected - c).dot(unitNormal) >= 0 {
            return height * height
        }
        func segment(_ first: Vector3, _ second: Vector3) -> Float {
            let edge = second - first, length = edge.squaredLength
            guard length > 0 else { return (point - first).squaredLength }
            let t = max(0, min(1, (point - first).dot(edge) / length))
            return (point - (first + edge * t)).squaredLength
        }
        return min(segment(a, b), segment(b, c), segment(c, a))
    }

    private static func hasUnflippedFaces(_ proposed: TriangleSurface, comparedTo original: TriangleSurface) throws -> Bool {
        func normal(_ surface: TriangleSurface, _ a: Int, _ b: Int, _ c: Int) -> Vector3 {
            (surface.positions[b] - surface.positions[a]).cross(surface.positions[c] - surface.positions[a])
        }
        for start in stride(from: 0, to: proposed.indices.count, by: 3) {
            if start.isMultiple(of: 768) { try Task.checkCancellation() }
            let a = Int(proposed.indices[start]), b = Int(proposed.indices[start + 1]), c = Int(proposed.indices[start + 2])
            if proposed.positions[a] == original.positions[a], proposed.positions[b] == original.positions[b], proposed.positions[c] == original.positions[c] { continue }
            let direction = normal(proposed, a, b, c)
            guard direction.squaredLength.isFinite, direction.dot(normal(original, a, b, c)) > 0 else { return false }
        }
        return true
    }
}
