import Foundation
import Math

/// Additive hierarchy resource. V1 `.meshlets` remains the exact source partition and is not replaced.
public struct MeshletLODSidecar: Sendable {
    public struct Part: Sendable {
        public let meshIndex: Int
        public let partIndex: Int
        public let vertexCount: Int
        public let sourceIndexCount: Int
        public let sourceDigest: UInt64
        public let indices: [UInt32]
        public let clusters: [MeshletCluster]
        public let nodes: [MeshletLODNode]
        public let roots: [Int]

        public init(meshIndex: Int, partIndex: Int, geometry: MeshletLODGeometry) {
            self.meshIndex = meshIndex; self.partIndex = partIndex
            self.vertexCount = geometry.vertexCount; self.sourceIndexCount = geometry.baseIndexCount; self.sourceDigest = geometry.sourceDigest
            self.indices = geometry.geometry.indices; self.clusters = geometry.geometry.clusters
            self.nodes = geometry.nodes; self.roots = geometry.roots
        }

        fileprivate init(mesh: Int, part: Int, vertices: Int, sourceCount: Int, digest: UInt64,
                         indices: [UInt32], clusters: [MeshletCluster], nodes: [MeshletLODNode], roots: [Int]) {
            meshIndex = mesh; partIndex = part; vertexCount = vertices; sourceIndexCount = sourceCount; sourceDigest = digest
            self.indices = indices; self.clusters = clusters; self.nodes = nodes; self.roots = roots
        }
    }

    public let parts: [Part]
    public let maximumVertices: Int
    public let maximumTriangles: Int
    public static let maximumByteCount = 512 * 1024 * 1024
    private static let magic = Array("ADAMLOD1".utf8)

    public init(parts: [Part], maximumVertices: Int = 64, maximumTriangles: Int = 96) {
        self.parts = parts; self.maximumVertices = maximumVertices; self.maximumTriangles = maximumTriangles
    }

    public func geometry(meshIndex: Int, partIndex: Int, positions: [Vector3], indices: [UInt32]) throws -> MeshletLODGeometry? {
        guard let part = parts.first(where: { $0.meshIndex == meshIndex && $0.partIndex == partIndex }) else { return nil }
        guard part.vertexCount == positions.count, part.sourceIndexCount == indices.count,
            part.sourceDigest == MeshletGeometry.digest(positions: positions, indices: indices) else { throw MeshletDataError.incompatibleSource }
        let flat = try MeshletGeometry(clusters: part.clusters, indices: part.indices, positions: positions,
                                       maximumVertices: maximumVertices, maximumTriangles: maximumTriangles)
        return try MeshletLODGeometry(positions: positions, sourceIndices: indices, geometry: flat, nodes: part.nodes, roots: part.roots)
    }

