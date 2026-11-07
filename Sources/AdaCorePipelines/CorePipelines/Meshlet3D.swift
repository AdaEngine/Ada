import AdaECS
@_spi(Internal) import AdaRender
import AdaUtils
import Foundation
import Math
import Synchronization

/// CPU-known diagnostics. GPU visible counts require explicit asynchronous readback in benchmarks.
public struct Meshlet3DCount: Codable, Sendable {
    public var mode = MeshletVisibilityMode3D.disabled.rawValue
    public var eligibleItems = 0
    public var fallbackItems = 0
    public var candidateMeshlets = 0
    public var cpuVisibleMeshlets = 0
    public var sourceTriangles = 0
    public var cpuSubmittedTriangles = 0
    public var gpuDraws = 0
    public var fullyVisibleItems = 0
    public var fastPathTriangles = 0
    public var fallbackTriangles = 0
    public var lodNodes = 0
    public var selectedLODNodes = 0
    /// CPU/map cut counts, not a readback of GPU decisions.
    public var selectedLODLevels: [Int: Int] = [:]
    public var lodSelectedTriangles = 0
    public var lodGPUItems = 0
    public var lodFallbackItems = 0
    public var lodFallbackReasons: [String: Int] = [:]
    public var motionLODItems = 0
    public var motionLODTriangles = 0
    public var fallbackReasons: [String: Int] = [:]
    public init() {}
}

public final class Render3DMeshletStatistics: Resource, Sendable {
    private let state = Mutex<[String: Meshlet3DCount]>([:])
    public init() {}
    public var snapshots: [String: Meshlet3DCount] { state.withLock { $0 } }
    func record(_ value: Meshlet3DCount, view: Entity.ID) { state.withLock { $0[String(view)] = value } }
    func recordMotion(items: Int, triangles: Int, view: Entity.ID) {
        state.withLock { values in
            values[String(view)]?.motionLODItems = items
            values[String(view)]?.motionLODTriangles = triangles
        }
    }
    func retain(_ views: [Entity.ID]) {
        let active = Set(views.map { String($0) })
        state.withLock { values in for key in values.keys where !active.contains(key) { values.removeValue(forKey: key) } }
    }
}

/// Immutable static opaque triangle lists only; eligibility is evaluated after coarse batching.
public enum Meshlet3DEligibility {
    public static func fallbackReason(_ item: Opaque3DRenderItem, allowInstances: Bool = false, allowLOD: Bool = false) -> String? {
        let part = item.mesh.models[item.modelIndex].parts[item.partIndex]
        guard part.primitiveTopology == .triangleList else { return "topology" }
        guard part.meshlets != nil || (allowLOD && part.meshletLOD != nil) else { return "noPreparedData" }
        guard item.drawPass is any MeshletGeometryDrawPass else { return "drawPass" }
        guard item.skinningBuffer == nil, item.morphBuffer == nil, part.morphTargets == nil else { return "deformation" }
        guard let material = item.material as? PBRMaterial, material.graphMaterial == nil else { return "material" }
        guard material.effectiveAlphaMode == .opaque else { return "alphaCoverage" }
        guard material.heightTexture == nil else { return "parallax" }
        guard !item.forceVisible else { return "forceVisible" }
        guard let range = item.batchRange, !range.isEmpty else { return "noInstances" }
        guard allowInstances || range.count == 1 else { return "instancedBatch" }
        let transform = item.worldTransform
        guard transform.x.w == 0, transform.y.w == 0, transform.z.w == 0, transform.w.w == 1 else { return "nonAffine" }
        return nil
    }
}

/// One processor per view; encode and raster consumers share the same completion-protected command.
struct MeshletLODItemKey: Hashable {
    let entity: Entity.ID
    let model: Int
    let part: Int
    let source: ObjectIdentifier
    let generation: UUID
    init(item: Opaque3DRenderItem, hierarchy: MeshletLODGeometry) {
        entity = item.entity; model = item.modelIndex; part = item.partIndex
        source = ObjectIdentifier(item.mesh.models[item.modelIndex].parts[item.partIndex].indexBuffer)
        generation = hierarchy.id
    }
}

