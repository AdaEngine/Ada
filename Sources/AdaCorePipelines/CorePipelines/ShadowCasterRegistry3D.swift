import AdaECS
@_spi(Internal) import AdaRender
import AdaUtils
import Foundation
import Math

/// Static shadow casters drawn by GPU-culled indirect draws, shared by every shadow view of a frame.
///
/// A caster is one instance of one mesh part. Its geometry is copied once into a shared buffer per vertex
/// layout, so many parts draw from the same buffers. Casters whose shadow cannot be reproduced exactly
/// without per-view CPU work (skinned, morphed, level of detail, distance fade, shader-graph masks) are left
/// in ``cpuSources`` for the CPU-culled path. See `Documentation/Designs/gpu-driven-shadow-batching.md`.
public struct ShadowCasterRegistry3D: Resource {
    /// Identity of a source part: its buffers and index count.
    struct PartKey: Hashable {
        var vertex: ObjectIdentifier
        var index: ObjectIdentifier
        var indexCount: Int
    }

    /// Opaque casters only depend on their material for single- or double-sided rejection, so they share a draw
    /// group per pool and sidedness. Alpha-masked casters keep their own material buffer and base texture.
    enum GroupKey: Hashable {
        case opaque(pool: Int, doubleSided: Bool)
        case masked(pool: Int, buffer: ObjectIdentifier, texture: ObjectIdentifier?)

        var pool: Int {
            switch self {
            case let .opaque(pool, _), let .masked(pool, _, _): pool
            }
        }
    }

    /// One indirect draw per view: a pooled part drawn with a group's state.
    struct DrawPart: Hashable {
        var group: GroupKey
        var part: PartKey
    }

    /// Draw state shared by consecutive parts.
    struct Group {
        var key: GroupKey
        var descriptor: VertexDescriptor
        var material: any UniformBuffer
        var texture: Texture2D
        var palette: any UniformBuffer
        var firstPart: Int
        var partCount: Int

        /// Material parameters, base colour for alpha masks, and the identity skinning palette.
        var resources: RenderResourceSet {
            RenderResourceSet(bindings: [
                .init(binding: 15, shaderStages: .fragment, resource: .uniformBuffer(material, offset: 0)),
                .init(binding: 4, shaderStages: .fragment, resource: .texture(texture)),
                .init(binding: 7, shaderStages: .fragment, resource: .sampler(texture.sampler)),
                .init(binding: Skinning3DUniforms.binding, shaderStages: .vertex, resource: .uniformBuffer(palette, offset: 0)),
            ])
        }
    }

    private struct CasterKey: Hashable {
        var entity: Entity.ID
        var instance: UInt64
        var placed: Bool
        var model: Int32
        var part: Int32
    }

    private struct Snapshot: Equatable {
        var bounds: AABB?
        var draw: DrawPart
        var record: Flat3DInstanceData
    }

    private struct PooledPart {
        let vertexSource: any VertexBuffer
        let indexSource: any IndexBuffer
        let vertexBytes: Int
        let indexBytes: Int
        var vertexOffset = 0
        var indexOffset = 0
        var lastUsed: UInt64
    }

    private struct Pool {
        let descriptor: VertexDescriptor
        let stride: Int
        var vertex: (any VertexBuffer)?
        var index: (any IndexBuffer)?
        var vertexUsed = 0
        var indexUsed = 0
        var parts: [PartKey: PooledPart] = [:]
        var needsRebuild = false
    }

    /// A large static part culled per meshlet cluster. It is drawn from its own buffers, never pooled.
    struct ClusterPart {
        var descriptor: VertexDescriptor
        var vertex: any VertexBuffer
        var index: any IndexBuffer
        var material: any UniformBuffer
        var palette: any UniformBuffer

