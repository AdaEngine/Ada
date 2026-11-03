import Foundation
import Math

/// A contiguous group of source triangles. Bounds are in the part's local coordinate space.
public struct MeshletCluster: Equatable, Sendable {
    public let firstIndex: Int
    public let indexCount: Int
    public let minimum: Vector3
    public let maximum: Vector3

    public init(firstIndex: Int, indexCount: Int, minimum: Vector3, maximum: Vector3) {
        self.firstIndex = firstIndex
        self.indexCount = indexCount
        self.minimum = minimum
        self.maximum = maximum
    }
}

public enum MeshletDataError: Error, Equatable, Sendable {
    case invalidProfile
    case invalidGeometry
    case invalidClusters
    case incompatibleSource
    case invalidSidecar
}

/// Immutable, validated scan clusters. Indices preserve source order, winding and multiplicity exactly.
/// Preparation is explicit: no builder runs in a render pass or implicitly for procedural meshes.
public struct MeshletGeometry: Sendable {
    /// Identity of this validated generation, stable across value copies and never serialized as an asset path.
    public let id: UUID
    public let clusters: [MeshletCluster]
    public let indices: [UInt32]
    public let vertexCount: Int
    public let maximumVertices: Int
    public let maximumTriangles: Int
    public let sourceDigest: UInt64
    /// Conservative local-space union, cached once per generation. Nil for empty or unrepresentable geometry.
    public let bounds: AABB?

    public init(
        clusters: [MeshletCluster], indices: [UInt32], positions: [Vector3],
        maximumVertices: Int = 64, maximumTriangles: Int = 96
    ) throws {
        try Self.validateInput(positions: positions, indices: indices, maximumVertices: maximumVertices, maximumTriangles: maximumTriangles)
        var next = 0
        var aggregateMinimum = Vector3(Float.greatestFiniteMagnitude)
        var aggregateMaximum = -aggregateMinimum
        for cluster in clusters {
            guard cluster.firstIndex == next, cluster.indexCount > 0, cluster.indexCount % 3 == 0,
                cluster.indexCount / 3 <= maximumTriangles, cluster.indexCount <= indices.count - next,
                Self.isFinite(cluster.minimum), Self.isFinite(cluster.maximum),
                cluster.minimum.x <= cluster.maximum.x, cluster.minimum.y <= cluster.maximum.y, cluster.minimum.z <= cluster.maximum.z
            else { throw MeshletDataError.invalidClusters }
            let end = next + cluster.indexCount
            var vertices = Set<UInt32>()
            for index in indices[next..<end] {
                vertices.insert(index)
                let p = positions[Int(index)]
                guard p.x >= cluster.minimum.x, p.y >= cluster.minimum.y, p.z >= cluster.minimum.z,
                    p.x <= cluster.maximum.x, p.y <= cluster.maximum.y, p.z <= cluster.maximum.z
                else { throw MeshletDataError.invalidClusters }
            }
            guard vertices.count <= maximumVertices else { throw MeshletDataError.invalidClusters }
            aggregateMinimum = min(aggregateMinimum, cluster.minimum)
            aggregateMaximum = max(aggregateMaximum, cluster.maximum)
            next = end
        }
        guard next == indices.count else { throw MeshletDataError.invalidClusters }
        self.id = UUID()
        self.clusters = clusters
        self.indices = indices
        self.vertexCount = positions.count
        self.maximumVertices = maximumVertices
        self.maximumTriangles = maximumTriangles
        self.sourceDigest = Self.digest(positions: positions, indices: indices)
        if clusters.isEmpty {
            self.bounds = nil
        } else {
            // Avoid overflow in (minimum + maximum) and round the extents outward.
            let center = aggregateMinimum * 0.5 + aggregateMaximum * 0.5
            let extent = max(aggregateMaximum - center, center - aggregateMinimum)
            let outward = Vector3(extent.x.nextUp, extent.y.nextUp, extent.z.nextUp)
            self.bounds = Self.isFinite(center) && Self.isFinite(outward) ? AABB(center: center, halfExtents: outward) : nil
        }
    }

    /// Deterministic reference scan, intended for CPU tools and explicitly prepared procedural assets.
    /// This is AdaEngine's reference algorithm, not a claim of using meshoptimizer's native builder.
    public static func scan(
        positions: [Vector3], indices: [UInt32], maximumVertices: Int = 64, maximumTriangles: Int = 96
    ) throws -> Self {
        try validateInput(positions: positions, indices: indices, maximumVertices: maximumVertices, maximumTriangles: maximumTriangles)
        var clusters: [MeshletCluster] = []
        clusters.reserveCapacity((indices.count / 3 + maximumTriangles - 1) / maximumTriangles)
        var first = 0
        var vertices = Set<UInt32>()
        var lo = Vector3(Float.greatestFiniteMagnitude), hi = -lo
        for offset in stride(from: 0, to: indices.count, by: 3) {
            let triangle = indices[offset..<(offset + 3)]
            let additional = Set(triangle).subtracting(vertices).count
            if offset > first && (vertices.count + additional > maximumVertices || (offset - first) / 3 >= maximumTriangles) {
                clusters.append(.init(firstIndex: first, indexCount: offset - first, minimum: lo, maximum: hi))
                first = offset
                vertices.removeAll(keepingCapacity: true)
                lo = Vector3(Float.greatestFiniteMagnitude)
                hi = -lo
            }
            for index in triangle {
                vertices.insert(index)
                lo = min(lo, positions[Int(index)])
                hi = max(hi, positions[Int(index)])
            }
        }
        if first < indices.count { clusters.append(.init(firstIndex: first, indexCount: indices.count - first, minimum: lo, maximum: hi)) }
        return try Self(clusters: clusters, indices: indices, positions: positions,
                        maximumVertices: maximumVertices, maximumTriangles: maximumTriangles)
    }

    /// Checks source identity before attaching derived data to a part generation.
    public func matches(positions: [Vector3], indices: [UInt32]) -> Bool {
        vertexCount == positions.count && self.indices == indices && sourceDigest == Self.digest(positions: positions, indices: indices)
    }

    /// Stable FNV-1a fingerprint of normalized float32 positions and uint32 indices, not a security hash.
    public static func digest(positions: [Vector3], indices: [UInt32]) -> UInt64 {
        var hash: UInt64 = 14695981039346656037
        func word(_ value: UInt32) {
            for shift in stride(from: 0, to: 32, by: 8) {
                hash = (hash ^ UInt64((value >> shift) & 255)) &* 1099511628211
            }
        }
        word(UInt32(clamping: positions.count))
        word(UInt32(clamping: indices.count))
        for p in positions { word(p.x.bitPattern); word(p.y.bitPattern); word(p.z.bitPattern) }
        for index in indices { word(index) }
        return hash
    }

    private static func isFinite(_ value: Vector3) -> Bool { value.x.isFinite && value.y.isFinite && value.z.isFinite }

    private static func validateInput(positions: [Vector3], indices: [UInt32], maximumVertices: Int, maximumTriangles: Int) throws {
        guard (3...256).contains(maximumVertices), (1...256).contains(maximumTriangles) else { throw MeshletDataError.invalidProfile }
        guard UInt32(exactly: positions.count) != nil, UInt32(exactly: indices.count) != nil, indices.count % 3 == 0,
            positions.allSatisfy(isFinite), indices.allSatisfy({ index in
                guard let value = Int(exactly: index) else { return false }
                return value < positions.count
            })
        else { throw MeshletDataError.invalidGeometry }
    }
}
