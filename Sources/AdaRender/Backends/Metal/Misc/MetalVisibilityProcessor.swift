#if canImport(Metal)
    import Foundation
    import Math
    @unsafe @preconcurrency import Metal

    /// CPU state is protected by the lock; one camera owns the frame ring and submits on one queue.
    final class MetalVisibilityProcessor: GPUVisibilityProcessor, @unchecked Sendable {
        private struct View {
            var projection: Transform3D
            var width: UInt32
            var height: UInt32
            var count: UInt32
            var words: UInt32
        }
        private struct Frame {
            let candidates: MTLBuffer
            let constants: MTLBuffer
            let instances: MetalBuffer
            let arguments: MetalBuffer
        }
        private let lock = NSLock()
        private let device: MTLDevice
        private let copy: MTLComputePipelineState
        private let reduce: MTLComputePipelineState
        private let compact: MTLComputePipelineState
        private var frames: [Frame?]
        private var frame = 0
        private var pyramid: MTLTexture?
        private var levels: [MTLTexture] = []

        init(device: MTLDevice) throws {
            self.device = device
            let options = MTLCompileOptions()
            options.fastMathEnabled = false
            let library = try device.makeLibrary(source: MetalVisibilityShaders.source, options: options)
            func pipeline(_ name: String) throws -> MTLComputePipelineState {
                guard let function = library.makeFunction(name: name) else { throw CreationError.missingFunction(name) }
                return try device.makeComputePipelineState(function: function)
            }
            copy = try pipeline("visibility_copy")
            reduce = try pipeline("visibility_reduce")
            compact = try pipeline("visibility_compact")
            frames = Array(repeating: nil, count: max(1, unsafe RenderEngine.configurations.maxFramesInFlight))
        }

        func encode(
            on command: any CommandBuffer,
            depth: Texture,
            viewProjection: Transform3D,
            instances: any Buffer,
            instanceStride: Int,
            candidates: [GPUVisibilityCandidate],
            draws: [IndexedIndirectArguments]
        ) -> GPUVisibilityOutput? {
            lock.withLock {
                encodeLocked(
                    on: command,
                    depth: depth,
                    viewProjection: viewProjection,
                    instances: instances,
                    instanceStride: instanceStride,
                    candidates: candidates,
                    draws: draws
                )
            }
        }

        private func encodeLocked(
            on command: any CommandBuffer,
            depth: Texture,
            viewProjection: Transform3D,
            instances: any Buffer,
            instanceStride: Int,
            candidates: [GPUVisibilityCandidate],
            draws: [IndexedIndirectArguments]
        ) -> GPUVisibilityOutput? {
            guard let command = command as? MetalCommandEncoder, let source = depth.gpuTexture as? MetalGPUTexture,
                let input = instances as? MetalBuffer, !candidates.isEmpty, !draws.isEmpty, instanceStride > 0, instanceStride % 4 == 0
            else {
                return nil
            }
            let capacity = input.length / instanceStride
            var counts: [UInt32: Int] = [:]
            var starts: [UInt32: UInt32] = [:]
            for candidate in candidates {
                guard Int(candidate.source) < capacity, draws.indices.contains(Int(candidate.draw)),
                    Int(candidate.destination) + Int(draws[Int(candidate.draw)].instanceCount) <= capacity,
                    starts[candidate.draw] == nil || starts[candidate.draw] == candidate.destination
                else {
                    return nil
                }
                starts[candidate.draw] = candidate.destination
                counts[candidate.draw, default: 0] += 1
                if counts[candidate.draw, default: 0] > Int(draws[Int(candidate.draw)].instanceCount) {
                    return nil
                }
            }
            let width = source.texture.width
            let height = source.texture.height
            if pyramid?.width != width || pyramid?.height != height {
                let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r32Float, width: width, height: height, mipmapped: true)
                descriptor.usage = [.shaderRead, .shaderWrite]
                descriptor.storageMode = .private
                guard let texture = device.makeTexture(descriptor: descriptor) else {
                    return nil
                }
                pyramid = texture
                levels.removeAll(keepingCapacity: true)
                for level in 0..<texture.mipmapLevelCount {
                    guard let view = texture.makeTextureView(pixelFormat: .r32Float, textureType: .type2D, levels: level..<(level + 1), slices: 0..<1) else {
                        return nil
                    }
                    levels.append(view)
                }
            }
            guard let pyramid, !levels.isEmpty else {
                return nil
            }
            frame = (frame + 1) % frames.count
            let candidateBytes = candidates.count * MemoryLayout<GPUVisibilityCandidate>.stride
            let argumentBytes = draws.count * MemoryLayout<IndexedIndirectArguments>.stride
            if frames[frame]?.candidates.length ?? 0 < candidateBytes || frames[frame]?.instances.length ?? 0 < input.length
                || frames[frame]?.arguments.length ?? 0 < argumentBytes {
                guard let bounds = device.makeBuffer(length: candidateBytes, options: .storageModeShared),
                    let constants = device.makeBuffer(length: MemoryLayout<View>.stride, options: .storageModeShared),
                    let output = device.makeBuffer(length: input.length, options: .storageModePrivate),
                    let arguments = device.makeBuffer(length: argumentBytes, options: .storageModeShared)
                else {
                    return nil
                }
                frames[frame] = Frame(candidates: bounds, constants: constants, instances: MetalBuffer(buffer: output), arguments: MetalBuffer(buffer: arguments))
            }
            guard let buffers = frames[frame], let encoder = command.commandBuffer.makeComputeCommandEncoder() else {
                return nil
            }
            var commands = draws
            for index in commands.indices { commands[index].instanceCount = 0 }
            unsafe candidates.withUnsafeBytes { bytes in
                if let base = bytes.baseAddress { unsafe buffers.candidates.contents().copyMemory(from: base, byteCount: bytes.count) }
            }
            unsafe commands.withUnsafeBytes { bytes in
                if let base = bytes.baseAddress { unsafe buffers.arguments.buffer.contents().copyMemory(from: base, byteCount: bytes.count) }
            }
            var view = View(projection: viewProjection, width: UInt32(width), height: UInt32(height), count: UInt32(candidates.count), words: UInt32(instanceStride / 4))
            unsafe withUnsafeBytes(of: &view) { bytes in
                if let base = bytes.baseAddress { unsafe buffers.constants.contents().copyMemory(from: base, byteCount: bytes.count) }
            }
            encoder.label = "Hi-Z and instance compaction"
            encoder.setComputePipelineState(copy)
            encoder.setTexture(source.texture, index: 0)
            encoder.setTexture(levels[0], index: 1)
            encoder.dispatchThreads(MTLSize(width: width, height: height, depth: 1), threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
            encoder.memoryBarrier(scope: .textures)
            encoder.setComputePipelineState(reduce)
            for level in 1..<levels.count {
                encoder.setTexture(levels[level - 1], index: 0)
                encoder.setTexture(levels[level], index: 1)
                encoder.dispatchThreads(MTLSize(width: levels[level].width, height: levels[level].height, depth: 1), threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
                encoder.memoryBarrier(scope: .textures)
            }
            encoder.setComputePipelineState(compact)
            encoder.setTexture(pyramid, index: 0)
            encoder.setBuffer(buffers.candidates, offset: 0, index: 0)
            encoder.setBuffer(input.buffer, offset: 0, index: 1)
            encoder.setBuffer(buffers.instances.buffer, offset: 0, index: 2)
            encoder.setBuffer(buffers.arguments.buffer, offset: 0, index: 3)
            encoder.setBuffer(buffers.constants, offset: 0, index: 4)
            encoder.dispatchThreads(
                MTLSize(width: candidates.count, height: 1, depth: 1),
                threadsPerThreadgroup: MTLSize(width: min(64, compact.maxTotalThreadsPerThreadgroup), height: 1, depth: 1)
            )
            encoder.endEncoding()
            return GPUVisibilityOutput(instances: buffers.instances, arguments: buffers.arguments, drawCount: draws.count)
        }

        private enum CreationError: Error { case missingFunction(String) }
    }
#endif