        /// Material parameters (opaque, so no base texture) and the identity skinning palette.
        var resources: RenderResourceSet {
            RenderResourceSet(bindings: [
                .init(binding: 15, shaderStages: .fragment, resource: .uniformBuffer(material, offset: 0)),
                .init(binding: 4, shaderStages: .fragment, resource: .texture(Texture2D.whiteTexture)),
                .init(binding: 7, shaderStages: .fragment, resource: .sampler(Texture2D.whiteTexture.sampler)),
                .init(binding: Skinning3DUniforms.binding, shaderStages: .vertex, resource: .uniformBuffer(palette, offset: 0)),
            ])
        }
    }

    /// Everything that decides a cluster caster's clusters, record and draw state.
    private struct ClusterSnapshot: Equatable {
        var entity: Entity.ID
        var model: Int32
        var part: Int32
        var vertex: ObjectIdentifier
        var index: ObjectIdentifier
        var geometry: UUID
        var descriptor: VertexDescriptor
        var material: ObjectIdentifier
        var record: Flat3DInstanceData
    }

    private struct Copy {
        let source: any Buffer
        let destination: any Buffer
        let destinationOffset: Int
        let size: Int
    }

    /// Frames a pooled part may stay unused before a rebuild may drop it.
    private static let retention: UInt64 = 300
    /// Largest pool buffer: the baseline WebGPU `maxBufferSize`. Larger scenes keep the CPU path.
    static let maximumPoolBytes = 256 << 20

    /// Smallest part, in meshlet clusters, that is culled per cluster. Smaller parts cost more as separate draws
    /// than their culled clusters save, so they stay per-caster casters.
    static let minimumClusterCasterClusters = 256

    /// Disable with `ADAENGINE_SHADOW_GPU=0` to draw every caster on the CPU-culled path.
    public var isEnabled = ProcessInfo.processInfo.environment["ADAENGINE_SHADOW_GPU"] != "0"

    /// The current casters, instance records and pooled parts.
    public private(set) var input = GPUShadowCullInput()
    /// Casters that keep the CPU-culled path.
    public private(set) var cpuSources: [Mesh3DRenderSource] = []
    /// Increments whenever ``input`` or the draw groups change.
    public private(set) var revision: UInt64 = 0
    /// Bounds of casters added, removed or changed by the last revision (old and new), or `nil` when the change
    /// cannot be bounded and every shadow view must redraw.
    public private(set) var changedBounds: [AABB]? = []

    /// Clusters of the large static parts culled per cluster (see `Documentation/Designs/meshlet-shadow-culling.md`).
    public private(set) var clusterInput = GPUShadowClusterInput()
    /// ``GPUShadowClusterInput/isValid`` of the current cluster input, evaluated once per change.
    public private(set) var isClusterInputValid = false
    /// Draw state of each cluster caster part, in ``clusterInput`` segment order.
    private(set) var clusterParts: [ClusterPart] = []
    private var clusterSnapshots: [ClusterSnapshot] = []

    private(set) var groups: [Group] = []
    private(set) var defaults: BufferData<Flat3DDefaultVertexData>?
    private var pools: [Pool] = []
    private var poolIndex: [VertexDescriptor: Int] = [:]
    private var snapshots: [CasterKey: Snapshot] = [:]
    private var copies: [Copy] = []
    private var frame: UInt64 = 0
    /// Material frame and switch state of the last update, so the second shadow node of a frame reuses it.
    private var updated: (frame: Int, enabled: Bool, palette: ObjectIdentifier?)?

    public init() {}

    /// Number of indirect draws per shadow view.
    public var partCount: Int { input.parts.count }

    /// Bytes of shared geometry held for shadow casters.
    public var pooledBytes: Int { pools.reduce(0) { $0 + ($1.vertex?.length ?? 0) + ($1.index?.length ?? 0) } }

    /// Whether any caster is drawn by the per-caster GPU path.
    public var hasCasters: Bool { !input.casters.isEmpty }

