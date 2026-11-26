import Math

/// Dense world-space emissive triangles. The shader combines these with the analytic-light table.
/// Dropping the whole proposal on overflow keeps the BSDF and light PDFs in agreement.
struct PathTracing3DEmitterTable: Sendable {
    /// Source-local coordinates survive the reordering of unrelated entities and batch placements.
    struct Identity: Comparable, Equatable, Sendable {
        let entity: Int
        let instance: UInt64?
        let part: Int
        let triangle: Int

        static func < (lhs: Self, rhs: Self) -> Bool {
            (
                lhs.entity, lhs.instance != nil ? 1 : 0, lhs.instance ?? 0, lhs.part, lhs.triangle
            ) < (
                rhs.entity, rhs.instance != nil ? 1 : 0, rhs.instance ?? 0, rhs.part, rhs.triangle
            )
        }

        func combine(into digest: inout FrameDigest3D) {
            digest.combine(UInt64(bitPattern: Int64(entity)))
            digest.combine(instance == nil ? UInt64(0) : 1)
            digest.combine(instance ?? 0)
            digest.combine(UInt64(part))
            digest.combine(UInt64(triangle))
        }
    }

    static let maximumCount = 65_536
    static let wordsPerTriangle = 6
    private(set) var words: [Vector4] = []
    private(set) var identities: [Identity] = []
    private(set) var identityDigest = FrameDigest3D()
    private(set) var overflowed = false

    var count: Int { identities.count }

    mutating func append(
        _ vertices: [Vector4],
        first: Int,
        transform: Transform3D,
        material: Int,
        maximumDistance: Float,
        identity: Identity
    ) {
        guard !overflowed else {
            return
        }
        let a = (transform * Vector4(vertices[first].xyz, 1)).xyz
        let b = (transform * Vector4(vertices[first + 1].xyz, 1)).xyz
        let c = (transform * Vector4(vertices[first + 2].xyz, 1)).xyz
        let areaSquared = (b - a).cross(c - a).squaredLength
        guard LocalLighting3DMath.isFinite(a), LocalLighting3DMath.isFinite(b), LocalLighting3DMath.isFinite(c),
            areaSquared.isFinite, areaSquared > 1e-16
        else {
            return
        }
        guard count < Self.maximumCount else {
            words.removeAll()
            identities.removeAll()
            overflowed = true
            return
        }
        identities.append(identity)
        words.append(Vector4(a, Float(material)))
        words.append(Vector4(b, maximumDistance))
        words.append(Vector4(c, 0))
        for corner in 0..<3 {
            let base = vertices[first + 6 + corner]
            let emission = vertices[first + 9 + corner]
            words.append(Vector4(base.x, base.y, emission.x, emission.y))
        }
    }

    /// Compact for GPU lookup while retaining the source IDs for deterministic ordering and invalidation.
    mutating func finish() {
        let ordered = zip(identities, identities.dropFirst()).allSatisfy { previous, next in
            previous <= next
        }
        if !ordered {
            let order = identities.indices.sorted { lhs, rhs in
                identities[lhs] < identities[rhs]
            }
            identities = order.map { index in
                identities[index]
            }
            var sortedWords: [Vector4] = []
            sortedWords.reserveCapacity(words.count)
            for offset in order {
                let first = offset * Self.wordsPerTriangle
                sortedWords.append(contentsOf: words[first..<(first + Self.wordsPerTriangle)])
            }
            words = sortedWords
        }
        var digest = FrameDigest3D()
        for identity in identities {
            identity.combine(into: &digest)
        }
        identityDigest = digest
    }
}
