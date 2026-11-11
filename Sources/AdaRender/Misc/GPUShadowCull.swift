import Math

/// One shadow-casting instance of one pooled mesh part, culled on the GPU against every shadow view (64 bytes).
public struct GPUShadowCaster: Sendable, Equatable {
    /// World-space bounds minimum. `w` is 1 when the caster must always be drawn (no bounds, forced visible).
    public var minimum: Vector4
    /// World-space bounds maximum.
    public var maximum: Vector4
    /// Index of the caster's part in ``GPUShadowCullInput/parts``.
    public var part: UInt32
    /// Record index of the caster in ``GPUShadowCullInput/instances``.
    public var instance: UInt32
    /// Width of the distance fade. `maximum.w` stores the maximum draw distance.
    public var fadeDistance: Float = 0
    private var padding1: UInt32 = 0
    /// Exact CPU distance-test center, before rounding to the min/max representation.
    public var distanceCenter: Vector4

    public init(
        bounds: AABB?,
        forceVisible: Bool,
        part: UInt32,
        instance: UInt32,
        position: Vector3 = .zero,
        maximumDistance: Float = 0,
        fadeDistance: Float = 0
    ) {
        let alwaysVisible = forceVisible || bounds == nil
        minimum = Vector4(bounds?.min ?? .zero, alwaysVisible ? 1 : 0)
        maximum = Vector4(bounds?.max ?? .zero, maximumDistance)
        self.part = part
        self.instance = instance
        self.fadeDistance = fadeDistance
        distanceCenter = Vector4(bounds?.center ?? position, 0)
    }
}

/// The six clip planes of one shadow view, as rows of its view-projection (`row3 ± row0`, `row3 ± row1`, `row2`,
/// `row3 - row2`), matching the CPU mesh-visibility frustum test (128 bytes).
public struct GPUShadowCullView: Sendable {
    public var plane0: Vector4
    public var plane1: Vector4
    public var plane2: Vector4
    public var plane3: Vector4
    public var plane4: Vector4
    public var plane5: Vector4
    /// 0 draws every caster in this view (frustum culling disabled).
    public var culls: UInt32
    private var padding0: UInt32 = 0
    private var padding1: UInt32 = 0
    private var padding2: UInt32 = 0
    /// World-space camera position. A nonzero `w` enables distance culling.
    public var distanceCamera: Vector4

    public init(viewProjection: Transform3D, culls: Bool, distanceCamera: Vector3? = nil) {
        let row0 = viewProjection.row(at: 0)
        let row1 = viewProjection.row(at: 1)
        let row2 = viewProjection.row(at: 2)
        let row3 = viewProjection.row(at: 3)
        plane0 = row3 + row0
        plane1 = row3 - row0
        plane2 = row3 + row1
        plane3 = row3 - row1
        plane4 = row2
        plane5 = row3 - row2
        self.culls = culls ? 1 : 0
        self.distanceCamera = Vector4(distanceCamera ?? .zero, distanceCamera == nil ? 0 : 1)
    }
}

/// Casters, instance records and pooled parts shared by every shadow view of a frame.
///
/// For view `v` and part `p`, indirect draw `v * parts.count + p` draws the instances that survived culling.
/// They are written to output records `v * casters.count + segments[p]` and onward.
public struct GPUShadowCullInput: Sendable {
    public var casters: [GPUShadowCaster] = []
    /// Packed instance records, `instanceStride` bytes each.
    public var instances: [UInt8] = []
    public var instanceStride = 0
    /// Leading bytes of each record that the shadow passes read; the remainder is not copied.
    public var copiedBytes = 0
    /// Byte offset of the float that encodes the fraction removed by distance dithering.
    public var distanceFadeOffset: Int?
    /// Index count, first index and base vertex of each pooled part. Instance counts are ignored.
    public var parts: [IndexedIndirectArguments] = []
    /// First output record of each part inside a view's range; the parts' caster counts partition `casters.count`.
    public var segments: [UInt32] = []
    /// Changes whenever any array above changes, so unchanged inputs are not uploaded again.
    public var revision: UInt64 = 0