public struct Meshlet3DState: Resource {
    private struct Entry {
        var processor: (any MeshletVisibilityProcessor)?
        var output: MeshletVisibilityOutput?
        var attemptedProcessor = false
        var acceptedLOD: Set<MeshletLODItemKey> = []
    }
    private var entries: [Entity.ID: Entry] = [:]
    private struct CPUIndexGeometry {
        weak var source: (any IndexBuffer)?
        let indices: any IndexBuffer
    }
    private var cpuIndices: [UUID: CPUIndexGeometry] = [:]
    private var cpuIndexBytes = 0
    private let cpuIndexBudget = 256 * 1024 * 1024
    public init() {}
    public func output(for view: Entity.ID) -> MeshletVisibilityOutput? { entries[view]?.output }
    var preparedMotionLODIDs: Set<UUID> { Set(cpuIndices.keys) }
    mutating func recordMapCut(_ keys: Set<MeshletLODItemKey>, view: Entity.ID) { entries[view]?.acceptedLOD = keys }
    mutating func retain(_ views: [Entity.ID]) {
        for key in entries.keys where !views.contains(key) { entries.removeValue(forKey: key) }
        for key in cpuIndices.keys where cpuIndices[key]?.source == nil {
            if let entry = cpuIndices.removeValue(forKey: key) { cpuIndexBytes -= entry.indices.length }
        }
    }

