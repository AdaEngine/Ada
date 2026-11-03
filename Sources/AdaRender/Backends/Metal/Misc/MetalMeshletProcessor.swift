#if METAL
  import Foundation
  import Math
  import Synchronization
  @unsafe @preconcurrency import Metal

  /// Immutable uploads are shared by view processors on the same render device.
  final class MetalMeshletGeometryCache: @unchecked Sendable {
    struct Key: Hashable {
      let source: ObjectIdentifier
      let generation: Foundation.UUID
    }
    struct Geometry {
      let descriptors: MTLBuffer
      let indices: MTLBuffer
      let nodes: MTLBuffer
      let sourceOwner: any IndexBuffer
    }
    private let lock = NSLock()
    private var values: [Key: Geometry] = [:]
    private var bytes = 0

    func get(_ draw: MeshletVisibilityDraw, device: MTLDevice, limit: Int) -> Geometry? {
      lock.withLock {
        let key = Key(
          source: ObjectIdentifier(draw.sourceIndexBuffer), generation: draw.cacheID)
        if let value = values[key] { return value }
        let descriptorBytes =
          draw.geometry.clusters.count * MemoryLayout<MeshletGPUDescriptor>.stride
        let indexBytes = draw.geometry.indices.count * 4
        let nodeBytes = max(1, draw.lod?.nodes.count ?? 0) * MemoryLayout<MeshletLODNodeGPU>.stride
        guard descriptorBytes <= limit, indexBytes <= limit,
          nodeBytes <= limit,
          bytes <= MeshletVisibilityLimits.persistentBytes - descriptorBytes - indexBytes
            - nodeBytes,
          let descriptors = device.makeBuffer(length: descriptorBytes, options: .storageModeShared),
          let indices = device.makeBuffer(length: indexBytes, options: .storageModeShared),
          let nodes = device.makeBuffer(length: nodeBytes, options: .storageModeShared)
        else { return nil }
        var packed = draw.geometry.clusters.map(MeshletGPUDescriptor.init)
        if let lod = draw.lod {
          for (nodeID, node) in lod.nodes.enumerated() {
            for cluster in node.firstCluster..<(node.firstCluster + node.clusterCount) {
              packed[cluster].reserved.x = UInt32(nodeID)
            }
          }
          let nodeData = lod.nodes.map(MeshletLODNodeGPU.init)
          unsafe nodeData.withUnsafeBytes {
            if let base = $0.baseAddress {
              unsafe nodes.contents().copyMemory(from: base, byteCount: $0.count)
            }
          }
        }
        unsafe packed.withUnsafeBytes {
          if let base = $0.baseAddress {
            unsafe descriptors.contents().copyMemory(from: base, byteCount: $0.count)
          }
        }
        unsafe draw.geometry.indices.withUnsafeBytes {
          if let base = $0.baseAddress {
            unsafe indices.contents().copyMemory(from: base, byteCount: $0.count)
          }
        }
        let value = Geometry(
          descriptors: descriptors, indices: indices, nodes: nodes,
          sourceOwner: draw.sourceIndexBuffer)
        values[key] = value
        bytes += descriptorBytes + indexBytes + nodeBytes
        return value
      }
    }
  }

  /// Per-view transient slots are protected by completion of the command containing compute and its raster consumers.
  final class MetalMeshletProcessor: MeshletVisibilityProcessor, @unchecked Sendable {
    private struct DrawKey: Hashable {
      let geometry: MetalMeshletGeometryCache.Key
      let occurrence: Int
    }
    private struct DrawFrame {
      let constants: MTLBuffer
      let counts: MTLBuffer
      let offsets: MTLBuffer
      let groupScratch: MTLBuffer
      let geometry: MetalMeshletGeometryCache.Geometry
      let clusterCapacity: Int
      let byteCount: Int
    }
    // CPU mutations stay under lock; only the independent busy mutex crosses GPU completion callbacks.
    private final class Frame: @unchecked Sendable {
      let busy = Mutex(false)
      let indices: MetalIndexBuffer
      let arguments: MetalBuffer
      var draws: [DrawKey: DrawFrame] = [:]
      var cachedBytes = 0
      init(indices: MetalIndexBuffer, arguments: MetalBuffer) {
        self.indices = indices
        self.arguments = arguments
      }
    }
    private let lock = NSLock()
    private let device: MTLDevice
    private let cache: MetalMeshletGeometryCache
    private let classify: MTLComputePipelineState
    private let scan: MTLComputePipelineState
    private let scatter: MTLComputePipelineState
    private let limit: Int
    private var frames: [Frame?]
    private var nextFrame = 0

    init(device: MTLDevice, cache: MetalMeshletGeometryCache) throws {
      self.device = device
      self.cache = cache
      limit = min(device.maxBufferLength, MeshletVisibilityLimits.bufferBytes)
      let options = MTLCompileOptions()
      options.fastMathEnabled = false
      let library = try device.makeLibrary(source: MetalMeshletShaders.source, options: options)
      func pipeline(_ name: String) throws -> MTLComputePipelineState {
        guard let function = library.makeFunction(name: name) else {
          throw CreationError.missingFunction(name)
        }
        return try device.makeComputePipelineState(function: function)
      }
      classify = try pipeline("meshlet_classify")
      scan = try pipeline("meshlet_scan")
      scatter = try pipeline("meshlet_scatter")
      guard classify.maxTotalThreadsPerThreadgroup >= 256,
        scatter.maxTotalThreadsPerThreadgroup >= 64
      else {
        throw CreationError.unsupportedThreadgroup
      }
      frames = Array(
        repeating: nil, count: max(1, unsafe RenderEngine.configurations.maxFramesInFlight))
    }

    func encode(
      on command: any CommandBuffer, viewProjection: Transform3D, draws: [MeshletVisibilityDraw]
    ) -> MeshletVisibilityOutput? {
      guard let command = command as? MetalCommandEncoder,
        let plan = MeshletVisibilityPlan(
          draws: draws, projection: viewProjection, bufferLimit: limit)
      else { return nil }
      return lock.withLock {
        encodeLocked(command, projection: viewProjection, draws: draws, plan: plan)
      }
    }

    private func encodeLocked(
      _ command: MetalCommandEncoder, projection: Transform3D,
      draws: [MeshletVisibilityDraw], plan: MeshletVisibilityPlan
    ) -> MeshletVisibilityOutput? {
      guard
        let slot = (0..<frames.count).map({ (nextFrame + $0) % frames.count }).first(where: {
          frames[$0]?.busy.withLock { $0 } != true
        })
      else { return nil }
      var geometries: [MetalMeshletGeometryCache.Geometry] = []
      geometries.reserveCapacity(draws.count)
      for draw in draws {
        guard let geometry = cache.get(draw, device: device, limit: limit) else { return nil }
        geometries.append(geometry)
      }
      if frames[slot].map({
        $0.indices.length < plan.indexCount * 4 || $0.arguments.length < plan.argumentBytes
      }) ?? true {
        // Shared storage also permits the explicit test/debug readData API after GPU completion.
        guard
          let indices = device.makeBuffer(
            length: MeshletVisibilityLimits.bufferCapacity(
              required: plan.indexCount * 4, limit: limit), options: .storageModeShared),
          let arguments = device.makeBuffer(
            length: MeshletVisibilityLimits.bufferCapacity(
              required: plan.argumentBytes, limit: limit), options: .storageModeShared)
        else { return nil }
        frames[slot] = Frame(
          indices: MetalIndexBuffer(buffer: indices, indexFormat: .uInt32),
          arguments: MetalBuffer(buffer: arguments))
      }
      guard let frame = frames[slot] else { return nil }
      var occurrences: [MetalMeshletGeometryCache.Key: Int] = [:]
      let keys = draws.map { draw in
        let geometry = MetalMeshletGeometryCache.Key(
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
          let count = draw.geometry.clusters.count
          let required = count * 8 + ((count + 255) / 256) * 8 + MemoryLayout<MeshletGPUView>.stride
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
            let constants = device.makeBuffer(
              length: MemoryLayout<MeshletGPUView>.stride, options: .storageModeShared),
            let counts = device.makeBuffer(length: count * 4, options: .storageModePrivate),
            let offsets = device.makeBuffer(length: count * 4, options: .storageModePrivate),
            let groupScratch = device.makeBuffer(
              length: ((count + 255) / 256) * 8, options: .storageModePrivate)
          else { return nil }
          let value = DrawFrame(
            constants: constants, counts: counts, offsets: offsets, groupScratch: groupScratch,
            geometry: geometries[index], clusterCapacity: count, byteCount: required)
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
          if let base = $0.baseAddress {
            unsafe buffers.constants.contents().copyMemory(
              from: base, byteCount: $0.count)
          }
        }
      }
      frame.busy.withLock { $0 = true }
      let lease = MeshletFrameLease { frame.busy.withLock { $0 = false } }
      command.addCompletedHandler { lease.release() }
      // Separate encoders establish storage-write ordering between the three global phases.
      for pipeline in [classify, scan, scatter] {
        guard let encoder = command.commandBuffer.makeComputeCommandEncoder() else { return nil }
        encoder.label = "Meshlet stable compaction phase"
        encoder.setComputePipelineState(pipeline)
        for draw in activeDraws {
          encoder.setBuffer(draw.geometry.descriptors, offset: 0, index: 0)
          encoder.setBuffer(draw.geometry.indices, offset: 0, index: 1)
          encoder.setBuffer(draw.counts, offset: 0, index: 2)
          encoder.setBuffer(draw.offsets, offset: 0, index: 3)
          encoder.setBuffer(frame.indices.buffer, offset: 0, index: 4)
          encoder.setBuffer(frame.arguments.buffer, offset: 0, index: 5)
          encoder.setBuffer(draw.constants, offset: 0, index: 6)
          encoder.setBuffer(draw.groupScratch, offset: 0, index: 7)
          encoder.setBuffer(draw.geometry.nodes, offset: 0, index: 8)
          let isScan = pipeline === scan
          let isScatter = pipeline === scatter
          encoder.dispatchThreadgroups(
            MTLSize(width: isScatter ? min(1024, draw.clusterCapacity) : (isScan ? 1 : (draw.clusterCapacity + 255) / 256),
              height: isScatter ? (draw.clusterCapacity + 1023) / 1024 : 1, depth: 1),
            threadsPerThreadgroup: MTLSize(width: isScatter ? 64 : (isScan ? 1 : 256), height: 1, depth: 1))
        }
        encoder.endEncoding()
      }
      nextFrame = (slot + 1) % frames.count
      return MeshletVisibilityOutput(
        indices: frame.indices, arguments: frame.arguments, drawCount: draws.count)
    }

    private enum CreationError: Error {
      case missingFunction(String)
      case unsupportedThreadgroup
    }
  }
#endif