    public init() {}

    /// Whether the arrays describe a consistent, non-empty input.
    public var isValid: Bool {
        guard !casters.isEmpty, !parts.isEmpty, segments.count == parts.count,
            instanceStride > 0, instanceStride % 4 == 0, copiedBytes > 0, copiedBytes % 4 == 0, copiedBytes <= instanceStride,
            instances.count % instanceStride == 0
        else { return false }
        if let offset = distanceFadeOffset, offset < 0 || offset % 4 != 0 || offset > copiedBytes - 4 {
            return false
        }
        let records = instances.count / instanceStride
        var counts = [Int](repeating: 0, count: parts.count)
        for caster in casters {
            guard Int(caster.part) < parts.count, Int(caster.instance) < records else { return false }
            counts[Int(caster.part)] += 1
        }
        var next = 0
        for part in parts.indices {
            guard Int(segments[part]) == next else { return false }
            next += counts[part]
        }
        return next == casters.count
    }
}

/// Compacted instances and indirect arguments for every culled view.
public struct GPUShadowCullOutput: Sendable {
    public let instances: any Buffer
    public let arguments: any Buffer
    public let viewCount: Int
    public let partCount: Int
    public let casterCount: Int
    public let instanceStride: Int

    public init(instances: any Buffer, arguments: any Buffer, viewCount: Int, partCount: Int, casterCount: Int, instanceStride: Int) {
        self.instances = instances
        self.arguments = arguments
        self.viewCount = viewCount
        self.partCount = partCount
        self.casterCount = casterCount
        self.instanceStride = instanceStride
    }

    /// Byte offset of the indirect arguments for one view and part.
    public func argumentOffset(view: Int, part: Int) -> Int {
        (view * partCount + part) * MemoryLayout<IndexedIndirectArguments>.stride
    }

    /// First output instance record of one view and part.
    public func firstInstance(view: Int, segment: UInt32) -> Int {
        view * casterCount + Int(segment)
    }
}

/// Frustum-culls shadow casters for many shadow views in one GPU pass and writes indexed indirect draws.
///
/// The test never rejects a caster that the CPU frustum test keeps: it uses the same planes with a small
/// tolerance toward drawing, and an extra draw of an off-view caster is clipped without changing any pixel.
/// One owner (render node and camera) uses an instance; its frame ring is not shared.
public protocol GPUShadowCullProcessor: AnyObject, Sendable {
    /// Encodes culling before the shadow render pass on `command`. With `firstInstance`, each indirect draw
    /// selects its compacted instances through `firstInstance`; otherwise it is 0 and the caller binds the
    /// instance buffer at ``GPUShadowCullOutput/firstInstance(view:segment:)`` records.
    func encode(on command: any CommandBuffer, input: GPUShadowCullInput, views: [GPUShadowCullView], firstInstance: Bool) -> GPUShadowCullOutput?
}

// MARK: - Meshlet clusters

/// One meshlet cluster of a cluster caster: a large static part culled per cluster instead of as a whole (48 bytes).
///
/// See `Documentation/Designs/meshlet-shadow-culling.md`.
public struct GPUShadowCluster: Sendable, Equatable {
    /// World-space bounds minimum (`w` unused).
    public var minimum: Vector4
    /// World-space bounds maximum (`w` unused).
    public var maximum: Vector4
    /// First index of the cluster in its part's own index buffer.
    public var firstIndex: UInt32
    /// Index count of the cluster.
    public var indexCount: UInt32
    /// Index of the cluster's part in ``GPUShadowClusterInput/segments``.
    public var part: UInt32
    /// Record index of the part's caster in ``GPUShadowClusterInput/instances``.
    public var instance: UInt32

    public init(bounds: AABB, firstIndex: UInt32, indexCount: UInt32, part: UInt32, instance: UInt32) {
        minimum = Vector4(bounds.min, 0)
        maximum = Vector4(bounds.max, 0)
        self.firstIndex = firstIndex
        self.indexCount = indexCount
        self.part = part
        self.instance = instance
    }
}

