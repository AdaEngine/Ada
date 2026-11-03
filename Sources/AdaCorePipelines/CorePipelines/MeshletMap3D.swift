import AdaAssets
import AdaECS
@_spi(Internal) import AdaRender
import AdaUtils
import Foundation
import Math

/// Diagnostic-only expanded vertices give each actual cluster a flat stable color without per-cluster draws.
/// Buffers are built once on first map use, shared across views, and bounded independently of production culling.
public struct MeshletMap3DResources: Resource {
    private struct Geometry {
        let source: any IndexBuffer
        let vertices: any VertexBuffer
        let count: Int
    }
    private struct GeometryKey: Hashable {
        let source: ObjectIdentifier
        let generation: UUID
    }
    private struct PipelineKey: Hashable {
        let temporal: Bool
        let response: Bool
        let surface: Bool
    }
    public var isEnabled = false
    public private(set) var allocatedBytes = 0
    private var geometries: [GeometryKey: Geometry] = [:]
    private var pipelines: [PipelineKey: any RenderPipeline] = [:]
    private var flags: [BufferData<Vector4>] = [.init(elements: [.zero]), .init(elements: [[1, 0, 0, 0]])]
    private let budget = 768 * 1024 * 1024
    private var lodPixelError: Float = 0
    private var lodProjection = Transform3D.identity
    private var viewport = SizeInt.zero
    private var requiresMotionGuides = false
    private var motionLODIDs: Set<UUID> = []
    private var activeView: Entity.ID?
    private var acceptedLOD: [Entity.ID: Set<MeshletLODItemKey>] = [:]
    public init() {}

    mutating func configureLOD(projection: Transform3D, viewport: SizeInt, pixelError: Float,
                              requiresMotionGuides: Bool = false, motionLODIDs: Set<UUID> = [], view: Entity.ID? = nil) {
        lodProjection = projection
        self.viewport = viewport
        lodPixelError = pixelError.isFinite && pixelError > 0 ? pixelError : 0
        self.requiresMotionGuides = requiresMotionGuides
        self.motionLODIDs = motionLODIDs
        activeView = view
        if let view { acceptedLOD[view] = [] }
    }
    func acceptedCut(for view: Entity.ID) -> Set<MeshletLODItemKey> { acceptedLOD[view] ?? [] }
    mutating func retainViews(_ views: [Entity.ID]) {
        let active = Set(views)
        acceptedLOD = acceptedLOD.filter { active.contains($0.key) }
    }