    mutating func prepare(
        items: inout [Opaque3DRenderItem], view: Entity.ID, projection: Transform3D,
        settings: MeshVisibilitySettings3D, command: CommandBuffer, device: RenderDevice, map: Bool = false,
        viewport: SizeInt = .zero, lodProjection: Transform3D? = nil, requiresMotionGuides: Bool = false
    ) -> Meshlet3DCount {
        var count = Meshlet3DCount()
        count.mode = map ? "map" : settings.meshlets.rawValue
        entries[view]?.output = nil
        entries[view]?.acceptedLOD = []
        if entries[view] == nil { entries[view] = Entry() }
        var acceptedLOD: Set<MeshletLODItemKey> = []
        defer { entries[view]?.acceptedLOD = acceptedLOD }
        var selected: [Int] = []
        var draws: [MeshletVisibilityDraw] = []
        let frustum = MeshVisibilityFrustum3D(viewProjection: projection)
        for index in items.indices {
            let item = items[index]
            let part = item.mesh.models[item.modelIndex].parts[item.partIndex]
            let automatic = settings.lod && part.meshletLOD?.automaticPixelError != nil
            let mode: MeshletVisibilityMode3D = automatic ? .cpuReference : settings.meshlets
            guard mode != .disabled || map else { continue }
            if automatic, settings.meshlets == .disabled, !map { count.mode = mode.rawValue }
            let pixelError = lodPixelError(for: part, settings: settings)
            let lodEnabled = pixelError.isFinite && pixelError > 0 && viewport.width > 0 && viewport.height > 0
            count.sourceTriangles += part.indexCount / 3 * (item.batchRange?.count ?? 0)
            let reason = settings.gpuOcclusion && !map && !automatic ? "legacyOcclusion" : Meshlet3DEligibility.fallbackReason(item, allowLOD: lodEnabled)
            if let reason {
                count.fallbackItems += 1
                count.fallbackTriangles += part.indexCount / 3 * (item.batchRange?.count ?? 0)
                count.fallbackReasons[reason, default: 0] += 1
                continue
            }
            let preparedHierarchy = lodEnabled ? part.meshletLOD : nil
            var hierarchy = preparedHierarchy.flatMap { $0.nodes.count > $0.roots.count ? $0 : nil }
            var preparationFailure: String?
            if let current = hierarchy, requiresMotionGuides || mode == .cpuReference,
                prepareIndices(current, source: part.indexBuffer, device: device) == nil {
                hierarchy = nil
                preparationFailure = requiresMotionGuides ? "temporalGuideBudget" : "cpuLODBudget"
            }
            let leafOnly = preparedHierarchy.flatMap { $0.nodes.count == $0.roots.count ? $0.geometry : nil }
            guard let baseGeometry = part.meshlets ?? leafOnly ?? hierarchy?.geometry else {
                count.fallbackItems += 1; count.fallbackReasons[preparationFailure ?? "noPreparedBase", default: 0] += 1
                count.fallbackTriangles += part.indexCount / 3
                count.lodFallbackItems += 1
                continue
            }
            let geometry = hierarchy?.geometry ?? baseGeometry
            count.eligibleItems += 1
            count.candidateMeshlets += geometry.clusters.count
            if lodEnabled && hierarchy == nil {
                count.lodFallbackItems += 1
                count.lodFallbackReasons[preparationFailure ?? (preparedHierarchy == nil ? "noLODData" : "noLODReduction"), default: 0] += 1
            }
            if let hierarchy { count.lodNodes += hierarchy.nodes.count }
            var selectedNodes: [Int] = []
            if let hierarchy, map || mode == .cpuReference {
                selectedNodes = MeshletLODSelection.selectedNodes(geometry: hierarchy, transform: item.worldTransform,
                    viewProjection: lodProjection ?? projection, viewport: viewport, pixelError: pixelError)
                count.selectedLODNodes += selectedNodes.count
                for id in selectedNodes {
                    let node = hierarchy.nodes[id]
                    count.selectedLODLevels[node.level, default: 0] += 1
                    for cluster in geometry.clusters[node.firstCluster..<(node.firstCluster + node.clusterCount)] {
                        count.lodSelectedTriangles += cluster.indexCount / 3
                    }
                }
            }
            // Partition display has its own cached geometry. Do not run unused compute/compaction work.
            if map { continue }
            let simplifiedHierarchy = hierarchy.map { $0.nodes.count > $0.roots.count } == true
            if mode == .gpu, !simplifiedHierarchy,
                !settings.frustumCulling || baseGeometry.bounds.map({ frustum.fullyContains(MeshVisibility3DMath.transformed($0, by: item.worldTransform)) }) == true {
                count.fullyVisibleItems += 1
                count.fastPathTriangles += part.indexCount / 3
                continue
            }
            if mode == .cpuReference {
                var ranges: [Range<Int>] = []
                var visibleMeshlets = 0
                var submittedTriangles = 0
                let clusterRanges = hierarchy.map { lod in selectedNodes.map { lod.nodes[$0].firstCluster..<(lod.nodes[$0].firstCluster + lod.nodes[$0].clusterCount) } }
                    ?? [0..<geometry.clusters.count]
                for indices in clusterRanges {
                  for cluster in geometry.clusters[indices] {
                    let bounds = AABB(center: (cluster.minimum + cluster.maximum) * 0.5, halfExtents: (cluster.maximum - cluster.minimum) * 0.5)
                    if settings.frustumCulling && !frustum.intersects(MeshVisibility3DMath.transformed(bounds, by: item.worldTransform)) { continue }
                    visibleMeshlets += 1
                    submittedTriangles += cluster.indexCount / 3
                    let range = cluster.firstIndex..<(cluster.firstIndex + cluster.indexCount)
                    if let last = ranges.last, last.upperBound == range.lowerBound {
                        ranges[ranges.count - 1] = last.lowerBound..<range.upperBound
                    } else { ranges.append(range) }
                  }
                }
                var indexBuffer: any IndexBuffer = part.indexBuffer
                if let hierarchy {
                    guard let cached = cpuIndices[hierarchy.id] else { continue }
                    indexBuffer = cached.indices
                }
                count.cpuVisibleMeshlets += visibleMeshlets
                count.cpuSubmittedTriangles += submittedTriangles
                items[index].meshletOverride = MeshletDrawOverride(indices: indexBuffer, ranges: ranges, sourceIndices: hierarchy?.geometry.indices ?? part.meshDescriptor.indicies)
                if let hierarchy { acceptedLOD.insert(MeshletLODItemKey(item: item, hierarchy: hierarchy)) }
            } else {
                selected.append(index)
                draws.append(MeshletVisibilityDraw(geometry: baseGeometry, sourceIndexBuffer: part.indexBuffer,
                    transform: item.worldTransform, forceVisible: !settings.frustumCulling,
                    lod: simplifiedHierarchy ? hierarchy : nil, lodPixelError: pixelError,
                    viewport: viewport, lodViewProjection: lodProjection ?? projection))
            }
        }
        guard settings.meshlets == .gpu, !draws.isEmpty else { return count }
        var entry = entries.removeValue(forKey: view) ?? Entry()
        if !entry.attemptedProcessor {
            entry.processor = device.createMeshletVisibilityProcessor()
            entry.attemptedProcessor = true
        }
        defer { entries[view] = entry }
        if let output = entry.processor?.encode(on: command, viewProjection: projection, draws: draws), output.drawCount == draws.count {
            entry.output = output
            count.gpuDraws = output.drawCount
            count.lodGPUItems = draws.filter { $0.lod != nil }.count
            for (draw, index) in selected.enumerated() {
                items[index].meshletOverride = MeshletDrawOverride(indices: output.indices, arguments: output.arguments,
                    argumentOffset: draw * MemoryLayout<IndexedIndirectArguments>.stride)
                if let hierarchy = draws[draw].lod { acceptedLOD.insert(MeshletLODItemKey(item: items[index], hierarchy: hierarchy)) }
            }
        } else {
            count.fallbackItems += selected.count
            count.fallbackReasons["processorUnavailableOrBudget", default: 0] += selected.count
            for index in selected {
                let item = items[index]
                count.fallbackTriangles += item.mesh.models[item.modelIndex].parts[item.partIndex].indexCount / 3
            }
            count.eligibleItems -= selected.count
        }
        return count
    }

