import AdaRender
import Math

/// Prepares one adaptive level for compact, locally smooth terrain triangle groups.
enum MeshTerrainMeshletLOD {
    private struct Edge: Hashable {
        let a: UInt32
        let b: UInt32

        init(_ a: UInt32, _ b: UInt32) {
            self.a = min(a, b)
            self.b = max(a, b)
        }
    }

    private struct Approximation {
        let indices: [UInt32]
        let error: Float
    }

    static func prepare(_ descriptor: inout MeshDescriptor, maximumBytes: Int) throws -> Int {
        let source = descriptor.indicies
        let positions = descriptor.positions.elements
        guard (96...73_728).contains(source.count), source.count * 96 + positions.count * 32 <= maximumBytes else { return 0 }
        let base = try MeshletGeometry.scan(positions: positions, indices: source)
        var incident: [UInt32: Int] = [:]
        var edges: Set<Edge> = []
        for offset in stride(from: 0, to: source.count, by: 3) {
            for corner in 0..<3 {
                let vertex = source[offset + corner]
                incident[vertex, default: 0] += 1
                edges.insert(.init(vertex, source[offset + (corner + 1) % 3]))
            }
        }
        var clusters: [MeshletCluster] = []
        var indices: [UInt32] = []
        var nodes: [MeshletLODNode] = []
        var roots: [Int] = []
        var hasReduction = false
        let clustersPerLeaf = 4
        let clustersPerGroup = clustersPerLeaf * 4
        for groupStart in stride(from: 0, to: base.clusters.count, by: clustersPerGroup) {
            try Task.checkCancellation()
            let groupEnd = min(groupStart + clustersPerGroup, base.clusters.count)
            let group = base.clusters[groupStart..<groupEnd]
            let sourceRange = span(group)
            let childCount = (group.count + clustersPerLeaf - 1) / clustersPerLeaf
            let parent = childCount > 1 ? reduce(source[sourceRange], positions: positions, incident: incident, edges: &edges) : nil
            let firstChild = nodes.count
            for first in stride(from: groupStart, to: groupEnd, by: clustersPerLeaf) {
                let children = base.clusters[first..<min(first + clustersPerLeaf, groupEnd)]
                let bounds = bounds(of: children)
                let range = span(children)
                let firstCluster = clusters.count
                for cluster in children {
                    let firstIndex = indices.count
                    indices.append(contentsOf: source[cluster.firstIndex..<(cluster.firstIndex + cluster.indexCount)])
                    clusters.append(.init(firstIndex: firstIndex, indexCount: cluster.indexCount, minimum: cluster.minimum, maximum: cluster.maximum))
                }
                if parent == nil { roots.append(nodes.count) }
                nodes.append(.init(parent: parent == nil ? nil : firstChild + childCount, firstChild: 0, childCount: 0,
                    firstCluster: firstCluster, clusterCount: children.count, minimum: bounds.0, maximum: bounds.1, error: 0,
                    firstSourceIndex: range.lowerBound, sourceIndexCount: range.count))
            }
            guard let parent else { continue }
            hasReduction = true
            // A parent cluster never straddles another node's index span.
            let firstCluster = clusters.count
            for start in stride(from: 0, to: parent.indices.count, by: 63) {
                let triangleIndices = parent.indices[start..<min(start + 63, parent.indices.count)]
                let first = indices.count
                var lower = Vector3(Float.greatestFiniteMagnitude), upper = -lower
                for index in triangleIndices {
                    let point = positions[Int(index)]
                    lower = min(lower, point)
                    upper = max(upper, point)
                }
                clusters.append(.init(firstIndex: first, indexCount: triangleIndices.count, minimum: lower, maximum: upper))
                indices.append(contentsOf: triangleIndices)
            }
            let box = bounds(of: group)
            roots.append(nodes.count)
            nodes.append(.init(parent: nil, firstChild: firstChild, childCount: childCount,
                firstCluster: firstCluster, clusterCount: clusters.count - firstCluster,
                minimum: box.0, maximum: box.1, error: max(parent.error, (box.1 - box.0).length * 0.005),
                firstSourceIndex: sourceRange.lowerBound, sourceIndexCount: sourceRange.count, level: 1))
        }
        guard hasReduction else { return 0 }
        let geometry = try MeshletGeometry(clusters: clusters, indices: indices, positions: positions)
        descriptor.meshletLOD = try MeshletLODGeometry(positions: positions, sourceIndices: source,
            geometry: geometry, nodes: nodes, roots: roots, automaticPixelError: 2)
        return bytes(for: descriptor.meshletLOD)
    }