/// Clusters of every cluster caster, shared by every shadow view of a frame.
///
/// For view `v`, the surviving clusters of part `p` are written as consecutive indirect draws starting at
/// argument `v * clusters.count + segments[p]`; their number is the `UInt32` counter `v * segments.count + p`.
public struct GPUShadowClusterInput: Sendable, Equatable {
    public var clusters: [GPUShadowCluster] = []
    /// Packed instance records, `instanceStride` bytes each, one per part; bound as per-instance vertex data.
    public var instances: [UInt8] = []
    public var instanceStride = 0
    /// First cluster of each part. Parts' clusters are consecutive, so a part's cluster count is the next segment's
    /// start (or `clusters.count`) minus its own.
    public var segments: [UInt32] = []
    /// Changes whenever any array above changes, so unchanged inputs are not uploaded again.
    public var revision: UInt64 = 0

    public init() {}

    /// Number of clusters of part `part`: the most draws it can issue in one view.
    public func clusterCount(part: Int) -> Int {
        let end = part + 1 < segments.count ? Int(segments[part + 1]) : clusters.count
        return end - Int(segments[part])
    }

    /// Whether the arrays describe a consistent, non-empty input.
    public var isValid: Bool {
        guard !clusters.isEmpty, !segments.isEmpty, segments[0] == 0, instanceStride > 0, instanceStride % 4 == 0,
            instances.count % instanceStride == 0
        else { return false }
        let records = instances.count / instanceStride
        for part in segments.indices {
            let end = part + 1 < segments.count ? Int(segments[part + 1]) : clusters.count
            guard end > Int(segments[part]) else { return false }
            for cluster in clusters[Int(segments[part])..<end] where Int(cluster.part) != part || Int(cluster.instance) >= records {
                return false
            }
        }
        return true
    }
}

/// Indirect draws of the clusters that survived culling, and their GPU-written counts, for every culled view.
public struct GPUShadowClusterCullOutput: Sendable {
    /// Indexed indirect arguments; see ``argumentOffset(view:part:)``.
    public let arguments: any Buffer
    /// One `UInt32` draw count per (view, part); see ``countOffset(view:part:)``.
    public let counts: any Buffer
    /// The input's instance records, readable as per-instance vertex data.
    public let instances: any Buffer
    public let viewCount: Int
    public let input: GPUShadowClusterInput

    public init(arguments: any Buffer, counts: any Buffer, instances: any Buffer, viewCount: Int, input: GPUShadowClusterInput) {
        self.arguments = arguments
        self.counts = counts
        self.instances = instances
        self.viewCount = viewCount
        self.input = input
    }

    /// Byte offset of the first indirect draw of one view and part.
    public func argumentOffset(view: Int, part: Int) -> Int {
        (view * input.clusters.count + Int(input.segments[part])) * MemoryLayout<IndexedIndirectArguments>.stride
    }

    /// Byte offset of the draw count of one view and part.
    public func countOffset(view: Int, part: Int) -> Int {
        (view * input.segments.count + part) * MemoryLayout<UInt32>.stride
    }
}

/// Frustum-culls meshlet clusters for many shadow views in one GPU pass and writes one indexed indirect draw per
/// surviving cluster, compacted per (view, part) with a GPU counter. The test is the one of
/// ``GPUShadowCullProcessor``, so it never rejects a cluster that reaches a view.
/// One owner (render node and camera) uses an instance; its frame ring is not shared.
public protocol GPUShadowClusterCullProcessor: AnyObject, Sendable {
    /// Encodes culling before the shadow render pass on `command`, or returns nil (encoding nothing) when the
    /// input is invalid or the output would exceed the processor's budget.
    func encode(on command: any CommandBuffer, input: GPUShadowClusterInput, views: [GPUShadowCullView]) -> GPUShadowClusterCullOutput?
}

/// Largest argument buffer of one cluster cull: about 3.3 million cluster-view pairs.
public enum GPUShadowClusterCullLimits {
    public static let argumentBytes = 64 << 20
}
