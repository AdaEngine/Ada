//
//  SAGACommandBuffer.swift
//  AdaEngine
//
//  Records AdaRender's stateful encoders as SAGA command lists.
//

#if SAGA_RENDER && canImport(SAGACompiler)
    import AdaUtils
    import Foundation
    import Math
    import SAGA
    import SAGACore
    import SAGAShaderIR
    import SAGATypes
    import Synchronization
    #if SAGA_METAL_NATIVE_PASS
    @_spi(IndexedDrawGrouping) import SAGAMetal
    #endif

    /// Builds one SAGA command when the device queue runs, after earlier resource work resolved its slots.
    typealias SAGACommandBuilder = @Sendable () throws -> BufferCommand

    final class SAGACommandQueue: CommandQueue {
        let context: SAGAContext

        init(context: SAGAContext) {
            self.context = context
        }

        func makeCommandBuffer() -> CommandBuffer {
            SAGACommandBuffer(context: context)
        }
    }

    final class SAGACommandBuffer: CommandBufferWithDeferredRetention, @unchecked Sendable {
        private static let tracesSubmission = ProcessInfo.processInfo.environment["ADAENGINE_SAGA_TRACE_GROUPING"] == "1"
        var label: String?
        let context: SAGAContext
        private var builders: [SAGACommandBuilder] = []
        #if SAGA_METAL_NATIVE_PASS
        private var groupableDraws: [Int: MetalIndexedDrawGrouping] = [:]

        func recordIndexedDrawGrouping(_ grouping: IndexedDrawGrouping, colorCount: Int, hasDepthStencil: Bool) {
            let permissions: MetalIndexedDrawGrouping
            switch grouping {
            case .ui where colorCount == 1 && !hasDepthStencil:
                permissions = .color
            case .shadowDepth where colorCount == 1 && hasDepthStencil:
                permissions = [.color, .depthStencil]
            case .geometry where colorCount > 1 && hasDepthStencil:
                permissions = [.color, .depthStencil, .multipleColorAttachments]
            default:
                return
            }
            groupableDraws[builders.count] = permissions
        }
        #endif
        private var completedHandlers: [@Sendable () -> Void] = []
        private var submissionObservers: [@Sendable (Bool) -> Void] = []
        private var timingHandlers: [@Sendable (Double?) -> Void] = []
        private var retainedResources: [any Sendable] = []

        init(context: SAGAContext) {
            self.context = context
        }

        func append(_ builder: @escaping SAGACommandBuilder) {
            builders.append(builder)
        }

        func beginRenderPass(_ desc: RenderPassDescriptor) -> RenderCommandEncoder {
            SAGARenderCommandEncoder(buffer: self, descriptor: desc)
        }

        #if SAGA_METAL_NATIVE_PASS
        func beginFoveatedRenderPass(_ desc: RenderPassDescriptor, rateMap: any RasterizationRateMap) throws -> FoveatedRenderPass {
            guard context.shaderOutput == .msl, let map = rateMap as? MetalRasterizationRateMap else {
                throw FoveatedRenderingError.unsupportedBackend
            }
            return try map.beginSAGAPass(desc, commands: self)
        }
        #endif

        #if SAGA_NATIVE || SAGA_METAL
        func beginComputePass(_: ComputePassDescriptor) -> (any ComputeCommandEncoder)? {
            SAGAComputeCommandEncoder(buffer: self)
        }
        #endif

        func beginBlitPass(_: BlitPassDescriptor) -> BlitCommandEncoder {
            SAGABlitCommandEncoder(buffer: self)
        }

        func retainUntilRetired(_ resource: any Sendable) {
            retainedResources.append(resource)
        }

        func commit() {
            #if SAGA_METAL_NATIVE_PASS
            let groupableDraws = self.groupableDraws
            self.groupableDraws = [:]
            #endif
            let builders = self.builders
            self.builders = []
            let completed = completedHandlers
            let observers = submissionObservers
            submissionObservers = []
            let reportResult: @Sendable (Bool) -> Void = { success in
                observers.forEach { $0(success) }
            }
            let timing = timingHandlers
            let resources = retainedResources
            let hasCompletionHandlers = !completed.isEmpty || !timing.isEmpty
            let debugErrors = context.debugErrors
            let usesDirect3D12 = context.shaderOutput == .hlsl
            let measuresVulkan = context.shaderOutput == .spirv && !timing.isEmpty
            let queue = context.queue
            #if os(Windows)
                let retireOffQueue = hasCompletionHandlers && !debugErrors
            #else
                let retireOffQueue = false
            #endif
            let submissionLabel = label ?? "-"
            completedHandlers = []
            timingHandlers = []
            retainedResources = []
            let finish: @Sendable (Bool, Double?) -> Void = { success, seconds in
                reportResult(success)
                timing.forEach { $0(seconds) }
                completed.forEach { $0() }
                withExtendedLifetime(resources) {}
            }
            let notifyUnavailable: @Sendable () -> Void = { finish(false, nil) }
            let unavailable = hasCompletionHandlers || !observers.isEmpty ? notifyUnavailable : nil
            queue.enqueue(onUnavailable: unavailable) { device in
                var completedHere = true
                var succeeded = false
                var seconds: Double?
                defer {
                    if completedHere {
                        if retireOffQueue {
                            let result = succeeded
                            let duration = seconds
                            queue.enqueueRetirement { finish(result, duration) }
                        } else {
                            finish(succeeded, seconds)
                        }
                    }
                }
                let wait: @Sendable () async throws -> Double?
                if builders.isEmpty {
                    guard hasCompletionHandlers || !observers.isEmpty else {
                        return
                    }
                    // Even an empty frame fence must retire after earlier device work.
                    if usesDirect3D12 {
                        let fence = try await device.submitCommands([])
                        wait = {
                            _ = try await fence.wait()
                            return nil
                        }
                    } else {
                        let fence = try await device.submitResourceUse([])
                        wait = {
                            try await fence.wait()
                            return nil
                        }
                    }
                } else {
                    let submission = PerformanceStallProbe.begin()
                    defer {
                        if submission != nil { PerformanceStallProbe.end("SAGA.Submit.\(submissionLabel)", since: submission, count: builders.count) }
                    }
                    let commands = try builders.map { try $0() }
                    var capture = measuresVulkan ? await SAGAVulkanTiming.prepare(commands, on: device) : nil
                    let submittedCommands = capture?.commands ?? commands
                    let ticket: CommandTicket
                    do {
                        #if SAGA_METAL_NATIVE_PASS
                        if !groupableDraws.isEmpty {
                            ticket = try await MetalIndexedDrawGrouping.$commands.withValue(groupableDraws) {
                                try await device.submitCommands(submittedCommands)
                            }
                        } else {
                            ticket = try await device.submitCommands(submittedCommands)
                        }
                        #else
                        ticket = try await device.submitCommands(submittedCommands)
                        #endif
                        if Self.tracesSubmission {
                            print("ADA-SAGA\t\(Date().timeIntervalSince1970)\t\(ticket.sequence)\t\(submissionLabel)")
                        }
                    } catch GPUError.validation where capture != nil {
                        // SAGA rejects invalid command lists before submission. Keep rendering if only profiling is unsupported.
                        await capture?.release(on: device)
                        capture = nil
                        ticket = try await device.submitCommands(commands)
                    } catch {
                        await capture?.release(on: device)
                        if debugErrors {
                            print("[SAGA] submit failed with \(error): \(commands.count) commands")
                            for command in commands.prefix(6) { print("[SAGA]   \(String(String(describing: command).prefix(700)))") }
                        }
                        throw error
                    }
                    let timing = capture
                    wait = {
                        if let timing {
                            return try await timing.complete(ticket, on: device)
                        }
                        _ = try await ticket.wait()
                        return nil
                    }
                }

                if retireOffQueue {
                    completedHere = false
                    queue.enqueueRetirement {
                        do {
                            finish(true, try await wait())
                        } catch {
                            finish(false, nil)
                            throw error
                        }
                    }
                } else if hasCompletionHandlers || debugErrors || builders.isEmpty {
                    seconds = try await wait()
                    succeeded = true
                } else if !resources.isEmpty || !observers.isEmpty {
                    // Observe retirement off the ordered bridge without delaying later submissions.
                    completedHere = false
                    Task {
                        do {
                            finish(true, try await wait())
                        } catch {
                            finish(false, nil)
                        }
                    }
                }
                if debugErrors && !builders.isEmpty {
                    for error in await device.takeUncapturedErrors() {
                        print("[SAGA] device error: \(error)")
                    }
                }
            }
        }

        func observeSubmissionResult(_ observer: @escaping @Sendable (Bool) -> Void) {
            submissionObservers.append(observer)
        }

        func addCompletedHandler(_ handler: @escaping @Sendable () -> Void) {
            completedHandlers.append(handler)
        }

        func addCompletedTimingHandler(_ handler: @escaping @Sendable (Double?) -> Void) {
            timingHandlers.append(handler)
        }
    }

    // MARK: - Render encoder

    /// A pass attachment resolved when the command list is built.
    ///
    /// SAGA turns every draw into its own render pass, so attachments always store: a later draw of the same
    /// AdaRender pass loads them, and a discarded store would leave that draw with undefined contents.
    private struct PassColor: Sendable {
        let slot: ResourceSlot<ResourceID>
        let clear: RenderClearColor?
        let store: RenderStoreAction
        let resolve: ResourceSlot<ResourceID>?
        let format: TextureFormat
        /// The attachments' owners. A texture destroys its GPU resource on deinit, which must not run before the
        /// pass that draws into it was built.
        let owners: [SAGAGPUTexture]
    }

    private struct PassDepth: Sendable {
        let slot: ResourceSlot<ResourceID>
        let depthClear: Double?
        let depthStore: RenderStoreAction
        let stencilClear: UInt32?
        let stencilStore: RenderStoreAction
        let hasStencil: Bool
        let format: TextureFormat
        let owner: SAGAGPUTexture
    }

    private struct BufferBinding: Sendable {
        let buffer: SAGABuffer
        let offset: Int
        let size: Int
    }

    final class SAGARenderCommandEncoder: RenderCommandEncoder, @unchecked Sendable {
        private let buffer: SAGACommandBuffer
        private let colors: [PassColor]
        private let depth: PassDepth?
        private var drewInPass = false
        #if SAGA_METAL_NATIVE_PASS
        var rateMap: MetalRasterizationRateBinding?
        var indexedDrawGrouping: IndexedDrawGrouping?
        #endif

        private var pipeline: SAGARenderPipeline?
        private var vertexBuffers: [Int: BufferBinding] = [:]
        private var uniforms: [ComputeBindingSlot: BufferBinding] = [:]
        private var textures: [ComputeBindingSlot: SAGAGPUTexture] = [:]
        private var accelerationStructures: [ComputeBindingSlot: SAGAAccelerationStructure] = [:]
        private var samplers: [ComputeBindingSlot: SAGASampler] = [:]
        private var index: (buffer: SAGABuffer, format: IndexFormat, offset: Int)?
        private var viewport: RenderViewport?
        private var scissor: RenderScissor?

        init(buffer: SAGACommandBuffer, descriptor: RenderPassDescriptor) {
            self.buffer = buffer
            var colors = descriptor.colorAttachments.compactMap { attachment -> PassColor? in
                guard let texture = attachment.texture.gpuTexture as? SAGAGPUTexture,
                      let format = texture.pixelFormat.sagaFormat else { return nil }
                let loads = attachment.operation?.loadAction ?? .clear
                let color = attachment.clearColor ?? AdaUtils.Color.black
                return PassColor(
                    slot: texture.slot,
                    clear: loads == .clear
                        ? RenderClearColor(
                            red: Double(color.red),
                            green: Double(color.green),
                            blue: Double(color.blue),
                            alpha: Double(color.alpha)
                        ) : nil,
                    store: .store,
                    resolve: (attachment.resolveTexture?.gpuTexture as? SAGAGPUTexture)?.slot,
                    format: format,
                    owners: [texture] + [attachment.resolveTexture?.gpuTexture as? SAGAGPUTexture].compactMap { $0 }
                )
            }
            if colors.isEmpty, let depthTexture = descriptor.depthStencilAttachment?.texture.gpuTexture as? SAGAGPUTexture {
                // SAGA Vulkan cannot draw without a color attachment, so a depth-only pass gets a placeholder of the same
                // size. Its pipelines write nothing to it (see `SAGARenderPipeline`). Drop this when SAGA supports
                // depth-only passes.
                if let placeholder = try? SAGAGPUTexture(
                    context: buffer.context,
                    descriptor: AdaRender.TextureDescriptor(
                        width: depthTexture.size.width,
                        height: depthTexture.size.height,
                        pixelFormat: .rgba8,
                        textureUsage: [.renderTarget],
                        textureType: .texture2D,
                        mipmapLevel: 1
                    )
                ) {
                    colors = [
                        PassColor(
                        slot: placeholder.slot, clear: nil, store: .store, resolve: nil, format: .rgba8Unorm, owners: [placeholder]
                    )
                    ]
                }
            }
            self.colors = colors
            if let attachment = descriptor.depthStencilAttachment,
               let texture = attachment.texture.gpuTexture as? SAGAGPUTexture,
               let depthFormat = texture.pixelFormat.sagaFormat {
                let hasStencil = texture.pixelFormat == .depth24_stencil8 || texture.pixelFormat == .depth_32f_stencil8
                self.depth = PassDepth(
                    slot: texture.slot,
                    depthClear: (attachment.depthOperation?.loadAction ?? .clear) == .clear ? 1 : nil,
                    depthStore: .store,
                    stencilClear: (attachment.stencilOperation?.loadAction ?? .clear) == .clear ? 1 : nil,
                    stencilStore: .store,
                    hasStencil: hasStencil,
                    format: depthFormat,
                    owner: texture
                )
            } else {
                self.depth = nil
            }
        }

        func pushDebugName(_: String) {}
        func popDebugName() {}

        func setRenderPipelineState(_ pipeline: RenderPipeline) {
            self.pipeline = pipeline as? SAGARenderPipeline
            #if SAGA_METAL_NATIVE_PASS
            if let layer = rateMap?.vertexLayer, let base = self.pipeline {
                do {
                    self.pipeline = try base.rasterizedVariant(layer: layer)
                } catch {
                    self.pipeline = nil
                    buffer.append { throw error }
                }
            }
            #endif
        }

        // MARK: Resources

        private func binding(_ buffer: any Buffer, offset: Int) -> BufferBinding? {
            guard let buffer = buffer as? SAGABuffer else {
                return nil
            }
            return BufferBinding(buffer: buffer, offset: offset, size: buffer.length - offset)
        }

        func setVertexBuffer(_ buffer: UniformBuffer, offset: Int, slot: Int) {
            uniforms[ComputeBindingSlot(group: 0, binding: UInt32(slot))] = binding(buffer, offset: offset)
        }

        func setVertexBuffer(_ buffer: VertexBuffer, offset: Int, slot: Int) {
            vertexBuffers[slot] = binding(buffer, offset: offset)
        }

        func setFragmentBuffer(_ buffer: UniformBuffer, offset: Int, slot: Int) {
            uniforms[ComputeBindingSlot(group: 0, binding: UInt32(slot))] = binding(buffer, offset: offset)
        }

        func setVertexBuffer<T>(_ bufferData: BufferData<T>, offset: Int, slot: Int) {
            guard let raw = bufferData.buffer, let bound = binding(raw, offset: offset) else {
                return
            }
            uniforms[ComputeBindingSlot(group: 0, binding: UInt32(slot))] = bound
            vertexBuffers[slot] = bound
        }

        func setFragmentBuffer<T>(_ bufferData: BufferData<T>, offset: Int, slot: Int) {
            guard let raw = bufferData.buffer else {
                return
            }
            uniforms[ComputeBindingSlot(group: 0, binding: UInt32(slot))] = binding(raw, offset: offset)
        }

        func setIndexBuffer<T>(_ bufferData: BufferData<T>, indexFormat: IndexBufferFormat) {
            guard let buffer = bufferData.buffer as? SAGABuffer else {
                return
            }
            index = (buffer, indexFormat == .uInt32 ? .uint32 : .uint16, 0)
        }

        func setIndexBuffer(_ buffer: IndexBuffer, offset: Int) {
            guard let buffer = buffer as? SAGAIndexBuffer else {
                return
            }
            index = (buffer, buffer.indexFormat == .uInt32 ? .uint32 : .uint16, offset)
        }

        func setVertexBytes(_ bytes: UnsafeRawPointer, length: Int, slot: Int) {
            // Inline bytes get a fresh uniform buffer, as on the other backends.
            let inline = SAGAUniformBuffer(context: buffer.context, length: length, binding: slot)
            unsafe inline.setData(UnsafeMutableRawPointer(mutating: bytes), byteCount: length, offset: 0)
            uniforms[ComputeBindingSlot(group: 0, binding: UInt32(slot))] = BufferBinding(
                buffer: inline, offset: 0, size: inline.length
            )
        }

        func setFragmentTexture(_ texture: Texture, slot: Int) {
            textures[ComputeBindingSlot(group: 0, binding: UInt32(slot))] = texture.gpuTexture as? SAGAGPUTexture
        }

        func setFragmentSamplerState(_ sampler: Sampler, slot: Int) {
            samplers[ComputeBindingSlot(group: 0, binding: UInt32(slot))] = sampler as? SAGASampler
        }

        func setResourceSet(_ resourceSet: RenderResourceSet, index set: Int) {
            for entry in resourceSet.bindings {
                let slot = ComputeBindingSlot(group: UInt32(set), binding: UInt32(entry.binding))
                switch entry.resource {
                case let .uniformBuffer(buffer, offset):
                    uniforms[slot] = binding(buffer, offset: offset)
                case let .storageBuffer(buffer):
                    uniforms[slot] = binding(buffer, offset: 0)
                case let .texture(texture):
                    textures[slot] = texture.gpuTexture as? SAGAGPUTexture
                case let .sampler(sampler):
                    samplers[slot] = sampler as? SAGASampler
                case let .accelerationStructure(structure):
                    accelerationStructures[slot] = structure as? SAGAAccelerationStructure
                }
            }
        }

        func setViewport(_ viewport: Rect) {
            self.viewport = RenderViewport(
                x: Float(viewport.origin.x),
                y: Float(viewport.origin.y),
                width: Float(viewport.size.width),
                height: Float(viewport.size.height)
            )
        }

        func setScissorRect(_ rect: Rect) {
            scissor = RenderScissor(
                x: UInt32(max(0, rect.origin.x)),
                y: UInt32(max(0, rect.origin.y)),
                width: UInt32(max(0, rect.size.width)),
                height: UInt32(max(0, rect.size.height))
            )
        }

        func setTriangleFillMode(_: TriangleFillMode) {}

        // MARK: Draws

        func drawIndexedIndirect(arguments: any Buffer, offset: Int) -> Bool {
            guard let arguments = arguments as? SAGABuffer,
                  arguments.context === buffer.context, arguments.usage.contains(.indirect),
                  offset >= 0, offset % 4 == 0, offset <= arguments.length,
                  arguments.length - offset >= MemoryLayout<IndexedIndirectArguments>.stride,
                  let index, index.buffer.context === buffer.context,
                  index.offset >= 0, index.offset <= index.buffer.length,
                  index.offset % Int(index.format.byteSize) == 0,
                  index.buffer.length - index.offset >= Int(index.format.byteSize),
                  let state = captureState() else { return false }
            emit { target in
                .renderIndirect(
                    pipeline: try state.pipeline.slot.get(),
                    target: target.color0,
                    colorLoad: target.colorLoad,
                    indirectBuffer: try arguments.slot.get(),
                    indirectOffset: UInt64(offset),
                    indexBuffer: IndexBufferBinding(
                        buffer: try index.buffer.slot.get(),
                        format: index.format,
                        offset: UInt64(index.offset),
                        size: UInt64(index.buffer.length - index.offset)
                    ),
                    vertexBuffers: try state.vertexBindings(),
                    uniforms: try state.bufferBindings(for: state.pipeline.uniformSlots),
                    textures: try state.textureBindings(),
                    samplers: try state.samplerBindings(),
                    depth: target.depth,
                    resolve: target.resolve,
                    additionalColors: target.additionalColors,
                    raster: state.raster,
                    storageBuffers: try state.bufferBindings(for: state.pipeline.storageSlots),
                    colorStore: target.colorStore
                )
            }
            return true
        }

        func drawIndexed(indexCount: Int, indexBufferOffset: Int, instanceCount: Int) {
            drawIndexed(indexCount: indexCount, indexBufferOffset: indexBufferOffset, instanceCount: instanceCount, firstInstance: 0)
        }

        func drawIndexed(indexCount: Int, indexBufferOffset: Int, instanceCount: Int, firstInstance: Int) {
            guard let index, let state = captureState() else {
                return
            }
            let draw = IndexedDraw(
                indexCount: UInt32(indexCount),
                firstIndex: UInt32(indexBufferOffset / Int(index.format.byteSize)),
                instances: DrawInstances(count: UInt32(instanceCount), first: UInt32(firstInstance))
            )
            #if SAGA_METAL_NATIVE_PASS
            if let indexedDrawGrouping {
                buffer.recordIndexedDrawGrouping(indexedDrawGrouping, colorCount: colors.count, hasDepthStencil: depth != nil)
            }
            #endif
            emit { target in
                .renderIndexed(
                    pipeline: try state.pipeline.slot.get(),
                    target: target.color0,
                    colorLoad: target.colorLoad,
                    indexBuffer: IndexBufferBinding(
                        buffer: try index.buffer.slot.get(),
                        format: index.format,
                        offset: UInt64(index.offset),
                        size: UInt64(index.buffer.length - index.offset)
                    ),
                    draw: draw,
                    vertexBuffers: try state.vertexBindings(),
                    uniforms: try state.bufferBindings(for: state.pipeline.uniformSlots),
                    textures: try state.textureBindings(),
                    samplers: try state.samplerBindings(),
                    depth: target.depth,
                    resolve: target.resolve,
                    additionalColors: target.additionalColors,
                    raster: state.raster,
                    storageBuffers: try state.bufferBindings(for: state.pipeline.storageSlots),
                    colorStore: target.colorStore
                )
            }
        }

        func draw(type _: IndexPrimitive, vertexStart: Int, vertexCount: Int, instanceCount: Int) {
            guard let state = captureState() else {
                return
            }
            emit { target in
                .render(
                    pipeline: try state.pipeline.slot.get(),
                    target: target.color0,
                    colorLoad: target.colorLoad,
                    vertexCount: UInt32(vertexCount),
                    vertexBuffers: try state.vertexBindings(),
                    firstVertex: UInt32(vertexStart),
                    instances: DrawInstances(count: UInt32(instanceCount)),
                    uniforms: try state.bufferBindings(for: state.pipeline.uniformSlots),
                    textures: try state.textureBindings(),
                    samplers: try state.samplerBindings(),
                    depth: target.depth,
                    resolve: target.resolve,
                    additionalColors: target.additionalColors,
                    raster: state.raster,
                    storageBuffers: try state.bufferBindings(for: state.pipeline.storageSlots),
                    colorStore: target.colorStore
                )
            }
        }

        func endRenderPass() {
            guard !drewInPass, !colors.isEmpty || depth != nil else {
                return
            }
            // No draw recorded: draw a degenerate triangle so the pass still applies its clears.
            #if SAGA_METAL_NATIVE_PASS
            let layer = rateMap?.vertexLayer
            let raster: RenderRasterState = rateMap == nil ? .init() : drawRaster
            #else
            let layer: UInt32? = nil
            let raster = RenderRasterState()
            #endif
            let clear = buffer.context.clearPipeline(colors: colors.map(\.format), depth: depth?.format, rasterizationLayer: layer)
            emit { target in
                .render(
                    pipeline: try clear.get(),
                    target: target.color0,
                    colorLoad: target.colorLoad,
                    vertexCount: 3,
                    depth: target.depth,
                    resolve: target.resolve,
                    additionalColors: target.additionalColors,
                    raster: raster,
                    colorStore: target.colorStore
                )
            }
        }

        private var drawRaster: RenderRasterState {
            #if SAGA_METAL_NATIVE_PASS
            RenderRasterState(viewport: viewport, scissor: scissor, rateMap: rateMap)
            #else
            RenderRasterState(viewport: viewport, scissor: scissor)
            #endif
        }

        // MARK: Capture

        /// Everything a draw reads, frozen at encode time. Resolved to resource ids on the device queue.
        private struct DrawState: Sendable {
            let pipeline: SAGARenderPipeline
            let vertex: [Int: BufferBinding]
            let uniforms: [ComputeBindingSlot: BufferBinding]
            let textures: [ComputeBindingSlot: SAGAGPUTexture]
            let accelerationStructures: [ComputeBindingSlot: SAGAAccelerationStructure]
            let samplers: [ComputeBindingSlot: SAGASampler]
            let raster: RenderRasterState

            func vertexBindings() throws -> [VertexBufferBinding] {
                try pipeline.vertexBufferSlots.enumerated().compactMap { gpuSlot, engineSlot in
                    guard let binding = vertex[engineSlot] else {
                        return nil
                    }
                    return VertexBufferBinding(buffer: try binding.buffer.slot.get(), offset: UInt64(binding.offset), slot: UInt32(gpuSlot))
                }
            }

            func bufferBindings(for slots: Set<ComputeBindingSlot>) throws -> [ComputeBindingSlot: ComputeBufferBinding] {
                var result: [ComputeBindingSlot: ComputeBufferBinding] = [:]
                result.reserveCapacity(slots.count)
                for slot in slots {
                    if let binding = uniforms[slot] {
                        result[slot] = ComputeBufferBinding(buffer: try binding.buffer.slot.get(), offset: UInt64(binding.offset), size: UInt64(binding.size))
                    }
                }
                return result
            }

            func textureBindings() throws -> [ComputeBindingSlot: ResourceID] {
                var result: [ComputeBindingSlot: ResourceID] = [:]
                result.reserveCapacity(pipeline.textureSlots.count + pipeline.accelerationStructureSlots.count)
                for slot in pipeline.textureSlots {
                    if let texture = textures[slot] { result[slot] = try texture.sampledSlot.get() }
                }
                for slot in pipeline.accelerationStructureSlots {
                    if let structure = accelerationStructures[slot] { result[slot] = try structure.slot.get() }
                }
                return result
            }

            func samplerBindings() throws -> [ComputeBindingSlot: ResourceID] {
                var result: [ComputeBindingSlot: ResourceID] = [:]
                result.reserveCapacity(pipeline.samplerSlots.count)
                for slot in pipeline.samplerSlots {
                    if let sampler = samplers[slot] { result[slot] = try sampler.slot.get() }
                }
                return result
            }
        }

        private func captureState() -> DrawState? {
            guard let pipeline else {
                return nil
            }
            for slot in pipeline.writableStorageSlots {
                uniforms[slot]?.buffer.excludeFromShadowCache()
            }
            if buffer.context.debugErrors, !pipeline.reportedMissingBindings {
                pipeline.reportedMissingBindings = true
                func names(_ slots: Set<ComputeBindingSlot>) -> String {
                    slots.map { "\($0.group):\($0.binding)" }.sorted().joined(separator: ",")
                }
                let missingBuffers = pipeline.uniformSlots.union(pipeline.storageSlots).subtracting(uniforms.keys)
                let missingTextures = pipeline.textureSlots.subtracting(textures.keys)
                let missingSamplers = pipeline.samplerSlots.subtracting(samplers.keys)
                let vd = pipeline.descriptor.vertexDescriptor
                let attrs = vd.attributes.buffer.enumerated().compactMap { index, a -> String? in
                    a.format == .invalid ? nil : "loc\(index):\(a.name)@buf\(a.bufferIndex)+\(a.offset)/\(a.format)"
                }
                let layouts = vd.activeBufferIndices.map { i in "buf\(i): stride=\(vd.layouts.buffer[i].stride) \(vd.layouts.buffer[i].stepFunction)" }
                print("[SAGA] pipeline '\(pipeline.descriptor.debugName)' vertex attrs=\(attrs) layouts=\(layouts)"
                    + " mapped=\(pipeline.vertexBufferSlots) boundEngineSlots=\(vertexBuffers.keys.sorted()) shaderInputs=\(pipeline.vertexInputLocations)")
                print("[SAGA] pipeline '\(pipeline.descriptor.debugName)' declares uniforms=\(names(pipeline.uniformSlots))"
                    + " textures=\(names(pipeline.textureSlots)) samplers=\(names(pipeline.samplerSlots));"
                    + " unbound uniforms=\(names(missingBuffers)) textures=\(names(missingTextures)) samplers=\(names(missingSamplers))")
            }
            return DrawState(
                pipeline: pipeline,
                vertex: vertexBuffers,
                uniforms: uniforms,
                textures: textures,
                accelerationStructures: accelerationStructures,
                samplers: samplers,
                raster: drawRaster
            )
        }

        /// Attachments for one draw. The first draw of the pass applies the clears; later draws load.
        private struct DrawTarget {
            let color0: ResourceID?
            let colorLoad: RenderColorLoadAction
            let colorStore: RenderStoreAction
            let resolve: RenderResolveAttachment?
            let additionalColors: [UInt32: RenderColorAttachment]
            let depth: RenderDepthAttachment?
        }

        private func emit(_ make: @escaping @Sendable (DrawTarget) throws -> BufferCommand) {
            let first = !drewInPass
            drewInPass = true
            let colors = self.colors
            let depth = self.depth
            buffer.append {
                var additional: [UInt32: RenderColorAttachment] = [:]
                for (offset, color) in colors.enumerated().dropFirst() {
                    additional[UInt32(offset)] = RenderColorAttachment(
                        texture: try color.slot.get(),
                        loadAction: first ? (color.clear.map { .clear($0) } ?? .load) : .load,
                        storeAction: color.store
                    )
                }
                let depthAttachment = try depth.map { depth -> RenderDepthAttachment in
                    RenderDepthAttachment(
                        texture: try depth.slot.get(),
                        loadAction: first ? (depth.depthClear.map { .clear($0) } ?? .load) : .load,
                        stencil: depth.hasStencil
                            ? RenderStencilAttachmentState(
                                loadAction: first ? (depth.stencilClear.map { .clear($0) } ?? .load) : .load,
                                storeAction: depth.stencilStore
                            ) : nil,
                        storeAction: depth.depthStore
                    )
                }
                let first0 = colors.first
                let target = DrawTarget(
                    color0: try first0?.slot.get(),
                    colorLoad: first ? (first0?.clear.map { .clear($0) } ?? .load) : .load,
                    colorStore: first0?.store ?? .store,
                    resolve: try first0?.resolve.map { RenderResolveAttachment(texture: try $0.get()) },
                    additionalColors: additional,
                    depth: depthAttachment
                )
                return try make(target)
            }
        }
    }

    // MARK: - Blit encoder

    final class SAGABlitCommandEncoder: BlitCommandEncoder, @unchecked Sendable {
        private let buffer: SAGACommandBuffer

        init(buffer: SAGACommandBuffer) {
            self.buffer = buffer
        }

        func pushDebugName(_: String) {}
        func popDebugName() {}

        func copyTextureToTexture(
            source: Texture,
            sourceOrigin: Origin3D,
            sourceSize: Size3D,
            sourceMipLevel: Int,
            sourceSlice: Int,
            destination: Texture,
            destinationOrigin: Origin3D,
            destinationMipLevel: Int,
            destinationSlice: Int
        ) {
            guard let from = source.gpuTexture as? SAGAGPUTexture, let to = destination.gpuTexture as? SAGAGPUTexture else {
                return
            }
            let region = TextureCopyRegion(
                x: UInt32(sourceOrigin.x),
                y: UInt32(sourceOrigin.y),
                width: UInt32(sourceSize.width),
                height: UInt32(sourceSize.height),
                mipLevel: UInt32(sourceMipLevel),
                arrayLayer: UInt32(sourceSlice)
            )
            let origin = TextureCopyOrigin(
                x: UInt32(destinationOrigin.x),
                y: UInt32(destinationOrigin.y),
                mipLevel: UInt32(destinationMipLevel),
                arrayLayer: UInt32(destinationSlice)
            )
            let (src, dst) = (from.slot, to.slot)
            buffer.append {
                .copyTextureToTexture(source: try src.get(), destination: try dst.get(), sourceRegion: region, destinationOrigin: origin)
            }
        }

        func copyBufferToBuffer(source: Buffer, sourceOffset: Int, destination: Buffer, destinationOffset: Int, size: Int) {
            guard let from = source as? SAGABuffer, let to = destination as? SAGABuffer else {
                return
            }
            to.excludeFromShadowCache()
            let (src, dst) = (from.slot, to.slot)
            buffer.append {
                .copy(
                    source: try src.get(),
                    sourceOffset: UInt64(sourceOffset),
                    destination: try dst.get(),
                    destinationOffset: UInt64(destinationOffset),
                    byteCount: UInt64(size)
                )
            }
        }

        func copyBufferToTexture(
            source: Buffer,
            sourceOffset: Int,
            sourceBytesPerRow: Int,
            sourceBytesPerImage: Int,
            sourceSize: Size3D,
            destination: Texture,
            destinationOrigin: Origin3D,
            destinationMipLevel: Int,
            destinationSlice: Int
        ) {
            guard let from = source as? SAGABuffer, let to = destination.gpuTexture as? SAGAGPUTexture else {
                return
            }
            let layout = TextureBufferLayout(
                offset: UInt64(sourceOffset),
                bytesPerRow: UInt32(sourceBytesPerRow),
                rowsPerImage: sourceBytesPerRow > 0 ? UInt32(sourceBytesPerImage / sourceBytesPerRow) : nil
            )
            let region = TextureCopyRegion(
                x: UInt32(destinationOrigin.x),
                y: UInt32(destinationOrigin.y),
                width: UInt32(sourceSize.width),
                height: UInt32(sourceSize.height),
                mipLevel: UInt32(destinationMipLevel),
                arrayLayer: UInt32(destinationSlice)
            )
            let (src, dst) = (from.slot, to.slot)
            buffer.append {
                .copyBufferToTexture(source: try src.get(), layout: layout, destination: try dst.get(), region: region)
            }
        }

        func copyTextureToBuffer(
            source: Texture,
            sourceOrigin: Origin3D,
            sourceMipLevel: Int,
            sourceSlice: Int,
            sourceSize: Size3D,
            destination: Buffer,
            destinationOffset: Int,
            destinationBytesPerRow: Int,
            destinationBytesPerImage: Int
        ) {
            guard let from = source.gpuTexture as? SAGAGPUTexture, let to = destination as? SAGABuffer else {
                return
            }
            to.excludeFromShadowCache()
            let layout = TextureBufferLayout(
                offset: UInt64(destinationOffset),
                bytesPerRow: UInt32(destinationBytesPerRow),
                rowsPerImage: destinationBytesPerRow > 0 ? UInt32(destinationBytesPerImage / destinationBytesPerRow) : nil
            )
            let region = TextureCopyRegion(
                x: UInt32(sourceOrigin.x),
                y: UInt32(sourceOrigin.y),
                width: UInt32(sourceSize.width),
                height: UInt32(sourceSize.height),
                mipLevel: UInt32(sourceMipLevel),
                arrayLayer: UInt32(sourceSlice)
            )
            let (src, dst) = (from.slot, to.slot)
            buffer.append {
                .copyTextureRegionToBuffer(source: try src.get(), destination: try dst.get(), layout: layout, region: region)
            }
        }

        func endBlitPass() {}
    }
#endif