    /// Whether any part is drawn by the per-cluster GPU path.
    public var hasClusterCasters: Bool { !clusterInput.clusters.isEmpty }

    /// Builds the GPU-path input on devices without GPU culling (headless unit tests only).
    var buildsWithoutDeviceSupport = false
    /// Builds cluster casters on devices without GPU cluster culling (headless unit tests only).
    var buildsClustersWithoutDeviceSupport = false
    /// Smallest cluster caster in clusters; lowered by unit tests.
    var minimumClusterCount = minimumClusterCasterClusters
    /// Largest pool buffer in bytes; lowered by unit tests.
    var poolByteLimit = maximumPoolBytes
    /// Number of pool buffer pairs allocated so far (for tests).
    private(set) var poolAllocations = 0

    /// ``GPUShadowCullInput/isValid`` of the current input, evaluated once per change.
    public private(set) var isInputValid = false

    // MARK: - Update

    /// Splits `sources` into GPU-path casters and ``cpuSources``. Cheap when nothing changed: the arrays are rebuilt
    /// and compared, but uploads and pool copies happen only on change.
    public mutating func update(
        sources: [Mesh3DRenderSource],
        materials: inout PBR3DUniforms,
        identityPalette: (any UniformBuffer)?,
        device: RenderDevice
    ) {
        // Both shadow nodes update with the same extracted sources in one frame.
        let state = (frame: materials.frame, enabled: isEnabled, palette: identityPalette.map { ObjectIdentifier($0) })
        if let updated, updated == state { return }
        updated = state
        frame &+= 1
        // Backends without GPU culling never build pools or queue copies.
        guard isEnabled, device.supportsGPUShadowCull || buildsWithoutDeviceSupport, let identityPalette else {
            cpuSources = sources.filter(\.castShadows)
            clear()
            return
        }
        var cpu: [Mesh3DRenderSource] = []
        var casters: [GPUShadowCaster] = []
        var records: [Flat3DInstanceData] = []
        var keys: [CasterKey] = []
        var draws: [DrawPart] = []
        var drawIndex: [DrawPart: UInt32] = [:]
        var groupOrder: [GroupKey] = []
        var groupStates: [GroupKey: Group] = [:]
        let buildsClusters = device.supportsGPUShadowClusterCull || buildsClustersWithoutDeviceSupport
        var nextClusterParts: [ClusterPart] = []
        var nextClusterSnapshots: [ClusterSnapshot] = []
        var clusterGeometries: [(geometry: MeshletGeometry, transform: Transform3D)] = []
        for sourceIndex in sources.indices where sources[sourceIndex].castShadows {
            guard Self.isEligible(sources[sourceIndex]) else {
                cpu.append(sources[sourceIndex])
                continue
            }
            let mesh = sources[sourceIndex].mesh
            let count = sources[sourceIndex].instances?.count ?? 1
            for ordinal in 0..<count {
                let placement = sources[sourceIndex].instances == nil ? -1 : ordinal
                let transform: Transform3D
                let bounds: AABB?
                let tint: Vector4
                if placement >= 0, let instances = sources[sourceIndex].instances {
                    transform = sources[sourceIndex].transform * instances[placement].transform
                    // Matches the CPU list: the prototype bounds (no alternatives here) moved by the placement.
                    bounds = MeshVisibility3DMath.transformed(mesh.bounds, by: transform)
                    tint = instances[placement].color
                } else {
                    transform = sources[sourceIndex].transform
                    bounds = sources[sourceIndex].bounds
                    tint = .one
                }
                for modelIndex in mesh.models.indices {
                    let parts = mesh.models[modelIndex].parts
                    for partIndex in parts.indices {
                        let material = sources[sourceIndex].materials[parts[partIndex].materialIndex]
                        let pbr = material as? PBRMaterial
                        if pbr?.effectiveAlphaMode == .blend { continue }
                        let descriptor = parts[partIndex].vertexDescriptor
                        materials.write(material: material, descriptor: descriptor, device: device)
                        guard let buffer = materials.buffer(for: material) else { continue }
                        if buildsClusters, let geometry = clusterGeometry(
                            part: parts[partIndex], material: pbr, transform: transform,
                            isSingleton: placement < 0 && !sources[sourceIndex].forceVisible && bounds != nil
                        ) {
                            let record = Flat3DInstanceData(
                                modelMatrix: transform,
                                color: (pbr?.baseColorFactor ?? .one) * tint,
                                material: .zero,
                                textureFlags: .zero,
                                shadowFlags: .zero
                            )
                            nextClusterSnapshots.append(ClusterSnapshot(
                                entity: sources[sourceIndex].entity,
                                model: Int32(modelIndex),
                                part: Int32(partIndex),
                                vertex: ObjectIdentifier(parts[partIndex].vertexBuffer),
                                index: ObjectIdentifier(parts[partIndex].indexBuffer),
                                geometry: geometry.id,
                                descriptor: descriptor,
                                material: ObjectIdentifier(buffer),
                                record: record
                            ))
                            nextClusterParts.append(ClusterPart(
                                descriptor: descriptor,
                                vertex: parts[partIndex].vertexBuffer,
                                index: parts[partIndex].indexBuffer,
                                material: buffer,
                                palette: identityPalette
                            ))
                            clusterGeometries.append((geometry, transform))
                            continue
                        }
                        let pool = pool(for: descriptor)
                        let group: GroupKey = pbr?.effectiveAlphaMode == .mask
                            ? .masked(pool: pool, buffer: ObjectIdentifier(buffer), texture: pbr?.baseColorTexture.map(ObjectIdentifier.init))
                            : .opaque(pool: pool, doubleSided: pbr?.effectiveDoubleSided ?? true)
                        if groupStates[group] == nil {
                            groupStates[group] = Group(
                                key: group,
                                descriptor: descriptor,
                                material: buffer,
                                texture: pbr?.baseColorTexture ?? Texture2D.whiteTexture,
                                palette: identityPalette,
                                firstPart: 0,
                                partCount: 0
                            )
                            groupOrder.append(group)
                        }
                        let partKey = PartKey(
                            vertex: ObjectIdentifier(parts[partIndex].vertexBuffer),
                            index: ObjectIdentifier(parts[partIndex].indexBuffer),
                            indexCount: parts[partIndex].indexCount
                        )
                        retain(partKey, part: parts[partIndex], pool: pool)
                        let draw = DrawPart(group: group, part: partKey)
                        let index: UInt32
                        if let existing = drawIndex[draw] {
                            index = existing
                        } else {
                            index = UInt32(draws.count)
                            drawIndex[draw] = index
                            draws.append(draw)
                        }
                        casters.append(GPUShadowCaster(
                            bounds: bounds,
                            forceVisible: sources[sourceIndex].forceVisible,
                            part: index,
                            instance: UInt32(records.count)
                        ))
                        records.append(Flat3DInstanceData(
                            modelMatrix: transform,
                            color: (pbr?.baseColorFactor ?? .one) * tint,
                            material: .zero,
                            textureFlags: .zero,
                            shadowFlags: .zero
                        ))
                        keys.append(CasterKey(
                            entity: sources[sourceIndex].entity,
                            instance: placement >= 0 ? sources[sourceIndex].instances?[placement].id ?? 0 : 0,
                            placed: placement >= 0,
                            model: Int32(modelIndex),
                            part: Int32(partIndex)
                        ))
                    }
                }
            }
        }
        cpuSources = cpu
        guard let poolsChanged = rebuildPoolsIfNeeded(device: device) else {
            // A pool would exceed the buffer size limit: every caster keeps the CPU path.
            cpuSources = sources.filter(\.castShadows)
            clear()
            return
        }

        // Parts are ordered by group so each group's draws are consecutive; segments follow that order.
        let rank = Dictionary(uniqueKeysWithValues: groupOrder.enumerated().map { ($1, $0) })
        let order = draws.indices.sorted { (rank[draws[$0].group] ?? 0, $0) < (rank[draws[$1].group] ?? 0, $1) }
        var remap = [UInt32](repeating: 0, count: draws.count)
        for (position, original) in order.enumerated() { remap[original] = UInt32(position) }
        var counts = [Int](repeating: 0, count: draws.count)
        for index in casters.indices {
            casters[index].part = remap[Int(casters[index].part)]
            counts[Int(casters[index].part)] += 1
        }
        var parts: [IndexedIndirectArguments] = []
        var segments: [UInt32] = []
        var sortedDraws: [DrawPart] = []
        var next: UInt32 = 0
        for original in order {
            let draw = draws[original]
            let pool = pools[draw.group.pool]
            guard let pooled = pool.parts[draw.part] else {
                // Every retained part is pooled; anything else would misalign parts and casters.
                assertionFailure("Shadow caster part without pooled geometry")
                cpuSources = sources.filter(\.castShadows)
                clear()
                return
            }
            sortedDraws.append(draw)
            parts.append(IndexedIndirectArguments(
                indexCount: UInt32(draw.part.indexCount),
                firstIndex: UInt32(pooled.indexOffset / MemoryLayout<UInt32>.stride),
                baseVertex: Int32(pooled.vertexOffset / pool.stride)
            ))
            segments.append(next)
            next += UInt32(counts[parts.count - 1])
        }
        var nextGroups: [Group] = []
        for (position, draw) in sortedDraws.enumerated() {
            if let last = nextGroups.indices.last, nextGroups[last].key == draw.group {
                nextGroups[last].partCount += 1
            } else if var group = groupStates[draw.group] {
                group.firstPart = position
                group.partCount = 1
                nextGroups.append(group)
            }
        }

        // Diff by caster identity, so shadow views that kept their matrix redraw only where something changed.
        var current: [CasterKey: Snapshot] = [:]
        current.reserveCapacity(keys.count)
        var duplicate = false
        for index in keys.indices {
            let snapshot = Snapshot(
                bounds: casters[index].minimum.w != 0 ? nil : AABB(min: casters[index].minimum.xyz, max: casters[index].maximum.xyz),
                draw: draws[order[Int(casters[index].part)]],
                record: records[index]
            )
            if current.updateValue(snapshot, forKey: keys[index]) != nil { duplicate = true }
        }
        let instanceBytes = unsafe records.withUnsafeBytes { unsafe Array($0) }
        let changed = poolsChanged || current != snapshots || casters != input.casters || parts.count != input.parts.count
            || nextGroups.map(\.key) != groups.map(\.key) || instanceBytes != input.instances
        if changed {
            var bounds: [AABB]? = []
            if duplicate || poolsChanged {
                bounds = nil
            } else {
                for (key, old) in snapshots where current[key] != old {
                    guard let box = old.bounds else { bounds = nil; break }
                    bounds?.append(box)
                }
                if bounds != nil {
                    for (key, new) in current where snapshots[key] != new {
                        guard let box = new.bounds else { bounds = nil; break }
                        bounds?.append(box)
                    }
                }
            }
            changedBounds = bounds
            revision &+= 1
            var next = GPUShadowCullInput()
            next.casters = casters
            next.instances = instanceBytes
            next.instanceStride = MemoryLayout<Flat3DInstanceData>.stride
            // The shadow pipelines read the model matrix, colour and shadow flags (first 128 bytes).
            next.copiedBytes = MemoryLayout<Flat3DInstanceData>.offset(of: \.shadowFlags).map { $0 + MemoryLayout<Vector4>.stride }
                ?? MemoryLayout<Flat3DInstanceData>.stride
            next.parts = parts
            next.segments = segments
            next.revision = revision
            input = next
            isInputValid = next.isValid
            snapshots = current
        }
        groups = nextGroups
        clusterParts = nextClusterParts
        if nextClusterSnapshots != clusterSnapshots {
            // Cluster casters are large and rarely change: any change redraws every shadow view.
            revision &+= 1
            changedBounds = nil
            var next = GPUShadowClusterInput()
            var records: [Flat3DInstanceData] = []
            for (part, entry) in clusterGeometries.enumerated() {
                next.segments.append(UInt32(next.clusters.count))
                for cluster in entry.geometry.clusters {
                    let local = AABB(center: (cluster.minimum + cluster.maximum) * 0.5, halfExtents: (cluster.maximum - cluster.minimum) * 0.5)
                    next.clusters.append(GPUShadowCluster(
                        bounds: MeshVisibility3DMath.transformed(local, by: entry.transform),
                        firstIndex: UInt32(cluster.firstIndex),
                        indexCount: UInt32(cluster.indexCount),
                        part: UInt32(part),
                        instance: UInt32(part)
                    ))
                }
                records.append(nextClusterSnapshots[part].record)
            }
            next.instances = unsafe records.withUnsafeBytes { unsafe Array($0) }
            next.instanceStride = MemoryLayout<Flat3DInstanceData>.stride
            next.revision = revision
            clusterInput = next
            isClusterInputValid = next.isValid
            clusterSnapshots = nextClusterSnapshots
        }
        // The default-attribute buffer holds identical records. WebGPU binds it with stride 0 (one shared record),
        // so multi-draw instance indices beyond `casters.count` read that record; per-instance stepping backends
        // never multi-draw and read at most one part's casters.
        let defaultRecords = max(casters.count, clusterParts.count)
        if defaultRecords > (defaults?.count ?? 0) {
            var data = BufferData<Flat3DDefaultVertexData>(label: "Shadow Caster Defaults", elements: [])
            for _ in 0..<max(defaultRecords, 64) { data.append(Flat3DDefaultVertexData()) }
            data.write(to: device)
            defaults = data
        }
    }