    /// Returns false for unsupported/budget-limited surfaces, so their ordinary shader draws gray coverage.
    public mutating func draw(item: Opaque3DRenderItem, encoder: RenderCommandEncoder, device: RenderDevice,
                              target: RenderViewTarget, instances: BufferData<Flat3DInstanceData>) throws -> Bool {
        let lodEnabled = lodPixelError > 0 && viewport.width > 0 && viewport.height > 0
        guard isEnabled else { return false }
        let part = item.mesh.models[item.modelIndex].parts[item.partIndex]
        let preparedLOD = part.meshletLOD
        guard Meshlet3DEligibility.fallbackReason(item, allowLOD: preparedLOD != nil) == nil, let range = item.batchRange else { return false }
        // Keep one expanded generation across LOD thresholds and views. Its leaves contain the exact source geometry.
        let hierarchy = preparedLOD.flatMap { $0.nodes.count > $0.roots.count ? $0 : nil }
        let canCoarsen = lodEnabled && hierarchy.map { !requiresMotionGuides || motionLODIDs.contains($0.id) } == true
        let leafOnly = preparedLOD.flatMap { $0.nodes.count == $0.roots.count ? $0.geometry : nil }
        guard let clusters = hierarchy?.geometry ?? part.meshlets ?? leafOnly, let material = item.material as? PBRMaterial else { return false }
        let key = GeometryKey(source: ObjectIdentifier(part.indexBuffer), generation: hierarchy?.id ?? clusters.id)
        if geometries[key] == nil {
            let length = clusters.indices.count.multipliedReportingOverflow(by: MemoryLayout<Vector4>.stride)
            guard !length.overflow, length.partialValue <= budget - allocatedBytes else { return false }
            let positions = part.meshDescriptor.positions.elements
            var vertices: [Vector4] = []
            vertices.reserveCapacity(clusters.indices.count)
            // Stable across process runs and asset reloads; independent of camera/light/frame state.
            var seed: UInt32 = 2166136261
            for byte in part.meshDescriptor.name.utf8 { seed = (seed ^ UInt32(byte)) &* 16777619 }
            let base = Int(seed % 1_048_576)
            var levels = [Int](repeating: 0, count: clusters.clusters.count)
            if let hierarchy {
                for node in hierarchy.nodes {
                    for cluster in node.firstCluster..<(node.firstCluster + node.clusterCount) { levels[cluster] = node.level }
                }
            }
            for (id, cluster) in clusters.clusters.enumerated() {
                let packedID = UInt32((base + id) & 0x000f_ffff) | (UInt32(min(levels[id], 15)) << 20)
                for index in cluster.firstIndex..<(cluster.firstIndex + cluster.indexCount) {
                    vertices.append(Vector4(positions[Int(clusters.indices[index])], Float(packedID)))
                }
            }
            let buffer = device.createVertexBuffer(label: "Meshlet map positions and IDs", length: length.partialValue, binding: 0)
            buffer.setElements(&vertices)
            geometries[key] = Geometry(source: part.indexBuffer, vertices: buffer, count: vertices.count)
            allocatedBytes += length.partialValue
        }
        guard let geometry = geometries[key] else { return false }
        let pipelineKey = PipelineKey(temporal: target.temporalUpscalingActive,
            response: target.reflectionResponse3DTexture != nil, surface: target.diffuseSurface3DTexture != nil)
        if pipelines[pipelineKey] == nil { pipelines[pipelineKey] = try makePipeline(pipelineKey, device: device) }
        guard let pipeline = pipelines[pipelineKey] else { return false }
        let flag = material.effectiveDoubleSided ? 1 : 0
        if flags[flag].buffer == nil { flags[flag].write(to: device) }
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBuffer(geometry.vertices, offset: 0, slot: 0)
        encoder.setVertexBuffer(instances, offset: Int(range.lowerBound) * MemoryLayout<Flat3DInstanceData>.stride, slot: 3)
        encoder.setFragmentBuffer(flags[flag], offset: 0, slot: 54)
        if let hierarchy {
            let selected = MeshletLODSelection.selectedNodes(geometry: hierarchy, transform: item.worldTransform,
                viewProjection: lodProjection, viewport: viewport, pixelError: canCoarsen ? lodPixelError : 0)
            var ranges: [Range<Int>] = []
            for id in selected {
                let node = hierarchy.nodes[id]
                let first = clusters.clusters[node.firstCluster].firstIndex
                let last = clusters.clusters[node.firstCluster + node.clusterCount - 1]
                let next = first..<(last.firstIndex + last.indexCount)
                if let prior = ranges.last, prior.upperBound == next.lowerBound { ranges[ranges.count - 1] = prior.lowerBound..<next.upperBound }
                else { ranges.append(next) }
            }
            // These ranges are actual selected coarse triangles, not a recoloring of the original mesh.
            for range in ranges { encoder.draw(type: .triangle, vertexStart: range.lowerBound, vertexCount: range.count, instanceCount: 1) }
            if canCoarsen, let activeView { acceptedLOD[activeView, default: []].insert(MeshletLODItemKey(item: item, hierarchy: hierarchy)) }
        } else {
            encoder.draw(type: .triangle, vertexStart: 0, vertexCount: geometry.count, instanceCount: 1)
        }
        return true
    }

    private func makePipeline(_ key: PipelineKey, device: RenderDevice) throws -> any RenderPipeline {
        var defines: [String] = []
        if key.response { defines.append("MAP_RESPONSE") }
        if key.surface { defines.append("MAP_SURFACE") }
        let shader = try ShaderModule.createBundled(at: "Shaders/meshlet_map_3d.glsl", from: .adaModule, defines: defines)
        var vertex = VertexDescriptor()
        vertex.attributes[0] = .attribute(.vector4, name: "positionAndClusterID", bufferIndex: 0, offset: 0)
        vertex.layouts[0] = .init(stride: MemoryLayout<Vector4>.stride, stepFunction: .perVertex)
        for index in 0..<4 {
            vertex.attributes[5 + index] = .attribute(.vector4, name: "instanceModel\(index)", bufferIndex: 3, offset: index * 16)
        }
        vertex.layouts[3] = .init(stride: MemoryLayout<Flat3DInstanceData>.stride, stepFunction: .perInstance)
        var descriptor = RenderPipelineDescriptor(vertex: shader.requiredShader(for: .vertex), fragment: shader.getShader(for: .fragment),
            debugName: "Meshlet ID map", backfaceCulling: false)
        descriptor.vertexDescriptor = vertex
        descriptor.depthPixelFormat = key.temporal ? .depth_32f : .depth_32f_stencil8
        descriptor.depthStencilDescriptor = .init(isDepthTestEnabled: true, isDepthWriteEnabled: true, depthCompareOperator: .less)
        descriptor.colorAttachments = (0..<4).map { _ in .init(format: .rgba_16f) }
        if key.response { descriptor.colorAttachments.append(.init(format: .rgba_16f)) }
        if key.surface { descriptor.colorAttachments.append(.init(format: .rgba8)) }
        #if os(Android)
        descriptor.frontFaceWinding = .clockwise
        #endif
        return device.createRenderPipeline(from: descriptor)
    }
}
