import Foundation
import Math

/// One hierarchy node owns a complete approximation of its original source span.
/// A render cut selects either this node or its descendants, never both.
public struct MeshletLODNode: Sendable {
    public let parent: Int?
    public let firstChild: Int
    public let childCount: Int
    public let firstCluster: Int
    public let clusterCount: Int
    public let firstSourceIndex: Int
    public let sourceIndexCount: Int
    public let minimum: Vector3
    public let maximum: Vector3
    /// Cumulative absolute simplification error plus the offline conservative visual-error floor.
    public let error: Float
    public let level: Int

    public init(parent: Int?, firstChild: Int, childCount: Int, firstCluster: Int, clusterCount: Int,
                minimum: Vector3, maximum: Vector3, error: Float, firstSourceIndex: Int, sourceIndexCount: Int, level: Int = 0) {
        self.parent = parent
        self.firstChild = firstChild
        self.childCount = childCount
        self.firstCluster = firstCluster
        self.clusterCount = clusterCount
        self.firstSourceIndex = firstSourceIndex
        self.sourceIndexCount = sourceIndexCount
        self.minimum = minimum
        self.maximum = maximum
        self.error = error
        self.level = level
    }
}

/// Immutable adaptive LOD forest. The flat geometry contains every node's own approximation;
/// `baseIndexCount` bounds the output capacity of every valid nonoverlapping cut.
public struct MeshletLODGeometry: Sendable {
    public let id: UUID
    public let geometry: MeshletGeometry
    public let nodes: [MeshletLODNode]
    public let roots: [Int]
    public let sourceDigest: UInt64
    public let baseIndexCount: Int
    public let vertexCount: Int

    public init(positions: [Vector3], sourceIndices: [UInt32], geometry: MeshletGeometry, nodes: [MeshletLODNode], roots: [Int]) throws {
        guard geometry.matches(positions: positions, indices: geometry.indices), sourceIndices.count % 3 == 0,
            sourceIndices.allSatisfy({ value in Int(exactly: value).map { $0 < positions.count } == true }),
            nodes.count <= 1_000_000, roots.count <= nodes.count else { throw MeshletDataError.invalidGeometry }
        var expectedCluster = 0
        var childrenUsed = Set<Int>()
        for (index, node) in nodes.enumerated() {
            guard node.firstCluster == expectedCluster, node.clusterCount > 0,
                node.firstCluster >= 0, node.clusterCount <= geometry.clusters.count - expectedCluster,
                node.firstSourceIndex >= 0, node.firstSourceIndex <= sourceIndices.count,
                node.sourceIndexCount > 0, node.sourceIndexCount % 3 == 0,
                node.sourceIndexCount <= sourceIndices.count - node.firstSourceIndex,
                node.minimum.x.isFinite, node.minimum.y.isFinite, node.minimum.z.isFinite,
                node.maximum.x.isFinite, node.maximum.y.isFinite, node.maximum.z.isFinite,
                node.minimum.x <= node.maximum.x, node.minimum.y <= node.maximum.y, node.minimum.z <= node.maximum.z,
                node.error.isFinite, node.error >= 0, node.level >= 0, node.level <= 32
            else { throw MeshletDataError.invalidClusters }
            if let parent = node.parent { guard parent > index && parent < nodes.count else { throw MeshletDataError.invalidClusters } }
            let clusterEnd = node.firstCluster + node.clusterCount
            let first = geometry.clusters[node.firstCluster].firstIndex
            let last = geometry.clusters[clusterEnd - 1]
            let end = last.firstIndex + last.indexCount
            guard end - first <= node.sourceIndexCount else { throw MeshletDataError.invalidClusters }
            for cluster in geometry.clusters[node.firstCluster..<clusterEnd] {
                guard Self.contains(node, minimum: cluster.minimum, maximum: cluster.maximum) else { throw MeshletDataError.invalidClusters }
            }
            let sourceEnd = node.firstSourceIndex + node.sourceIndexCount
            let sourceSpan = sourceIndices[node.firstSourceIndex..<sourceEnd]
            let sourceVertices = Set(sourceSpan)
            guard geometry.indices[first..<end].allSatisfy({ sourceVertices.contains($0) }) else { throw MeshletDataError.invalidClusters }
            for source in sourceVertices {
                let p = positions[Int(source)]
                guard Self.contains(node, minimum: p, maximum: p) else { throw MeshletDataError.invalidClusters }
            }
            if node.childCount == 0 {
                guard node.level == 0, node.firstChild == 0, node.error == 0,
                    geometry.indices[first..<end].elementsEqual(sourceSpan) else { throw MeshletDataError.invalidClusters }
            } else {
                guard (2...4).contains(node.childCount), node.firstChild >= 0, node.firstChild < index,
                    node.childCount <= index - node.firstChild else { throw MeshletDataError.invalidClusters }
                var nextSource = node.firstSourceIndex
                var childIndexCount = 0
                for childIndex in node.firstChild..<(node.firstChild + node.childCount) {
                    let child = nodes[childIndex]
                    guard childrenUsed.insert(childIndex).inserted, child.parent == index,
                        child.firstSourceIndex == nextSource, child.error <= node.error, child.level + 1 == node.level,
                        Self.contains(node, minimum: child.minimum, maximum: child.maximum)
                    else { throw MeshletDataError.invalidClusters }
                    nextSource += child.sourceIndexCount
                    let a = geometry.clusters[child.firstCluster].firstIndex
                    let z = geometry.clusters[child.firstCluster + child.clusterCount - 1]
                    childIndexCount += z.firstIndex + z.indexCount - a
                }
                guard nextSource == sourceEnd, end - first < childIndexCount else { throw MeshletDataError.invalidClusters }
            }
            expectedCluster = clusterEnd
        }
        let rootSet = Set(roots)
        guard expectedCluster == geometry.clusters.count, rootSet.count == roots.count else { throw MeshletDataError.invalidClusters }
        var nextSource = 0
        for root in roots {
            guard nodes.indices.contains(root), nodes[root].parent == nil, nodes[root].firstSourceIndex == nextSource else {
                throw MeshletDataError.invalidClusters
            }
            nextSource += nodes[root].sourceIndexCount
        }
        guard nextSource == sourceIndices.count else { throw MeshletDataError.invalidClusters }
        for (index, node) in nodes.enumerated() {
            guard node.parent == nil ? rootSet.contains(index) : childrenUsed.contains(index) else { throw MeshletDataError.invalidClusters }
        }
        self.id = UUID()
        self.geometry = geometry
        self.nodes = nodes
        self.roots = roots
        self.sourceDigest = MeshletGeometry.digest(positions: positions, indices: sourceIndices)
        self.baseIndexCount = sourceIndices.count
        self.vertexCount = positions.count
    }

    public func matches(positions: [Vector3], indices: [UInt32]) -> Bool {
        vertexCount == positions.count && baseIndexCount == indices.count && sourceDigest == MeshletGeometry.digest(positions: positions, indices: indices)
    }

    private static func contains(_ node: MeshletLODNode, minimum: Vector3, maximum: Vector3) -> Bool {
        node.minimum.x <= minimum.x && node.minimum.y <= minimum.y && node.minimum.z <= minimum.z
            && node.maximum.x >= maximum.x && node.maximum.y >= maximum.y && node.maximum.z >= maximum.z
    }
}