    /// Encodes the pending geometry copies. Call before culling or drawing on the same command buffer.
    public mutating func flushCopies(on command: CommandBuffer) {
        guard !copies.isEmpty else { return }
        let blit = command.beginBlitPass(BlitPassDescriptor(label: "Shadow Geometry Pool"))
        for copy in copies {
            blit.copyBufferToBuffer(source: copy.source, sourceOffset: 0, destination: copy.destination, destinationOffset: copy.destinationOffset, size: copy.size)
        }
        blit.endBlitPass()
        copies.removeAll(keepingCapacity: true)
    }

    /// Pool buffers of a draw group.
    func buffers(for group: Group) -> (vertex: any VertexBuffer, index: any IndexBuffer)? {
        guard let vertex = pools[group.key.pool].vertex, let index = pools[group.key.pool].index else { return nil }
        return (vertex, index)
    }

    // MARK: - Eligibility

    /// Whether every part of `source` can be drawn by the GPU path with exactly the CPU path's result.
    static func isEligible(_ source: borrowing Mesh3DRenderSource) -> Bool {
        guard source.skinningBuffer == nil, source.morphBuffers.isEmpty, source.alternatives.isEmpty else { return false }
        // A finite maximum distance fades the caster per view when distance culling is on.
        if let maximum = source.maximumDistance, maximum.isFinite, maximum > 0 { return false }
        for model in source.mesh.models {
            for part in model.parts {
                guard source.materials.indices.contains(part.materialIndex) else { return false }
                if let pbr = source.materials[part.materialIndex] as? PBRMaterial {
                    if pbr.effectiveAlphaMode == .blend { continue }
                    if pbr.effectiveAlphaMode == .mask && pbr.graphMaterial != nil { return false }
                }
                var layouts = part.vertexDescriptor.layouts
                let stride = layouts[0].stride
                guard part.indexBuffer.indexFormat == .uInt32, part.indexCount > 0,
                    part.indexCount * MemoryLayout<UInt32>.stride <= part.indexBuffer.length,
                    stride > 0, stride % 4 == 0, part.vertexBuffer.length > 0, part.vertexBuffer.length % 4 == 0
                else { return false }
            }
        }
        return true
    }