    static func bytes(for lod: MeshletLODGeometry?) -> Int {
        guard let lod else { return 0 }
        return lod.geometry.indices.count * MemoryLayout<UInt32>.stride * 2
            + lod.geometry.clusters.count * MemoryLayout<MeshletCluster>.stride + lod.nodes.count * MemoryLayout<MeshletLODNode>.stride
            + lod.roots.count * MemoryLayout<Int>.stride
    }

    private static func span(_ clusters: ArraySlice<MeshletCluster>) -> Range<Int> {
        let first = clusters[clusters.startIndex], last = clusters[clusters.endIndex - 1]
        return first.firstIndex..<(last.firstIndex + last.indexCount)
    }

    private static func bounds(of clusters: ArraySlice<MeshletCluster>) -> (Vector3, Vector3) {
        var lo = Vector3(Float.greatestFiniteMagnitude), hi = -lo
        for cluster in clusters { lo = min(lo, cluster.minimum); hi = max(hi, cluster.maximum) }
        return (lo, hi)
    }

    private static func reduce(_ source: ArraySlice<UInt32>, positions: [Vector3], incident: [UInt32: Int],
                               edges: inout Set<Edge>) -> Approximation? {
        var fans: [UInt32: [Int]] = [:]
        for offset in stride(from: source.startIndex, to: source.endIndex, by: 3) {
            for vertex in source[offset..<(offset + 3)] { fans[vertex, default: []].append(offset) }
        }
        var removed: Set<Int> = []
        var result: [UInt32] = []
        var maximumError: Float = 0
        for vertex in fans.keys.sorted() {
            guard let faces = fans[vertex], (4...8).contains(faces.count), incident[vertex] == faces.count,
                faces.allSatisfy({ !removed.contains($0) }), let ring = ring(around: vertex, faces: faces, source: source),
                let error = error(around: vertex, ring: ring, positions: positions) else { continue }
            let anchor = ring[0]
            let diagonals = ring.dropFirst(2).dropLast().map { Edge(anchor, $0) }
            guard diagonals.allSatisfy({ !edges.contains($0) }) else { continue }
            edges.formUnion(diagonals)
            removed.formUnion(faces)
            maximumError = max(maximumError, error)
            for i in 1..<(ring.count - 1) { result.append(contentsOf: [anchor, ring[i], ring[i + 1]]) }
        }
        guard !removed.isEmpty else { return nil }
        for offset in stride(from: source.startIndex, to: source.endIndex, by: 3) where !removed.contains(offset) {
            result.append(contentsOf: source[offset..<(offset + 3)])
        }
        return .init(indices: result, error: maximumError)
    }

    private static func ring(around center: UInt32, faces: [Int], source: ArraySlice<UInt32>) -> [UInt32]? {
        var next: [UInt32: UInt32] = [:]
        for offset in faces {
            guard let corner = (0..<3).first(where: { source[offset + $0] == center }) else { return nil }
            let a = source[offset + (corner + 1) % 3], b = source[offset + (corner + 2) % 3]
            guard a != b, a != center, b != center, next.updateValue(b, forKey: a) == nil else { return nil }
        }
        guard let first = next.keys.min() else { return nil }
        var ring: [UInt32] = []
        var current = first
        while let successor = next.removeValue(forKey: current) {
            ring.append(current)
            current = successor
        }
        return next.isEmpty && current == first ? ring : nil
    }

    private static func error(around center: UInt32, ring: [UInt32], positions: [Vector3]) -> Float? {
        let origin = positions[Int(center)]
        let points = ring.map { positions[Int($0)] - origin }
        let cross = points[0].cross(points[1])
        let scale = points.map(\.length).min() ?? 0
        guard scale.isFinite, scale > 0, cross.length.isFinite, cross.length > 0 else { return nil }
        let normal = cross.normalized
        let error = points.map { abs($0.dot(normal)) }.max() ?? 0
        guard error <= scale * 0.06 else { return nil }
        let tolerance = scale * scale * 0.00001
        for i in points.indices {
            let a = points[i], b = points[(i + 1) % points.count]
            // A strictly convex projected ring preserves its covered region
            // and winding with either triangulation, including the original fan.
            guard a.cross(b).dot(normal) > tolerance else { return nil }
            for j in points.indices where j != i && j != (i + 1) % points.count {
                guard (b - a).cross(points[j] - a).dot(normal) > tolerance else { return nil }
            }
        }
        // Both surfaces cover the same polygon and stay within this plane slab.
        return error * 2
    }
}
