import Foundation
import Math

/// Versioned derived geometry. The byte format uses explicit little-endian scalars, never Swift struct dumps.
/// Missing, corrupt or stale data must leave the original mesh available to the renderer.
public struct MeshletSidecar: Sendable {
    public struct Part: Sendable {
        public let meshIndex: Int
        public let partIndex: Int
        public let vertexCount: Int
        public let indexCount: Int
        public let sourceDigest: UInt64
        public let clusters: [MeshletCluster]

        public init(meshIndex: Int, partIndex: Int, geometry: MeshletGeometry) {
            self.meshIndex = meshIndex
            self.partIndex = partIndex
            self.vertexCount = geometry.vertexCount
            self.indexCount = geometry.indices.count
            self.sourceDigest = geometry.sourceDigest
            self.clusters = geometry.clusters
        }
    }

    public let parts: [Part]
    public let maximumVertices: Int
    public let maximumTriangles: Int
    public static let maximumByteCount = 64 * 1024 * 1024
    private static let magic: [UInt8] = [65, 68, 65, 77, 83, 72, 76, 49] // ADAMSHL1

    public init(parts: [Part], maximumVertices: Int = 64, maximumTriangles: Int = 96) {
        self.parts = parts
        self.maximumVertices = maximumVertices
        self.maximumTriangles = maximumTriangles
    }

    public func geometry(meshIndex: Int, partIndex: Int, positions: [Vector3], indices: [UInt32]) throws -> MeshletGeometry? {
        guard let part = parts.first(where: { $0.meshIndex == meshIndex && $0.partIndex == partIndex }) else { return nil }
        guard part.vertexCount == positions.count, part.indexCount == indices.count,
            part.sourceDigest == MeshletGeometry.digest(positions: positions, indices: indices)
        else { throw MeshletDataError.incompatibleSource }
        return try MeshletGeometry(clusters: part.clusters, indices: indices, positions: positions,
                                   maximumVertices: maximumVertices, maximumTriangles: maximumTriangles)
    }

    public init(data: Data) throws {
        guard data.count >= 24, data.count <= Self.maximumByteCount, Array(data.prefix(8)) == Self.magic else { throw MeshletDataError.invalidSidecar }
        var cursor = 8
        func word() throws -> UInt32 {
            guard cursor <= data.count - 4 else { throw MeshletDataError.invalidSidecar }
            let value = (0..<4).reduce(UInt32(0)) { $0 | UInt32(data[data.startIndex + cursor + $1]) << ($1 * 8) }
            cursor += 4
            return value
        }
        func integer() throws -> Int {
            guard let value = Int(exactly: try word()) else { throw MeshletDataError.invalidSidecar }
            return value
        }
        guard try word() == 1 else { throw MeshletDataError.invalidSidecar }
        maximumVertices = try integer()
        maximumTriangles = try integer()
        let count = try integer()
        guard (3...256).contains(maximumVertices), (1...256).contains(maximumTriangles), count <= 65_536, count <= (data.count - cursor) / 28
        else { throw MeshletDataError.invalidSidecar }
        var decoded: [Part] = []
        decoded.reserveCapacity(count)
        var keys = Set<UInt64>()
        for _ in 0..<count {
            let mesh = try integer(), part = try integer(), vertices = try integer(), indices = try integer(), clusterCount = try integer()
            let low = try word(), high = try word()
            let digest = UInt64(low) | UInt64(high) << 32
            let key = UInt64(mesh) << 32 | UInt64(part)
            guard keys.insert(key).inserted, indices % 3 == 0, clusterCount <= (data.count - cursor) / 32,
                clusterCount <= indices / 3
            else { throw MeshletDataError.invalidSidecar }
            var clusters: [MeshletCluster] = []
            clusters.reserveCapacity(clusterCount)
            var next = 0
            for _ in 0..<clusterCount {
                let first = try integer(), size = try integer()
                let lo = Vector3(Float(bitPattern: try word()), Float(bitPattern: try word()), Float(bitPattern: try word()))
                let hi = Vector3(Float(bitPattern: try word()), Float(bitPattern: try word()), Float(bitPattern: try word()))
                guard first == next, size > 0, size % 3 == 0, size / 3 <= maximumTriangles, size <= indices - next,
                    lo.x.isFinite, lo.y.isFinite, lo.z.isFinite, hi.x.isFinite, hi.y.isFinite, hi.z.isFinite,
                    lo.x <= hi.x, lo.y <= hi.y, lo.z <= hi.z
                else { throw MeshletDataError.invalidSidecar }
                clusters.append(.init(firstIndex: first, indexCount: size, minimum: lo, maximum: hi))
                next += size
            }
            guard next == indices else { throw MeshletDataError.invalidSidecar }
            decoded.append(Part(meshIndex: mesh, partIndex: part, vertexCount: vertices, indexCount: indices,
                                sourceDigest: digest, clusters: clusters))
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
        word(1); word(UInt32(maximumVertices)); word(UInt32(maximumTriangles)); word(UInt32(parts.count))
        for part in parts {
            guard let mesh = UInt32(exactly: part.meshIndex), let index = UInt32(exactly: part.partIndex),
                let vertices = UInt32(exactly: part.vertexCount), let indices = UInt32(exactly: part.indexCount),
                let clusters = UInt32(exactly: part.clusters.count)
            else { throw MeshletDataError.invalidSidecar }
            word(mesh); word(index); word(vertices); word(indices); word(clusters)
            word(UInt32(truncatingIfNeeded: part.sourceDigest)); word(UInt32(truncatingIfNeeded: part.sourceDigest >> 32))
            for cluster in part.clusters {
                guard let first = UInt32(exactly: cluster.firstIndex), let count = UInt32(exactly: cluster.indexCount) else { throw MeshletDataError.invalidSidecar }
                word(first); word(count)
                for value in [cluster.minimum.x, cluster.minimum.y, cluster.minimum.z, cluster.maximum.x, cluster.maximum.y, cluster.maximum.z] { word(value.bitPattern) }
            }
            guard data.count <= Self.maximumByteCount else { throw MeshletDataError.invalidSidecar }
        }
        _ = try Self(data: data)
        return data
    }
}

extension MeshletSidecar.Part {
    fileprivate init(meshIndex: Int, partIndex: Int, vertexCount: Int, indexCount: Int, sourceDigest: UInt64, clusters: [MeshletCluster]) {
        self.meshIndex = meshIndex
        self.partIndex = partIndex
        self.vertexCount = vertexCount
        self.indexCount = indexCount
        self.sourceDigest = sourceDigest
        self.clusters = clusters
    }
}