    /// The meshlets of a part that is culled per cluster, or nil to keep it a per-caster caster.
    ///
    /// Matches `Meshlet3DEligibility`: a single static instance of an opaque standard PBR triangle list without
    /// deformation or parallax, with an affine transform, so the cluster bounds describe exactly what is drawn.
    private func clusterGeometry(part: Mesh.Part, material: PBRMaterial?, transform: Transform3D, isSingleton: Bool) -> MeshletGeometry? {
        guard isSingleton, let material, material.graphMaterial == nil, material.effectiveAlphaMode == .opaque,
            material.heightTexture == nil, part.primitiveTopology == .triangleList, part.morphTargets == nil,
            let geometry = part.meshlets, geometry.clusters.count >= minimumClusterCount,
            transform.x.w == 0, transform.y.w == 0, transform.z.w == 0, transform.w.w == 1
        else { return nil }
        // `Mesh.Part.meshlets` is nil unless the clusters were validated against this part's buffers and index count.
        return geometry
    }

    // MARK: - Pools

    private mutating func clear() {
        // Without GPU-path casters, the pools and the source buffers they retain are released.
        pools = []
        poolIndex = [:]
        copies = []
        clusterParts = []
        guard !input.casters.isEmpty || !groups.isEmpty || !clusterInput.clusters.isEmpty else { return }
        clusterInput = GPUShadowClusterInput()
        isClusterInputValid = false
        clusterSnapshots = []
        input = GPUShadowCullInput()
        isInputValid = false
        groups = []
        snapshots = [:]
        changedBounds = nil
        revision &+= 1
    }

