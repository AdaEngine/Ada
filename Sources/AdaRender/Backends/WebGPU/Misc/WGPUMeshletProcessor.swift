#if WEBGPU_ENABLED && canImport(WebGPU) && !WASM
  import AdaUtils
  import Foundation
  import Math
  import Synchronization
  @unsafe @preconcurrency import WebGPU

  /// Device-owned immutable uploads shared by view processors. Access is serialized by webGPUDeviceLock.
  final class WGPUMeshletGeometryCache: @unchecked Sendable {
    struct Key: Hashable {
      let source: ObjectIdentifier
      let generation: Foundation.UUID
    }
    struct Geometry {
      let descriptors: WebGPU.GPUBuffer
      let indices: WebGPU.GPUBuffer
      let nodes: WebGPU.GPUBuffer
      let sourceOwner: any IndexBuffer
    }
    private var values: [Key: Geometry] = [:]
    private var bytes = 0

    func get(_ draw: MeshletVisibilityDraw, context: WGPUContext, limit: Int) -> Geometry? {
      let getStart = PerformanceStallProbe.begin()
      defer { PerformanceStallProbe.end("Meshlets.StaticCacheGet", since: getStart, count: draw.geometry.clusters.count) }
      let key = Key(source: ObjectIdentifier(draw.sourceIndexBuffer), generation: draw.cacheID)
      if let value = values[key] { return value }
      let descriptorBytes = draw.geometry.clusters.count * MemoryLayout<MeshletGPUDescriptor>.stride
      let indexBytes = draw.geometry.indices.count * 4
      let nodeBytes = max(1, draw.lod?.nodes.count ?? 0) * MemoryLayout<MeshletLODNodeGPU>.stride
      guard descriptorBytes <= limit, indexBytes <= limit,
        nodeBytes <= limit,
        bytes <= MeshletVisibilityLimits.persistentBytes - descriptorBytes - indexBytes - nodeBytes
      else { return nil }
      guard
        let descriptors = context.device.createBuffer(
          descriptor: .init(usage: [.storage, .copyDst], size: UInt64(descriptorBytes))),
        let indices = context.device.createBuffer(
          descriptor: .init(usage: [.storage, .copyDst], size: UInt64(indexBytes))),
        let nodes = context.device.createBuffer(
          descriptor: .init(usage: [.storage, .copyDst], size: UInt64(nodeBytes)))
      else { return nil }
      let packStart = PerformanceStallProbe.begin()
      var packed = draw.geometry.clusters.map(MeshletGPUDescriptor.init)
      var nodeData: [MeshletLODNodeGPU] = []
      if let lod = draw.lod {
        for (nodeID, node) in lod.nodes.enumerated() {
          for cluster in node.firstCluster..<(node.firstCluster + node.clusterCount) {
            packed[cluster].reserved.x = UInt32(nodeID)
          }
        }
        nodeData = lod.nodes.map(MeshletLODNodeGPU.init)
      }
      PerformanceStallProbe.end("Meshlets.StaticPack", since: packStart, bytes: descriptorBytes + nodeBytes, count: packed.count)
      let uploadStart = PerformanceStallProbe.begin()
      if !nodeData.isEmpty {
        unsafe nodeData.withUnsafeBytes {
          unsafe context.device.queue.writeBuffer(buffer: nodes, bufferOffset: 0, data: $0)
        }
      }
      unsafe packed.withUnsafeBytes {
        unsafe context.device.queue.writeBuffer(buffer: descriptors, bufferOffset: 0, data: $0)
      }
      unsafe draw.geometry.indices.withUnsafeBytes {
        unsafe context.device.queue.writeBuffer(buffer: indices, bufferOffset: 0, data: $0)
      }
      PerformanceStallProbe.end("Meshlets.StaticUpload", since: uploadStart, bytes: descriptorBytes + indexBytes + nodeBytes, count: packed.count)
      let value = Geometry(
        descriptors: descriptors, indices: indices, nodes: nodes,
        sourceOwner: draw.sourceIndexBuffer)
      values[key] = value
      bytes += descriptorBytes + indexBytes + nodeBytes
      return value
    }
  }

  /// Each view owns bounded transient slots. A slot is reused only after its complete compute+raster command finishes.
  final class WGPUMeshletProcessor: MeshletVisibilityProcessor, @unchecked Sendable {
    // Native handles are immutable; GPU calls are serialized by webGPUDeviceLock, CPU mutations by lock.
    private struct Pipelines: @unchecked Sendable {
      let layout: WebGPU.GPUBindGroupLayout
      let classify: WebGPU.GPUComputePipeline
      let scan: WebGPU.GPUComputePipeline
      let scatter: WebGPU.GPUComputePipeline
    }
    private struct DrawKey: Hashable {
      let geometry: WGPUMeshletGeometryCache.Key
      let occurrence: Int
    }
    private struct DrawFrame {
      let constants: WebGPU.GPUBuffer
      let counts: WebGPU.GPUBuffer
      let offsets: WebGPU.GPUBuffer
      let groupScratch: WebGPU.GPUBuffer
      let group: WebGPU.GPUBindGroup
      let clusterCapacity: Int
      let byteCount: Int
    }
    // Only busy crosses the command completion callback; handles stay alive through this retained frame.
    private final class Frame: @unchecked Sendable {
      let busy = Mutex(false)
      let indices: WGPUIndexBuffer
      let arguments: WGPUBuffer
      var draws: [DrawKey: DrawFrame] = [:]
      var cachedBytes = 0
      init(indices: WGPUIndexBuffer, arguments: WGPUBuffer) {
        self.indices = indices
        self.arguments = arguments
      }
    }
    private let lock = NSLock()
    private let context: WGPUContext
    private let cache: WGPUMeshletGeometryCache
    private let pipelines: Pipelines
    private let limit: Int
    private var frames: [Frame?]
    private var nextFrame = 0

    init?(context: WGPUContext, cache: WGPUMeshletGeometryCache) {
      let creationStart = PerformanceStallProbe.begin()
      defer { PerformanceStallProbe.end("Meshlets.CreateProcessorCPU", since: creationStart, count: 3) }
      self.context = context
      self.cache = cache
      let created: (Pipelines, Int)? = webGPUDeviceLock.withLock { _ in
        var limits = WebGPU.GPULimits()
        guard context.device.getLimits(limits: &limits) == .success,
          limits.maxStorageBuffersPerShaderStage >= 8,
          limits.maxComputeInvocationsPerWorkgroup >= 256,
          limits.maxComputeWorkgroupStorageSize >= 1024,
          limits.maxComputeWorkgroupSizeX >= 256, limits.maxComputeWorkgroupsPerDimension >= 1024
        else { return nil }
        let limit = Int(
          min(
            UInt64(MeshletVisibilityLimits.bufferBytes),
            min(limits.maxStorageBufferBindingSize, limits.maxBufferSize)))
        let entries: [WebGPU.GPUBindGroupLayoutEntry] =
          (0..<6).map {
            .init(
              binding: UInt32($0), visibility: .compute,
              buffer: .init(type: $0 < 2 ? .readOnlyStorage : .storage))
          } + [
            .init(binding: 6, visibility: .compute, buffer: .init(type: .uniform)),
            .init(binding: 7, visibility: .compute, buffer: .init(type: .storage)),
            .init(binding: 8, visibility: .compute, buffer: .init(type: .readOnlyStorage)),
          ]
        let layout = context.device.createBindGroupLayout(descriptor: .init(entries: entries))
        let shader = context.device.createShaderModule(
          descriptor: .init(
            label: "Meshlet frustum/scan/scatter",
            nextInChain: WebGPU.GPUShaderSourceWGSL(code: WGPUMeshletShaders.source)))
        let pipelineLayout = context.device.createPipelineLayout(
          descriptor: .init(bindGroupLayouts: [layout]))
        func pipeline(_ entry: String) -> WebGPU.GPUComputePipeline {
          context.device.createComputePipeline(
            descriptor: .init(
              label: "Meshlet \(entry)", layout: pipelineLayout,
              compute: .init(module: shader, entryPoint: entry)))
        }
        return (
          Pipelines(
            layout: layout, classify: pipeline("classify"), scan: pipeline("scan"),
            scatter: pipeline("scatter")), limit
        )
      }
      guard let (pipelines, limit) = created else { return nil }
      self.pipelines = pipelines
      self.limit = limit
      frames = Array(
        repeating: nil, count: max(1, unsafe RenderEngine.configurations.maxFramesInFlight))
    }

    func encode(
      on command: any CommandBuffer, viewProjection: Transform3D, draws: [MeshletVisibilityDraw]
    ) -> MeshletVisibilityOutput? {
      let encodeStart = PerformanceStallProbe.begin()
      defer { PerformanceStallProbe.end("Meshlets.EncodeCPU", since: encodeStart, count: draws.count) }
      guard let command = command as? WGPUCommandEncoder,
        let plan = MeshletVisibilityPlan(
          draws: draws, projection: viewProjection, bufferLimit: limit)
      else { return nil }
      return lock.withLock {
        webGPUDeviceLock.withLock { _ in
          encodeLocked(command, projection: viewProjection, draws: draws, plan: plan)
        }
      }
    }

    private func encodeLocked(
      _ command: WGPUCommandEncoder, projection: Transform3D,
      draws: [MeshletVisibilityDraw], plan: MeshletVisibilityPlan
    ) -> MeshletVisibilityOutput? {
      guard
        let slot = (0..<frames.count).map({ (nextFrame + $0) % frames.count }).first(where: {
          frames[$0]?.busy.withLock { $0 } != true
        })
      else { return nil }
      var geometries: [WGPUMeshletGeometryCache.Geometry] = []
      geometries.reserveCapacity(draws.count)
      for draw in draws {
        guard let geometry = cache.get(draw, context: context, limit: limit) else { return nil }
        geometries.append(geometry)
      }
      if frames[slot].map({
        $0.indices.length < plan.indexCount * 4 || $0.arguments.length < plan.argumentBytes
      }) ?? true {
        let growStart = PerformanceStallProbe.begin()
        let indexCapacity = MeshletVisibilityLimits.bufferCapacity(required: plan.indexCount * 4, limit: limit)
        let argumentCapacity = MeshletVisibilityLimits.bufferCapacity(required: plan.argumentBytes, limit: limit)
        defer { PerformanceStallProbe.end("Meshlets.OutputFrameGrow", since: growStart, bytes: indexCapacity + argumentCapacity, count: slot) }
        guard
          let indices = context.device.createBuffer(
            descriptor: .init(
              usage: [.storage, .index, .copySrc],
              size: UInt64(
                indexCapacity)
            )),
          let arguments = context.device.createBuffer(
            descriptor: .init(
              usage: [.storage, .indirect, .copySrc],
              size: UInt64(
                argumentCapacity))
          )
        else { return nil }
        frames[slot] = Frame(
          indices: WGPUIndexBuffer(
            buffer: indices, device: context.device, indexFormat: .uInt32,
            instance: context.instance),
          arguments: WGPUBuffer(
            buffer: arguments, device: context.device, instance: context.instance))
      }
      guard let frame = frames[slot] else { return nil }
      var occurrences: [WGPUMeshletGeometryCache.Key: Int] = [:]
      let keys = draws.map { draw in
        let geometry = WGPUMeshletGeometryCache.Key(
          source: ObjectIdentifier(draw.sourceIndexBuffer), generation: draw.cacheID)
        let occurrence = occurrences[geometry, default: 0]
        occurrences[geometry] = occurrence + 1
        return DrawKey(geometry: geometry, occurrence: occurrence)
      }
      let activeKeys = Set(keys)
      var activeDraws: [DrawFrame] = []
      activeDraws.reserveCapacity(draws.count)
      for index in draws.indices {
        let draw = draws[index]
        let key = keys[index]
        if frame.draws[key] == nil {
          let required =
            draw.geometry.clusters.count * 8 + ((draw.geometry.clusters.count + 255) / 256) * 8
            + MemoryLayout<MeshletGPUView>.stride
          if frame.cachedBytes + required > MeshletVisibilityLimits.frameDrawCacheBytes
            || frame.draws.count >= MeshletVisibilityLimits.frameDrawCacheCount
          {
            for oldKey in frame.draws.keys where !activeKeys.contains(oldKey) {
              if let old = frame.draws.removeValue(forKey: oldKey) {
                frame.cachedBytes -= old.byteCount
              }
            }
          }
          guard frame.cachedBytes + required <= MeshletVisibilityLimits.frameDrawCacheBytes,
            frame.draws.count < MeshletVisibilityLimits.frameDrawCacheCount
          else { return nil }
          guard
            let value = makeDraw(
              geometry: geometries[index], count: draw.geometry.clusters.count,
              frame: frame)
          else { return nil }
          frame.draws[key] = value
          frame.cachedBytes += value.byteCount
        }
        guard let buffers = frame.draws[key] else { return nil }
        activeDraws.append(buffers)
        var view = MeshletGPUView(
          projection: projection, transform: draw.transform,
          parameters: SIMD4(
            UInt32(plan.firstIndices[index]), UInt32(index), UInt32(draw.geometry.clusters.count),
            draw.forceVisible ? 1 : 0))
        if draw.lod != nil {
          view.lodProjection = draw.lodViewProjection ?? projection
          view.lod = Vector4(
            Float(draw.viewport.width), Float(draw.viewport.height), draw.lodPixelError,
            MeshletLODSelection.scaleBound(draw.transform))
        }
        unsafe withUnsafeBytes(of: &view) {
          unsafe context.device.queue.writeBuffer(
            buffer: buffers.constants, bufferOffset: 0, data: $0)
        }
      }
      frame.busy.withLock { $0 = true }
      let lease = MeshletFrameLease { frame.busy.withLock { $0 = false } }
      command.addCompletedHandler { lease.release() }
      dispatch(command, pipeline: pipelines.classify, draws: activeDraws, scan: false)
      dispatch(command, pipeline: pipelines.scan, draws: activeDraws, scan: true)
      dispatch(command, pipeline: pipelines.scatter, draws: activeDraws, scan: false, scatter: true)
      nextFrame = (slot + 1) % frames.count
      return MeshletVisibilityOutput(
        indices: frame.indices, arguments: frame.arguments, drawCount: draws.count)
    }

    private func makeDraw(
      geometry: WGPUMeshletGeometryCache.Geometry,
      count: Int, frame: Frame
    ) -> DrawFrame? {
      guard
        let constants = context.device.createBuffer(
          descriptor: .init(
            usage: [.uniform, .copyDst], size: UInt64(MemoryLayout<MeshletGPUView>.stride))),
        let counts = context.device.createBuffer(
          descriptor: .init(usage: [.storage], size: UInt64(count * 4))),
        let offsets = context.device.createBuffer(
          descriptor: .init(usage: [.storage], size: UInt64(count * 4))),
        let groupScratch = context.device.createBuffer(
          descriptor: .init(usage: [.storage], size: UInt64(((count + 255) / 256) * 8)))
      else { return nil }
      let resources = [
        geometry.descriptors, geometry.indices, counts, offsets, frame.indices.buffer,
        frame.arguments.buffer, constants, groupScratch, geometry.nodes,
      ]
      let entries = resources.enumerated().map {
        WebGPU.GPUBindGroupEntry(
          binding: UInt32($0.offset), buffer: $0.element, size: $0.element.size)
      }
      let group = context.device.createBindGroup(
        descriptor: .init(layout: pipelines.layout, entries: entries))
      return DrawFrame(
        constants: constants, counts: counts, offsets: offsets, groupScratch: groupScratch,
        group: group,
        clusterCapacity: count,
        byteCount: count * 8 + ((count + 255) / 256) * 8 + MemoryLayout<MeshletGPUView>.stride)
    }

    private func dispatch(
      _ command: WGPUCommandEncoder, pipeline: WebGPU.GPUComputePipeline,
      draws: [DrawFrame], scan: Bool, scatter: Bool = false
    ) {
      let pass = command.commandEncoder.beginComputePass(
        descriptor: nil as WebGPU.GPUComputePassDescriptor?)
      pass.setPipeline(pipeline: pipeline)
      for draw in draws {
        pass.setBindGroup(groupIndex: 0, group: draw.group, dynamicOffsets: [])
        pass.dispatchWorkgroups(
          workgroupCountX: scatter ? UInt32(min(1024, draw.clusterCapacity)) : (scan ? 1 : UInt32((draw.clusterCapacity + 255) / 256)),
          workgroupCountY: scatter ? UInt32((draw.clusterCapacity + 1023) / 1024) : 1, workgroupCountZ: 1)
      }
      pass.end()
    }
  }
#endif
