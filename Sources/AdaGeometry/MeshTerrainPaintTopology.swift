import Math

struct MeshTerrainPaintBrush {
    let stamp: MeshTerrainPaintStamp
    let hit: TriangleSurfaceHit
    let source: UInt32
    let normal: Vector3
}

struct MeshTerrainPaintTopology {
    typealias Layer = MeshTerrainCompiledPaint.Sample.Layer
    private struct Edge: Hashable {
        let first: Int
        let second: Int
        let owner: UInt32
    }
    private let points: [Vector3]
    private let sources: [UInt32]
    private let normals: [Vector3]
    private let across: [SIMD2<Int>]

    init(surface: TriangleSurface, work: inout TriangleSurfaceQueryBudget) throws {
        try work.charge(surface.positions.count + surface.indices.count * 5)
        var welded: [Vector3: Int] = [:], vertexIDs: [Int] = []
        vertexIDs.reserveCapacity(surface.positions.count)
        for point in surface.positions {
            if vertexIDs.count.isMultiple(of: 256) { try Task.checkCancellation() }
            if let previous = welded[point] { vertexIDs.append(previous) }
            else { let id = welded.count; welded[point] = id; vertexIDs.append(id) }
        }
        points = surface.indices.map { surface.positions[Int($0)] }
        sources = surface.faceSources
        var normals: [Vector3] = []
        var firstCornerByEdge: [Edge: Int] = [:]
        var links = [SIMD2<Int>](repeating: .init(repeating: -1), count: points.count)
        for start in stride(from: 0, to: points.count, by: 3) {
            if start.isMultiple(of: 768) { try Task.checkCancellation() }
            let normal = (points[start + 1] - points[start]).cross(points[start + 2] - points[start])
            let length = normal.length
            normals.append(length.isFinite && length > 0 ? normal / length : .zero)
            for corner in start..<(start + 3) {
                let next = Self.next(corner)
                let a = vertexIDs[Int(surface.indices[corner])], b = vertexIDs[Int(surface.indices[next])]
                let edge = Edge(first: min(a, b), second: max(a, b), owner: sources.isEmpty ? 0 : sources[start / 3])
                if let previous = firstCornerByEdge[edge] {
                    guard previous >= 0 else { continue }
                    let end = Self.next(previous)
                    if links[previous].x >= 0 || links[end].y >= 0 {
                        let linked = links[previous].x, linkedEnd = links[end].y
                        if linked >= 0 { links[linked].y = -1 }
                        if linkedEnd >= 0 { links[linkedEnd].x = -1 }
                        links[previous].x = -1; links[end].y = -1
                        firstCornerByEdge[edge] = -1
                    } else if points[previous] == points[next], points[end] == points[corner] {
                        links[previous].x = next; links[end].y = corner
                        links[corner].x = end; links[next].y = previous
                    } else { firstCornerByEdge[edge] = -1 }
                } else { firstCornerByEdge[edge] = corner }
            }
        }
        self.normals = normals
        across = links
    }

    func apply(
        _ brush: MeshTerrainPaintBrush,
        samples: inout [Int: [Layer]],
        sampleLimit: Int,
        work: inout TriangleSurfaceQueryBudget
    ) throws -> Bool {
        try work.charge(points.count)
        var distance = [Float](repeating: .infinity, count: points.count)
        var queue = CornerHeap()
        func visit(_ corner: Int, at value: Float) throws {
            guard value < brush.stamp.radius, value < distance[corner],
                (sources.isEmpty ? 0 : sources[corner / 3]) == brush.source,
                normals[corner / 3].dot(brush.normal) >= 0.5 else { return }
            guard queue.count < points.count * 4 else { throw TriangleGeometryError.budgetExceeded }
            distance[corner] = value
            queue.push(.init(corner: corner, distance: value))
        }
        let start = brush.hit.triangleIndex * 3
        for corner in start..<(start + 3) {
            try visit(corner, at: (points[corner] - brush.hit.position).length)
        }
        var reached = false
        while let item = queue.pop() {
            try work.charge()
            let corner = item.corner
            guard distance[corner] == item.distance else { continue }
            reached = true
            let t = 1 - item.distance / brush.stamp.radius
            let amount = t * t * (3 - 2 * t) * brush.stamp.strength
            try Self.write(brush.stamp.operation, amount: amount, at: corner, to: &samples, sampleLimit: sampleLimit, work: &work)
            let next = Self.next(corner), previous = Self.next(next)
            try visit(next, at: item.distance + (points[corner] - points[next]).length)
            try visit(previous, at: item.distance + (points[corner] - points[previous]).length)
            if across[corner].x >= 0 { try visit(across[corner].x, at: item.distance) }
            if across[corner].y >= 0 { try visit(across[corner].y, at: item.distance) }
        }
        return reached
    }

    private static func write(
        _ operation: MeshTerrainPaintStamp.Operation, amount: Float, at corner: Int, to samples: inout [Int: [Layer]],
        sampleLimit: Int, work: inout TriangleSurfaceQueryBudget
    ) throws {
        guard amount > 0 else { return }
        var values = samples[corner] ?? []
        try work.charge(values.count + 1)
        switch operation {
        case let .paint(layer):
            guard samples[corner] != nil || samples.count < sampleLimit else { throw TriangleGeometryError.budgetExceeded }
            for index in values.indices { values[index].weight *= 1 - amount }
            values.removeAll { $0.weight <= 0 }
            let index = values.firstIndex { $0.id >= layer } ?? values.endIndex
            if index < values.endIndex, values[index].id == layer { values[index].weight += amount }
            else {
                guard values.count < 32 else { throw TriangleGeometryError.budgetExceeded }
                values.insert(.init(id: layer, weight: amount), at: index)
            }
        case .erase:
            let coverage = values.reduce(Float(0)) { $0 + $1.weight }
            if coverage <= amount { samples.removeValue(forKey: corner); return }
            let retained = (coverage - amount) / coverage
            for index in values.indices { values[index].weight *= retained }
            values.removeAll { $0.weight <= 0 }
        }
        samples[corner] = values.isEmpty ? nil : values
    }

    private static func next(_ corner: Int) -> Int { corner.isMultiple(of: 3) ? corner + 1 : (corner % 3 == 1 ? corner + 1 : corner - 2) }
}

private struct CornerHeap {
    struct Item {
        let corner: Int
        let distance: Float

        func precedes(_ other: Self) -> Bool {
            distance < other.distance || (distance == other.distance && corner < other.corner)
        }
    }

    private var items: [Item] = []
    var count: Int { items.count }

    mutating func push(_ item: Item) {
        var index = items.count
        items.append(item)
        while index > 0 {
            let parent = (index - 1) / 2
            if !items[index].precedes(items[parent]) { break }
            items.swapAt(index, parent)
            index = parent
        }
    }

    mutating func pop() -> Item? {
        guard let last = items.popLast() else { return nil }
        guard !items.isEmpty else { return last }
        let first = items[0]
        items[0] = last
        var index = 0
        while index * 2 + 1 < items.count {
            let left = index * 2 + 1, right = left + 1
            let child = right < items.count && items[right].precedes(items[left]) ? right : left
            if !items[child].precedes(items[index]) { break }
            items.swapAt(index, child)
            index = child
        }
        return first
    }
}