    private mutating func pool(for descriptor: VertexDescriptor) -> Int {
        if let index = poolIndex[descriptor] { return index }
        let index = pools.count
        var layouts = descriptor.layouts
        pools.append(Pool(descriptor: descriptor, stride: layouts[0].stride))
        poolIndex[descriptor] = index
        return index
    }

    private mutating func retain(_ key: PartKey, part: Mesh.Part, pool: Int) {
        if pools[pool].parts[key] != nil {
            pools[pool].parts[key]?.lastUsed = frame
            return
        }
        var pooled = PooledPart(
            vertexSource: part.vertexBuffer,
            indexSource: part.indexBuffer,
            vertexBytes: part.vertexBuffer.length,
            indexBytes: part.indexCount * MemoryLayout<UInt32>.stride,
            lastUsed: frame
        )
        let stride = pools[pool].stride
        let vertexOffset = (pools[pool].vertexUsed + stride - 1) / stride * stride
        let indexOffset = pools[pool].indexUsed
        if let vertex = pools[pool].vertex, let index = pools[pool].index,
            vertexOffset + pooled.vertexBytes <= vertex.length, indexOffset + pooled.indexBytes <= index.length {
            pooled.vertexOffset = vertexOffset
            pooled.indexOffset = indexOffset
            pools[pool].vertexUsed = vertexOffset + pooled.vertexBytes
            pools[pool].indexUsed = indexOffset + pooled.indexBytes
            copies.append(Copy(source: pooled.vertexSource, destination: vertex, destinationOffset: vertexOffset, size: pooled.vertexBytes))
            copies.append(Copy(source: pooled.indexSource, destination: index, destinationOffset: indexOffset, size: pooled.indexBytes))
        } else {
            pools[pool].needsRebuild = true
        }
        pools[pool].parts[key] = pooled
    }

