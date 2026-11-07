import AdaGeometry
import Foundation
import Math

struct MeshTerrainLayerContact {
    var automatic: Float = 1
    var weights = SIMD32<Float>(repeating: 0)

    mutating func apply(layer: Int, strength: Float) {
        automatic *= 1 - strength
        weights *= 1 - strength
        weights[layer] += strength
    }
}

/// A finite geodesic band on the base sheet, seeded only where a joined
/// source shares an edge with that sheet. Disconnected layers cannot borrow paint.
struct MeshTerrainContactField {
    struct Writer {
        let source: UInt32
        let layer: Int
        let width: Float
    }

    private struct Edge: Hashable {
        let a: Int
        let b: Int

        init(_ first: Int, _ second: Int) {
            a = min(first, second)
            b = max(first, second)
        }
    }

    private let welded: [Int]
    private let contacts: [MeshTerrainLayerContact]

    static func build(_ surface: TriangleSurface, writers: [Writer], maximumBytes: Int, work: inout Int) throws -> Self? {
        guard !surface.faceSources.isEmpty, !writers.isEmpty else { return nil }
        let bytes = surface.positions.count * 320 + surface.indices.count * 112
        guard bytes <= maximumBytes else { throw TerrainSourceError.meshBudgetExceeded }
        try charge(surface.positions.count + surface.indices.count * 2, work: &work)
        var vertices: [Vector3] = [], indexByPosition: [Vector3: Int] = [:], welded: [Int] = []
        for position in surface.positions {
            if welded.count.isMultiple(of: 256) { try Task.checkCancellation() }
            if let index = indexByPosition[position] {
                welded.append(index)
            } else {
                indexByPosition[position] = vertices.count
                welded.append(vertices.count)
                vertices.append(position)
            }
        }
        var ground: Set<Edge> = []
        var neighbors = [[Int]](repeating: [], count: vertices.count)
        for face in surface.faceSources.indices where surface.faceSources[face] == 0 {
            if face.isMultiple(of: 256) { try Task.checkCancellation() }
            for corner in 0..<3 {
                let edge = edge(surface, welded: welded, face: face, corner: corner)
                if edge.a != edge.b, ground.insert(edge).inserted {
                    neighbors[edge.a].append(edge.b)
                    neighbors[edge.b].append(edge.a)
                }
            }
        }
        guard !ground.isEmpty else { return nil }
        let sources = Set(writers.map(\.source))
        var seeds: [UInt32: Set<Int>] = [:]
        for (face, source) in surface.faceSources.enumerated() where sources.contains(source) {
            if face.isMultiple(of: 256) { try Task.checkCancellation() }
            for corner in 0..<3 {
                let edge = edge(surface, welded: welded, face: face, corner: corner)
                if ground.contains(edge) {
                    seeds[source, default: []].insert(edge.a)
                    seeds[source, default: []].insert(edge.b)
                }
            }
        }
        guard !seeds.isEmpty else { return nil }
        var contacts = [MeshTerrainLayerContact](repeating: .init(), count: vertices.count)
        for writer in writers {
            guard let seeds = seeds[writer.source] else { continue }
            try Task.checkCancellation()
            try charge(vertices.count + seeds.count, work: &work)
            let distances = try distances(from: seeds, within: writer.width, vertices: vertices, neighbors: neighbors, work: &work)
            for (vertex, distance) in distances.enumerated() where distance < writer.width {
                let t = 1 - distance / writer.width
                contacts[vertex].apply(layer: writer.layer, strength: t * t * (3 - 2 * t))
            }
        }
        return .init(welded: welded, contacts: contacts)
    }

    func contact(at vertex: Int) -> MeshTerrainLayerContact { contacts[welded[vertex]] }

    private static func edge(_ surface: TriangleSurface, welded: [Int], face: Int, corner: Int) -> Edge {
        .init(welded[Int(surface.indices[face * 3 + corner])], welded[Int(surface.indices[face * 3 + (corner + 1) % 3])])
    }

    private static func distances(from seeds: Set<Int>, within width: Float, vertices: [Vector3], neighbors: [[Int]], work: inout Int) throws -> [Float] {
        // A vertex has at most one pending queue entry. A separate work limit
        // bounds repeated relaxations on poorly shaped triangles.
        var distance = [Float](repeating: .infinity, count: vertices.count)
        var pending = [Bool](repeating: false, count: vertices.count)
        var queue = [Int](repeating: 0, count: vertices.count)
        var head = 0, tail = 0, count = 0
        func enqueue(_ vertex: Int) {
            if pending[vertex] { return }
            queue[tail] = vertex
            tail = (tail + 1) % vertices.count
            count += 1
            pending[vertex] = true
        }
        for seed in seeds.sorted() { distance[seed] = 0; enqueue(seed) }
        var iterations = 0
        while count > 0 {
            if iterations.isMultiple(of: 256) { try Task.checkCancellation() }
            iterations += 1
            let vertex = queue[head]
            head = (head + 1) % vertices.count
            count -= 1
            pending[vertex] = false
            try charge(1 + neighbors[vertex].count, work: &work)
            for next in neighbors[vertex] {
                let candidate = distance[vertex] + (vertices[vertex] - vertices[next]).length
                if candidate < width, candidate < distance[next] {
                    distance[next] = candidate
                    enqueue(next)
                }
            }
        }
        return distance
    }

    private static func charge(_ amount: Int, work: inout Int) throws {
        guard amount <= work else { throw TerrainSourceError.meshBudgetExceeded }
        work -= amount
    }
}
