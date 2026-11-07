/// A zero-width sampled contact can place independent surface fans at one position.
/// Keep their geometry but give each fan its own vertex identity and shading normal.
enum ScalarSurfaceFans {
    static func separate(positions: inout [Vector3], indices: inout [UInt32]) throws {
        var builder = ScalarFanBuilder(indices: indices)
        try builder.pairEdges(positions: positions)
        try builder.apply(positions: &positions, indices: &indices)
    }
}

private struct ScalarFanBuilder {
    private struct Candidate {
        let first: Int
        let second: Int
        let score: Double
    }

    private let source: [UInt32]
    private var parents: [Int]
    private var remaining = 8_388_608

    init(indices: [UInt32]) {
        source = indices; parents = Array(indices.indices)
    }

    mutating func pairEdges(positions: [Vector3]) throws {
        var heads: [UInt64: Int] = [:]
        var next = [Int](repeating: -1, count: source.count)
        for edge in source.indices {
            try spend()
            let a = source[edge], b = source[end(edge)]
            let key = (UInt64(min(a, b)) << 32) | UInt64(max(a, b))
            next[edge] = heads[key] ?? -1; heads[key] = edge
        }
        for first in heads.values {
            try spend()
            let second = next[first]
            if second < 0 { continue }
            if next[second] < 0 {
                guard source[first] != source[second] else { throw ScalarFieldSurfaceError.unsupportedTopology }
                try join(first, second)
            } else {
                var forward: [Int] = [], backward: [Int] = []
                var edge = first
                while edge >= 0 {
                    try spend()
                    if source[edge] < source[end(edge)] { forward.append(edge) } else { backward.append(edge) }
                    edge = next[edge]
                }
                guard forward.count == backward.count else { throw ScalarFieldSurfaceError.unsupportedTopology }
                // A bounded 32-cell tetrahedral grid has at most 96 incident faces at a sample.
                guard forward.count <= 192 else { throw ScalarFieldSurfaceError.topologyBudgetExceeded }
                try pairContact(forward.sorted(), backward.sorted(), positions: positions)
            }
        }
    }

    private mutating func pairContact(_ forward: [Int], _ backward: [Int], positions: [Vector3]) throws {
        var candidates: [Candidate] = []
        for first in forward.indices {
            let a = normal(forward[first], positions: positions)
            for second in backward.indices {
                try spend()
                let b = normal(backward[second], positions: positions)
                candidates.append(.init(first: first, second: second, score: a.x * b.x + a.y * b.y + a.z * b.z))
            }
        }
        candidates.sort {
            if $0.score != $1.score {
                return $0.score > $1.score
            }
            if $0.first != $1.first {
                return $0.first < $1.first
            }
            return $0.second < $1.second
        }
        var usedForward = [Bool](repeating: false, count: forward.count), usedBackward = [Bool](repeating: false, count: backward.count)
        for candidate in candidates {
            try spend()
            guard !usedForward[candidate.first], !usedBackward[candidate.second] else { continue }
            try join(forward[candidate.first], backward[candidate.second])
            usedForward[candidate.first] = true; usedBackward[candidate.second] = true
        }
    }

    private mutating func join(_ first: Int, _ second: Int) throws {
        let otherStart = source[first] == source[second] ? second : end(second)
        let otherEnd = otherStart == second ? end(second) : second
        try merge(first, otherStart)
        try merge(end(first), otherEnd)
    }

    mutating func apply(positions: inout [Vector3], indices: inout [UInt32]) throws {
        var firstFan = [Int](repeating: -1, count: positions.count)
        var mapped: [Int: UInt32] = [:]
        for corner in source.indices {
            let fan = try root(corner), original = source[corner]
            let vertex: UInt32
            if let existing = mapped[fan] {
                vertex = existing
            } else {
                if firstFan[Int(original)] < 0 {
                    firstFan[Int(original)] = fan; vertex = original
                } else {
                    vertex = UInt32(positions.count)
                    positions.append(positions[Int(original)])
                }
                mapped[fan] = vertex
            }
            if indices[corner] != vertex { indices[corner] = vertex }
        }
    }

    private mutating func merge(_ first: Int, _ second: Int) throws {
        let a = try root(first), b = try root(second)
        parents[max(a, b)] = min(a, b)
    }

    private mutating func root(_ index: Int) throws -> Int {
        try spend()
        var result = index
        while parents[result] != result { try spend(); result = parents[result] }
        var point = index
        while parents[point] != point {
            let next = parents[point]; parents[point] = result; point = next
        }
        return result
    }

    private mutating func spend() throws {
        guard remaining > 0 else { throw ScalarFieldSurfaceError.topologyBudgetExceeded }
        if remaining.isMultiple(of: 256) { try Task.checkCancellation() }
        remaining -= 1
    }

    private func end(_ edge: Int) -> Int { edge - edge % 3 + (edge + 1) % 3 }

    private func normal(_ edge: Int, positions: [Vector3]) -> SIMD3<Double> {
        let start = edge - edge % 3
        let a = positions[Int(source[start])], b = positions[Int(source[start + 1])], c = positions[Int(source[start + 2])]
        let value = ScalarTriangleGeometry.normal(a, b, c)
        let length = (value.x * value.x + value.y * value.y + value.z * value.z).squareRoot()
        return value / length
    }
}