    /// Independent immutable indices keep temporal motion guides alive after the main GPU command completes.
    /// CPU selection matches the main shader's unjittered pixel-error policy; no compacted GPU buffer is reused.
    mutating func prepareMotion(
        items: inout [Opaque3DRenderItem], view: Entity.ID, settings: MeshVisibilitySettings3D, projection: Transform3D,
        viewport: SizeInt, device: RenderDevice, map: Bool = false
    ) -> (items: Int, triangles: Int) {
        let motionStart = PerformanceStallProbe.begin()
        var rangeCount = 0
        defer { PerformanceStallProbe.end("Meshlets.PrepareMotionCPU", since: motionStart, count: rangeCount) }
        let accepted = entries[view]?.acceptedLOD ?? []
        guard !accepted.isEmpty else { return (0, 0) }
        var count = 0, triangles = 0
        for index in items.indices {
            let item = items[index]
            guard Meshlet3DEligibility.fallbackReason(item, allowLOD: true) == nil else { continue }
            let part = item.mesh.models[item.modelIndex].parts[item.partIndex]
            let pixelError = lodPixelError(for: part, settings: settings)
            guard pixelError.isFinite, pixelError > 0, let hierarchy = part.meshletLOD, hierarchy.nodes.count > hierarchy.roots.count,
                accepted.contains(MeshletLODItemKey(item: item, hierarchy: hierarchy)),
                let buffer = cpuIndices[hierarchy.id]?.indices else { continue }
            let selected = MeshletLODSelection.selectedNodes(geometry: hierarchy, transform: item.worldTransform,
                viewProjection: projection, viewport: viewport, pixelError: pixelError)
            var ranges: [Range<Int>] = []
            for id in selected {
                let node = hierarchy.nodes[id]
                let first = hierarchy.geometry.clusters[node.firstCluster].firstIndex
                let last = hierarchy.geometry.clusters[node.firstCluster + node.clusterCount - 1]
                let next = first..<(last.firstIndex + last.indexCount)
                triangles += next.count / 3
                if let prior = ranges.last, prior.upperBound == next.lowerBound { ranges[ranges.count - 1] = prior.lowerBound..<next.upperBound }
                else { ranges.append(next) }
            }
            items[index].meshletOverride = MeshletDrawOverride(indices: buffer, ranges: ranges)
            rangeCount += ranges.count
            count += 1
        }
        return (count, triangles)
    }

    private func lodPixelError(for part: Mesh.Part, settings: MeshVisibilitySettings3D) -> Float {
        if let automatic = part.meshletLOD?.automaticPixelError { return settings.lod ? automatic : 0 }
        return settings.meshletLODPixelError
    }

    private mutating func prepareIndices(_ hierarchy: MeshletLODGeometry, source: any IndexBuffer, device: RenderDevice) -> (any IndexBuffer)? {
        if let existing = cpuIndices[hierarchy.id] { return existing.indices }
        let length = hierarchy.geometry.indices.count * MemoryLayout<UInt32>.stride
        guard length > 0, length <= cpuIndexBudget - cpuIndexBytes else { return nil }
        let uploadStart = PerformanceStallProbe.begin()
        defer { PerformanceStallProbe.end("Meshlets.MotionIndexUpload", since: uploadStart, bytes: length, count: hierarchy.nodes.count) }
        let uploaded: (any IndexBuffer)? = unsafe hierarchy.geometry.indices.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return nil }
            return unsafe device.createIndexBuffer(label: "Prepared meshlet LOD indices and motion guides", format: .uInt32, bytes: base, length: length)
        }
        guard let uploaded else { return nil }
        cpuIndices[hierarchy.id] = CPUIndexGeometry(source: source, indices: uploaded)
        cpuIndexBytes += length
        return uploaded
    }
}