    public init(data: Data) throws {
        guard data.count >= 24, data.count <= Self.maximumByteCount, Array(data.prefix(8)) == Self.magic else { throw MeshletDataError.invalidSidecar }
        var cursor = 8
        func word() throws -> UInt32 {
            guard cursor <= data.count - 4 else { throw MeshletDataError.invalidSidecar }
            let value = (0..<4).reduce(UInt32(0)) { $0 | UInt32(data[data.startIndex + cursor + $1]) << ($1 * 8) }
            cursor += 4; return value
        }
        func integer() throws -> Int {
            guard let value = Int(exactly: try word()) else { throw MeshletDataError.invalidSidecar }
            return value
        }
        func vector() throws -> Vector3 {
            let x = Float(bitPattern: try word()), y = Float(bitPattern: try word()), z = Float(bitPattern: try word())
            return Vector3(x, y, z)
        }
        func validBounds(_ lo: Vector3, _ hi: Vector3) -> Bool {
            lo.x.isFinite && lo.y.isFinite && lo.z.isFinite && hi.x.isFinite && hi.y.isFinite && hi.z.isFinite
                && lo.x <= hi.x && lo.y <= hi.y && lo.z <= hi.z
        }
        func reserveBytes(_ count: Int, stride: Int, remaining: inout Int) throws {
            guard count <= remaining / stride else { throw MeshletDataError.invalidSidecar }
            remaining -= count * stride
        }
        guard try word() == 1 else { throw MeshletDataError.invalidSidecar }
        maximumVertices = try integer(); maximumTriangles = try integer()
        let partCount = try integer()
        guard (3...256).contains(maximumVertices), (1...256).contains(maximumTriangles), partCount <= 65_536,
            partCount <= (data.count - cursor) / 40 else { throw MeshletDataError.invalidSidecar }
        var decoded: [Part] = []; decoded.reserveCapacity(partCount)
        var keys = Set<UInt64>()
        for _ in 0..<partCount {
            let mesh = try integer(), part = try integer(), vertices = try integer(), sourceCount = try integer()
            let indexCount = try integer(), clusterCount = try integer(), nodeCount = try integer(), rootCount = try integer()
            let low = try word(), high = try word(); let digest = UInt64(low) | UInt64(high) << 32
            var remaining = data.count - cursor
            try reserveBytes(clusterCount, stride: 32, remaining: &remaining)
            try reserveBytes(nodeCount, stride: 60, remaining: &remaining)
            try reserveBytes(rootCount, stride: 4, remaining: &remaining)
            try reserveBytes(indexCount, stride: 4, remaining: &remaining)
            guard keys.insert(UInt64(mesh) << 32 | UInt64(part)).inserted, sourceCount % 3 == 0, indexCount % 3 == 0,
                clusterCount <= indexCount / 3, nodeCount <= 1_000_000, rootCount <= nodeCount else { throw MeshletDataError.invalidSidecar }
            var clusters: [MeshletCluster] = []; clusters.reserveCapacity(clusterCount)
            var nextIndex = 0
            for _ in 0..<clusterCount {
                let first = try integer(), count = try integer(); let lo = try vector(), hi = try vector()
                guard first == nextIndex, count > 0, count % 3 == 0, count / 3 <= maximumTriangles,
                    count <= indexCount - nextIndex, validBounds(lo, hi) else { throw MeshletDataError.invalidSidecar }
                clusters.append(.init(firstIndex: first, indexCount: count, minimum: lo, maximum: hi)); nextIndex += count
            }
            guard nextIndex == indexCount else { throw MeshletDataError.invalidSidecar }
            var nodes: [MeshletLODNode] = []; nodes.reserveCapacity(nodeCount)
            for _ in 0..<nodeCount {
                let rawParent = try word()
                guard rawParent == UInt32.max || Int(exactly: rawParent) != nil else { throw MeshletDataError.invalidSidecar }
                let parent = rawParent == UInt32.max ? nil : Int(exactly: rawParent)
                let child = try integer(), children = try integer(), first = try integer(), count = try integer()
                let source = try integer(), sourceSize = try integer(), level = try integer()
                let lo = try vector(), hi = try vector(), error = Float(bitPattern: try word())
                guard error.isFinite, error >= 0, validBounds(lo, hi), level <= 32, children <= 4, first <= clusterCount, count <= clusterCount - first,
                    child <= nodeCount, children <= nodeCount - child, source <= sourceCount, sourceSize <= sourceCount - source
                else { throw MeshletDataError.invalidSidecar }
                nodes.append(.init(parent: parent, firstChild: child, childCount: children, firstCluster: first, clusterCount: count,
                    minimum: lo, maximum: hi, error: error, firstSourceIndex: source, sourceIndexCount: sourceSize, level: level))
            }
            var roots: [Int] = []; roots.reserveCapacity(rootCount)
            for _ in 0..<rootCount { let root = try integer(); guard root < nodeCount else { throw MeshletDataError.invalidSidecar }; roots.append(root) }
            var indices: [UInt32] = []; indices.reserveCapacity(indexCount)
            for _ in 0..<indexCount { let index = try word(); guard UInt64(index) < UInt64(vertices) else { throw MeshletDataError.invalidSidecar }; indices.append(index) }
            decoded.append(.init(mesh: mesh, part: part, vertices: vertices, sourceCount: sourceCount, digest: digest,
                                 indices: indices, clusters: clusters, nodes: nodes, roots: roots))
        }
        guard cursor == data.count else { throw MeshletDataError.invalidSidecar }
        parts = decoded
    }

    public func encoded() throws -> Data {
        guard (3...256).contains(maximumVertices), (1...256).contains(maximumTriangles), parts.count <= 65_536 else {
            throw MeshletDataError.invalidSidecar
        }
        var data = Data(Self.magic)
        func word(_ value: UInt32) { for shift in stride(from: 0, to: 32, by: 8) { data.append(UInt8((value >> shift) & 255)) } }
        func integer(_ value: Int) throws { guard let value = UInt32(exactly: value) else { throw MeshletDataError.invalidSidecar }; word(value) }
        func vector(_ v: Vector3) { word(v.x.bitPattern); word(v.y.bitPattern); word(v.z.bitPattern) }
        word(1); try integer(maximumVertices); try integer(maximumTriangles); try integer(parts.count)
        for part in parts {
            for value in [part.meshIndex, part.partIndex, part.vertexCount, part.sourceIndexCount,
                          part.indices.count, part.clusters.count, part.nodes.count, part.roots.count] { try integer(value) }
            word(UInt32(truncatingIfNeeded: part.sourceDigest)); word(UInt32(truncatingIfNeeded: part.sourceDigest >> 32))
            for cluster in part.clusters { try integer(cluster.firstIndex); try integer(cluster.indexCount); vector(cluster.minimum); vector(cluster.maximum) }
            for node in part.nodes {
                if let parent = node.parent { try integer(parent) } else { word(UInt32.max) }
                for value in [node.firstChild, node.childCount, node.firstCluster, node.clusterCount,
                              node.firstSourceIndex, node.sourceIndexCount, node.level] { try integer(value) }
                vector(node.minimum); vector(node.maximum); word(node.error.bitPattern)
            }
            for root in part.roots { try integer(root) }
            for index in part.indices { word(index) }
            guard data.count <= Self.maximumByteCount else { throw MeshletDataError.invalidSidecar }
        }
        _ = try Self(data: data)
        return data
    }
}
