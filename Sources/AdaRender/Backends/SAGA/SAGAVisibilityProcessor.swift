#if SAGA_NATIVE || SAGA_METAL
    import Math
    import SAGACompiler
    import SAGACore
    import SAGAShaderIR
    import SAGATypes
    import Synchronization

    struct SAGAVisibilityPipelines: Sendable {
        let copy = ResourceSlot<ComputePipeline>()
        let reduce = ResourceSlot<ComputePipeline>()
        let compact = ResourceSlot<ComputePipeline>()

        var isReady: Bool {
            (try? copy.get()) != nil && (try? reduce.get()) != nil && (try? compact.get()) != nil
        }

        init(context: SAGAContext) throws {
            let compiler = IndependentShaderCompiler()
            let copyArtifact = try compiler.compileCompute(.wgsl(SAGAVisibilityShaders.copy), to: context.shaderOutput)
            let reduceArtifact = try compiler.compileCompute(.wgsl(SAGAVisibilityShaders.reduce), to: context.shaderOutput)
            let compactArtifact = try compiler.compileCompute(.wgsl(SAGAVisibilityShaders.compact), to: context.shaderOutput)
            context.queue.enqueue { [self] device in
                copy.fulfill(try await device.createComputePipeline(copyArtifact))
                reduce.fulfill(try await device.createComputePipeline(reduceArtifact))
                compact.fulfill(try await device.createComputePipeline(compactArtifact))
            }
        }
    }

    /// One camera owns its depth pyramid and frame ring. Uploads and dispatches are recorded after the depth prepass.
    final class SAGAVisibilityProcessor: GPUVisibilityProcessor, Sendable {
        private struct View {
            var projection: Transform3D
            var width: UInt32
            var height: UInt32
            var count: UInt32
            var words: UInt32
        }

        private struct Frame: Sendable {
            let candidates: SAGABuffer
            let constants: SAGABuffer
            let instances: SAGABuffer
            let arguments: SAGABuffer

            var isReady: Bool {
                [candidates, constants, instances, arguments].allSatisfy { (try? $0.slot.get()) != nil }
            }
        }

        private final class Pyramid: Sendable {
            let size: SizeInt
            let texture = ResourceSlot<ResourceID>()
            let levels: [ResourceSlot<ResourceID>]
            let context: SAGAContext

            var isReady: Bool {
                (try? texture.get()) != nil && levels.allSatisfy { (try? $0.get()) != nil }
            }

            init(size: SizeInt, context: SAGAContext) {
                self.size = size
                self.context = context
                let count = Int.bitWidth - max(size.width, size.height).leadingZeroBitCount
                levels = (0..<count).map { _ in ResourceSlot<ResourceID>() }
                context.queue.enqueue { [texture, levels] device in
                    let id = try await device.createTexture(.init(
                        width: UInt32(size.width), height: UInt32(size.height), format: .r32Float,
                        usage: [.textureBinding, .storageBinding], mipLevelCount: UInt32(count)
                    ))
                    texture.fulfill(id)
                    for (index, level) in levels.enumerated() {
                        level.fulfill(try await device.createTextureView(texture: id, .init(baseMipLevel: UInt32(index), mipLevelCount: 1)))
                    }
                }
            }

            deinit {
                context.queue.enqueue { [texture, levels] device in
                    for level in levels {
                        if let id = try? level.get() { try await device.destroyTextureView(id) }
                    }
                    if let id = try? texture.get() { try await device.destroyTexture(id) }
                }
            }
        }

        private struct State {
            var pyramid: Pyramid?
            var frames: [Frame?]
            var cursor = 0
        }

        private let context: SAGAContext
        private let pipelines: SAGAVisibilityPipelines
        private let state: Mutex<State>

        init(context: SAGAContext) throws {
            self.context = context
            pipelines = try context.visibilityPipelines.withLock { cached in
                if let cached { return cached }
                let compiled = try SAGAVisibilityPipelines(context: context)
                cached = compiled
                return compiled
            }
            state = Mutex(State(frames: Array(repeating: nil, count: max(1, unsafe RenderEngine.configurations.maxFramesInFlight))))
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
            guard pipelines.isReady,
                  let command = command as? SAGACommandBuffer, command.context === context,
                  let depth = depth.gpuTexture as? SAGAGPUTexture, depth.context === context,
                  let input = instances as? SAGABuffer, input.context === context, input.usage.contains(.storage),
                  depth.size.width > 0, depth.size.height > 0,
                  (try? depth.slot.get()) != nil, (try? input.slot.get()) != nil,
                  validates(inputLength: input.length, stride: instanceStride, candidates: candidates, draws: draws)
            else { return nil }

            let prepared = state.withLock { state -> (Pyramid, Frame)? in
                let pyramid = state.pyramid.flatMap { $0.size == depth.size ? $0 : nil }
                    ?? Pyramid(size: depth.size, context: context)
                state.pyramid = pyramid
                // Keep the CPU visibility path active during preparation or if creation failed.
                guard pyramid.isReady else { return nil }
                let candidateBytes = candidates.count * MemoryLayout<GPUVisibilityCandidate>.stride
                let argumentBytes = draws.count * MemoryLayout<IndexedIndirectArguments>.stride
                let slot = state.cursor
                let frame: Frame
                if let existing = state.frames[slot], existing.candidates.length >= candidateBytes,
                   existing.instances.length >= input.length, existing.arguments.length >= argumentBytes {
                    frame = existing
                } else {
                    frame = Frame(
                        candidates: SAGABuffer(context: context, label: "Visibility candidates", length: candidateBytes, usage: [.storage, .copyDestination]),
                        constants: SAGABuffer(context: context, label: "Visibility view", length: MemoryLayout<View>.stride, usage: [.uniform, .copyDestination]),
                        instances: SAGABuffer(context: context, label: "Visible instances", length: input.length, usage: [.storage, .vertex, .copySource]),
                        arguments: SAGABuffer(context: context, label: "Visible draw arguments", length: argumentBytes, usage: [.storage, .indirect, .copyDestination, .copySource])
                    )
                    state.frames[slot] = frame
                }
                guard frame.isReady else { return nil }
                state.cursor = (slot + 1) % state.frames.count
                return (pyramid, frame)
            }
            guard let (pyramid, frame) = prepared else { return nil }

            var initializedDraws = draws
            for index in initializedDraws.indices { initializedDraws[index].instanceCount = 0 }
            let view = View(
                projection: viewProjection, width: UInt32(depth.size.width), height: UInt32(depth.size.height),
                count: UInt32(candidates.count), words: UInt32(instanceStride / 4)
            )
            appendWrite(unsafe candidates.withUnsafeBytes { Array($0) }, to: frame.candidates, on: command)
            appendWrite(unsafe initializedDraws.withUnsafeBytes { Array($0) }, to: frame.arguments, on: command)
            appendWrite(unsafe withUnsafeBytes(of: view) { Array($0) }, to: frame.constants, on: command)

            let width = UInt32(depth.size.width), height = UInt32(depth.size.height)
            command.append { [pipelines] in
                .dispatchCompute(pipeline: try pipelines.copy.get(), bindings: [:], workgroups: .init(x: (width + 7) / 8, y: (height + 7) / 8),
                                 textures: [.init(binding: 0): try depth.slot.get(), .init(binding: 1): try pyramid.levels[0].get()])
            }
            for level in pyramid.levels.indices.dropFirst() {
                command.append { [pipelines] in
                    .dispatchCompute(
                        pipeline: try pipelines.reduce.get(), bindings: [:],
                        workgroups: .init(x: (max(1, width >> level) + 7) / 8, y: (max(1, height >> level) + 7) / 8),
                        textures: [.init(binding: 0): try pyramid.levels[level - 1].get(), .init(binding: 1): try pyramid.levels[level].get()]
                    )
                }
            }
            let groups = UInt32((candidates.count + 63) / 64)
            let columns = min(groups, context.capabilities.maxComputeWorkgroupsPerDimension)
            command.append { [pipelines] in
                .dispatchCompute(
                    pipeline: try pipelines.compact.get(),
                    bindings: [
                        .init(binding: 1): try frame.candidates.slot.get(), .init(binding: 2): try input.slot.get(),
                        .init(binding: 3): try frame.instances.slot.get(), .init(binding: 4): try frame.arguments.slot.get(),
                        .init(binding: 5): try frame.constants.slot.get(),
                    ],
                    workgroups: .init(x: columns, y: (groups + columns - 1) / columns),
                    textures: [.init(binding: 0): try pyramid.texture.get()]
                )
            }
            return GPUVisibilityOutput(instances: frame.instances, arguments: frame.arguments, drawCount: draws.count)
        }

        private func appendWrite(_ bytes: [UInt8], to buffer: SAGABuffer, on command: SAGACommandBuffer) {
            command.append { .writeBytes(buffer: try buffer.slot.get(), offset: 0, bytes: bytes) }
        }

        private func validates(inputLength: Int, stride: Int, candidates: [GPUVisibilityCandidate], draws: [IndexedIndirectArguments]) -> Bool {
            let limit = Int(min(context.capabilities.maxBufferSize, 128 * 1_024 * 1_024))
            guard stride > 0, stride % 4 == 0, inputLength > 0, inputLength % 4 == 0, inputLength <= limit,
                  !candidates.isEmpty, !draws.isEmpty,
                  candidates.count <= limit / MemoryLayout<GPUVisibilityCandidate>.stride,
                  draws.count <= limit / MemoryLayout<IndexedIndirectArguments>.stride,
                  draws.allSatisfy({ $0.firstInstance == 0 }) else { return false }
            let capacity = UInt64(inputLength / stride)
            var counts: [UInt32: Int] = [:]
            var starts: [UInt32: UInt32] = [:]
            for candidate in candidates {
                guard UInt64(candidate.source) < capacity, UInt64(candidate.draw) < UInt64(draws.count),
                      UInt64(candidate.destination) + UInt64(draws[Int(candidate.draw)].instanceCount) <= capacity,
                      starts[candidate.draw] == nil || starts[candidate.draw] == candidate.destination else { return false }
                starts[candidate.draw] = candidate.destination
                counts[candidate.draw, default: 0] += 1
                if counts[candidate.draw, default: 0] > Int(draws[Int(candidate.draw)].instanceCount) { return false }
            }
            let segments = starts.map { (start: UInt64($0.value), end: UInt64($0.value) + UInt64(draws[Int($0.key)].instanceCount)) }
                .sorted { $0.start < $1.start }
            for index in segments.indices.dropFirst() where segments[index - 1].end > segments[index].start { return false }
            return true
        }
    }
#endif