    /// Reallocates pools that are full or mostly unused and copies their live parts again.
    /// New buffers are used, so frames still in flight keep reading the old ones.
    /// Returns whether any pool was rebuilt, or `nil` when a pool would exceed ``poolByteLimit``.
    private mutating func rebuildPoolsIfNeeded(device: RenderDevice) -> Bool? {
        // Check every pool against the limit before allocating anything, so an over-limit scene allocates nothing.
        for pool in pools {
            var vertexBytes = 0
            var indexBytes = 0
            for part in pool.parts.values where frame - part.lastUsed <= Self.retention {
                vertexBytes = (vertexBytes + pool.stride - 1) / pool.stride * pool.stride + part.vertexBytes
                indexBytes += part.indexBytes
            }
            guard vertexBytes <= poolByteLimit, indexBytes <= poolByteLimit else { return nil }
        }
        var rebuilt = false
        for index in pools.indices {
            let stale = pools[index].parts.filter { frame - $0.value.lastUsed > Self.retention }
            let staleBytes = stale.values.reduce(0) { $0 + $1.vertexBytes + $1.indexBytes }
            let allocated = (pools[index].vertex?.length ?? 0) + (pools[index].index?.length ?? 0)
            guard pools[index].needsRebuild || (staleBytes > 4 << 20 && staleBytes * 2 > allocated) else { continue }
            for key in stale.keys { pools[index].parts.removeValue(forKey: key) }
            let stride = pools[index].stride
            var vertexBytes = 0
            var indexBytes = 0
            for key in pools[index].parts.keys {
                vertexBytes = (vertexBytes + stride - 1) / stride * stride + (pools[index].parts[key]?.vertexBytes ?? 0)
                indexBytes += pools[index].parts[key]?.indexBytes ?? 0
            }
            // Headroom avoids reallocating for every part streamed in.
            let vertexCapacity = min(max(64 << 10, (vertexBytes + vertexBytes / 2 + stride - 1) / stride * stride), poolByteLimit / stride * stride)
            let indexCapacity = min(max(64 << 10, (indexBytes + indexBytes / 2 + 3) & ~3), poolByteLimit & ~3)
            let vertex = device.createVertexBuffer(label: "Shadow Geometry Pool Vertices", length: vertexCapacity, binding: 0)
            let zeros = [UInt8](repeating: 0, count: indexCapacity)
            guard let indexBuffer = unsafe zeros.withUnsafeBytes({ bytes in
                unsafe bytes.baseAddress.map { unsafe device.createIndexBuffer(label: "Shadow Geometry Pool Indices", format: .uInt32, bytes: $0, length: indexCapacity) }
            }) else { continue }
            pools[index].vertex = vertex
            pools[index].index = indexBuffer
            poolAllocations += 1
            var vertexUsed = 0
            var indexUsed = 0
            for key in pools[index].parts.keys {
                guard var part = pools[index].parts[key] else { continue }
                part.vertexOffset = (vertexUsed + stride - 1) / stride * stride
                part.indexOffset = indexUsed
                vertexUsed = part.vertexOffset + part.vertexBytes
                indexUsed = part.indexOffset + part.indexBytes
                copies.append(Copy(source: part.vertexSource, destination: vertex, destinationOffset: part.vertexOffset, size: part.vertexBytes))
                copies.append(Copy(source: part.indexSource, destination: indexBuffer, destinationOffset: part.indexOffset, size: part.indexBytes))
                pools[index].parts[key] = part
            }
            pools[index].vertexUsed = vertexUsed
            pools[index].indexUsed = indexUsed
            pools[index].needsRebuild = false
            rebuilt = true
        }
        if rebuilt {
            // Drop copies into buffers that are no longer any pool's buffers.
            let live = Set(pools.flatMap { [$0.vertex.map { ObjectIdentifier($0) }, $0.index.map { ObjectIdentifier($0) }] }.compactMap { $0 })
            copies.removeAll { !live.contains(ObjectIdentifier($0.destination)) }
        }
        return rebuilt
    }
}
