struct ScalarMeshWork {
    private var remaining: Int
    var available: Int { remaining }
    init(_ maximum: Int) throws {
        guard maximum >= 0 else { throw ScalarMeshSolidError.workBudgetExceeded }
        remaining = maximum
        try Task.checkCancellation()
    }

    mutating func spend(_ count: Int = 1) throws {
        guard count >= 0, count <= remaining else { throw ScalarMeshSolidError.workBudgetExceeded }
        if remaining.isMultiple(of: 256) || count >= 256 { try Task.checkCancellation() }
        remaining -= count
    }
}

struct ScalarMeshNode: Sendable {
    let low: ScalarMeshPoint
    let high: ScalarMeshPoint
    var end: Int
    let start: Int
    let count: Int

    func overlaps(_ low: ScalarMeshPoint, _ high: ScalarMeshPoint) -> Bool {
        self.low.x <= high.x && self.high.x >= low.x && self.low.y <= high.y && self.high.y >= low.y && self.low.z <= high.z && self.high.z >= low.z
    }

    func squaredDistance(_ point: ScalarMeshPoint) -> Double {
        let d = SIMD3(max(low.x - point.x, max(point.x - high.x, 0)), max(low.y - point.y, max(point.y - high.y, 0)), max(low.z - point.z, max(point.z - high.z, 0)))
        return scalarMeshDot(d, d)
    }

    func intersectsRay(_ origin: ScalarMeshPoint, _ direction: ScalarMeshPoint) -> Bool {
        var near = 0.0, far = Double.infinity
        for axis in 0..<3 {
            let first = (low[axis] - origin[axis]) / direction[axis], second = (high[axis] - origin[axis]) / direction[axis]
            near = max(near, min(first, second)); far = min(far, max(first, second))
        }
        return near <= far
    }
}

/// Flat depth-first BVH; subtree end indices permit allocation-free query traversal.
struct ScalarMeshHierarchy: Sendable {
    private static let directions: [ScalarMeshPoint] = [SIMD3(1, 0.371, 0.529), SIMD3(0.613, 1, 0.297), SIMD3(0.193, 0.719, 1), SIMD3(-1, 0.457, 0.831)]
    private(set) var triangles: [ScalarMeshTriangle]
    private(set) var nodes: [ScalarMeshNode] = []

    init(triangles: [ScalarMeshTriangle], work: inout ScalarMeshWork) throws {
        self.triangles = triangles
        try build(start: 0, count: triangles.count, work: &work)
    }

    private mutating func build(start: Int, count: Int, work: inout ScalarMeshWork) throws {
        try work.spend(count)
        var low = triangles[start].low, high = triangles[start].high
        for index in (start + 1)..<(start + count) {
            let triangle = triangles[index]
            for axis in 0..<3 { low[axis] = min(low[axis], triangle.low[axis]); high[axis] = max(high[axis], triangle.high[axis]) }
        }
        let node = nodes.count
        nodes.append(.init(low: low, high: high, end: node + 1, start: start, count: count <= 8 ? count : 0))
        if count > 8 {
            let extent = high - low
            let axis = extent.x >= extent.y && extent.x >= extent.z ? 0 : extent.y >= extent.z ? 1 : 2
            var levels = 0, size = count
            while size > 1 { levels += 1; size = (size + 1) / 2 }
            try work.spend(count * levels)
            let sorted = triangles[start..<(start + count)].sorted {
                let a = $0.low[axis] + $0.high[axis], b = $1.low[axis] + $1.high[axis]
                if a != b {
                    return a < b
                }
                if $0.ids.x != $1.ids.x {
                    return $0.ids.x < $1.ids.x
                }
                if $0.ids.y != $1.ids.y {
                    return $0.ids.y < $1.ids.y
                }
                return $0.ids.z < $1.ids.z
            }
            triangles.replaceSubrange(start..<(start + count), with: sorted)
            let left = count / 2
            try build(start: start, count: left, work: &work)
            try build(start: start + left, count: count - left, work: &work)
        }
        nodes[node].end = nodes.count
    }

    func validateIntersections(work: inout ScalarMeshWork) throws {
        for first in triangles.indices {
            let triangle = triangles[first]
            var cursor = 0
            while cursor < nodes.count {
                try work.spend()
                let node = nodes[cursor]
                if !node.overlaps(triangle.low, triangle.high) { cursor = node.end; continue }
                for second in node.start..<(node.start + node.count) where second > first {
                    try work.spend()
                    let other = triangles[second]
                    if other.low.x > triangle.high.x || other.high.x < triangle.low.x || other.low.y > triangle.high.y || other.high.y < triangle.low.y
                        || other.low.z > triangle.high.z || other.high.z < triangle.low.z { continue }
                    if ScalarMeshIntersection.overlaps(triangle, other) { throw ScalarMeshSolidError.selfIntersection }
                }
                cursor += 1
            }
        }
    }

    func squaredDistance(_ point: ScalarMeshPoint, work: inout ScalarMeshWork) throws -> Double {
        var best = Double.infinity, cursor = 0
        while cursor < nodes.count {
            try work.spend()
            let node = nodes[cursor]
            if node.squaredDistance(point) > best { cursor = node.end; continue }
            for index in node.start..<(node.start + node.count) {
                try work.spend()
                best = min(best, triangles[index].squaredDistance(point))
            }
            cursor += 1
        }
        return best
    }

    func isInside(_ point: ScalarMeshPoint, work: inout ScalarMeshWork) throws -> Bool {
        // A ray touching an edge is retried, rather than counting two faces or guessing.
        for direction in Self.directions {
            var count = 0, cursor = 0, ambiguous = false
            while cursor < nodes.count && !ambiguous {
                try work.spend()
                let node = nodes[cursor]
                if !node.intersectsRay(point, direction) { cursor = node.end; continue }
                for index in node.start..<(node.start + node.count) {
                    try work.spend()
                    guard let hit = triangles[index].rayHit(origin: point, direction: direction) else { ambiguous = true; break }
                    if hit { count += 1 }
                }
                cursor += 1
            }
            if !ambiguous {
                return !count.isMultiple(of: 2)
            }
        }
        throw ScalarMeshSolidError.ambiguousSample
    }
}
