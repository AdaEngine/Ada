import Math

/// Stackless, depth-first BVH. Escape indices make traversal independent of a shader stack size.
struct PathTracing3DBVH: Sendable {
    struct Triangle: Sendable {
        var vertices: [Vector4] // 12 texels: positions/material, normals, UVs for four maps.
        var minimum: Vector3 { min(vertices[0].xyz, min(vertices[1].xyz, vertices[2].xyz)) }
        var maximum: Vector3 { max(vertices[0].xyz, max(vertices[1].xyz, vertices[2].xyz)) }
    }
    struct Node: Sendable {
        var minimum: Vector3
        var maximum: Vector3
        var escape: Int
        var first: Int
        var count: Int
    }
    var nodes: [Node] = []
    var triangles: [Triangle] = []
    private var orderedInputs: [Int] = []

    init(_ input: [Triangle]) {
        guard !input.isEmpty else { return }
        var order = Array(input.indices)
        let minima = input.map(\.minimum), maxima = input.map(\.maximum)
        let centers = input.indices.map { (minima[$0]+maxima[$0])*0.5 }
        func build(_ lower: Int, _ upper: Int) {
            var lo = Vector3(Float.greatestFiniteMagnitude), hi = -lo
            var cLo = lo, cHi = hi
            for i in lower..<upper {
                let source = order[i], center = centers[source]
                lo = min(lo, minima[source]); hi = max(hi, maxima[source])
                cLo = min(cLo, center); cHi = max(cHi, center)
            }
            let index = nodes.count
            nodes.append(Node(minimum: lo, maximum: hi, escape: 0, first: 0, count: 0))
            if upper-lower <= 4 {
                nodes[index].first = triangles.count
                nodes[index].count = upper-lower
                for i in lower..<upper { triangles.append(input[order[i]]); orderedInputs.append(order[i]) }
            } else {
                let span = cHi-cLo
                let axis = span.x >= span.y && span.x >= span.z ? 0 : (span.y >= span.z ? 1 : 2)
                func coordinate(_ i: Int) -> Float {
                    let c = centers[i]
                    return axis == 0 ? c.x : (axis == 1 ? c.y : c.z)
                }
                let sorted = order[lower..<upper].sorted { coordinate($0) < coordinate($1) }
                order.replaceSubrange(lower..<upper, with: sorted)
                let middle = (lower+upper)/2
                build(lower, middle); build(middle, upper)
            }
            nodes[index].escape = nodes.count
        }
        build(0, input.count)
    }

    /// A refit preserves triangle coverage even if positions or input order change.
    /// Rebuilds handle count changes; animated poses avoid sorting the whole static world every frame.
    mutating func refit(_ input: [Triangle]) {
        guard input.count == orderedInputs.count, !nodes.isEmpty else { self = Self(input); return }
        triangles = orderedInputs.map { input[$0] }
        for index in nodes.indices.reversed() {
            let node = nodes[index]
            if node.count > 0 {
                var lo = Vector3(Float.greatestFiniteMagnitude), hi = -lo
                for triangle in triangles[node.first..<(node.first+node.count)] {
                    lo = min(lo,triangle.minimum); hi = max(hi,triangle.maximum)
                }
                nodes[index].minimum = lo; nodes[index].maximum = hi
            } else {
                let left = index+1, right = nodes[left].escape
                nodes[index].minimum = min(nodes[left].minimum,nodes[right].minimum)
                nodes[index].maximum = max(nodes[left].maximum,nodes[right].maximum)
            }
        }
    }

    var packedNodes: [Vector4] {
        nodes.flatMap { [Vector4($0.minimum, Float($0.escape)), Vector4($0.maximum, Float($0.first)), Vector4(Float($0.count), 0, 0, 0)] }
    }
}
