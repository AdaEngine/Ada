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
    import SAGATypes
    import Synchronization
    #if SAGA_METAL_NATIVE_PASS
    @_spi(IndexedDrawGrouping) import SAGAMetal
    import SAGAShaderIR
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

        func recordIndexedDrawGrouping(_ grouping: IndexedDrawGrouping) {
            groupableDraws[builders.count] = switch grouping {
            case .ui: .ui
            case .shadowDepth: .shadowDepth
            case .geometry: .geometry
            }
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
            let submissionLabel = label ?? "-"
            completedHandlers = []
            timingHandlers = []
            retainedResources = []
            let notifyCompletion: @Sendable () -> Void = {
                timing.forEach { $0(nil) }
                completed.forEach { $0() }
            }
            let notifyUnavailable: @Sendable () -> Void = {
                reportResult(false)
                notifyCompletion()
            }
            let unavailable = hasCompletionHandlers || !observers.isEmpty ? notifyUnavailable : nil
            context.queue.enqueue(onUnavailable: unavailable) { device in
                var reportsFailureOnExit = !observers.isEmpty
                defer {
                    if reportsFailureOnExit { reportResult(false) }
                    notifyCompletion()
                    withExtendedLifetime(resources) {}
                }
                guard !builders.isEmpty else {
                    if hasCompletionHandlers || !observers.isEmpty {
                        // Even an empty frame fence must retire after earlier device work.
                        let fence = try await device.submitResourceUse([])
                        try await fence.wait()
                        reportsFailureOnExit = false
                        reportResult(true)
                    }
                    return
                }
                let commands = try builders.map { try $0() }
                let ticket: CommandTicket
                do {
                    #if SAGA_METAL_NATIVE_PASS
                    if !groupableDraws.isEmpty {
                        ticket = try await MetalIndexedDrawGrouping.$commands.withValue(groupableDraws) {
                            try await device.submitCommands(commands)
                        }
                    } else {
                        ticket = try await device.submitCommands(commands)
                    }
                    #else
                    ticket = try await device.submitCommands(commands)
                    #endif
                    if Self.tracesSubmission {
                        print("ADA-SAGA\t\(Date().timeIntervalSince1970)\t\(ticket.sequence)\t\(submissionLabel)")
                    }
                } catch {
                    if debugErrors {
                        print("[SAGA] submit failed with \(error): \(commands.count) commands")
                        for command in commands.prefix(6) { print("[SAGA]   \(String(String(describing: command).prefix(700)))") }
                    }
                    throw error
                }
                if hasCompletionHandlers || debugErrors {
                    try await ticket.wait()
                    reportsFailureOnExit = false
                    reportResult(true)
                } else if !resources.isEmpty || !observers.isEmpty {
                    // Observe retirement off the ordered bridge without delaying later submissions.
                    reportsFailureOnExit = false
                    Task {
                        do {
                            _ = try await ticket.wait()
                            reportResult(true)
                        } catch {
                            reportResult(false)
                        }
                        withExtendedLifetime(resources) {}
                    }
                }
                if debugErrors {
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

    private struct BufferBinding {
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
                            red: Double(color.red), green: Double(color.green),
                            blue: Double(color.blue), alpha: Double(color.alpha)
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
                        width: depthTexture.size.width, height: depthTexture.size.height, pixelFormat: .rgba8,
                        textureUsage: [.renderTarget], textureType: .texture2D, mipmapLevel: 1
                    )
                ) {
                    colors = [PassColor(
                        slot: placeholder.slot, clear: nil, store: .store, resolve: nil, format: .rgba8Unorm, owners: [placeholder]
                    )]
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
            guard let buffer = buffer as? SAGABuffer else { return nil }
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
            guard let raw = bufferData.buffer, let bound = binding(raw, offset: offset) else { return }
            uniforms[ComputeBindingSlot(group: 0, binding: UInt32(slot))] = bound
            vertexBuffers[slot] = bound
        }

        func setFragmentBuffer<T>(_ bufferData: BufferData<T>, offset: Int, slot: Int) {
            guard let raw = bufferData.buffer else { return }
            uniforms[ComputeBindingSlot(group: 0, binding: UInt32(slot))] = binding(raw, offset: offset)
        }

        func setIndexBuffer<T>(_ bufferData: BufferData<T>, indexFormat: IndexBufferFormat) {
            guard let buffer = bufferData.buffer as? SAGABuffer else { return }
            index = (buffer, indexFormat == .uInt32 ? .uint32 : .uint16, 0)
        }

        func setIndexBuffer(_ buffer: IndexBuffer, offset: Int) {
            guard let buffer = buffer as? SAGAIndexBuffer else { return }
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
                x: Float(viewport.origin.x), y: Float(viewport.origin.y),
                width: Float(viewport.size.width), height: Float(viewport.size.height)
            )
        }

        func setScissorRect(_ rect: Rect) {
            scissor = RenderScissor(
                x: UInt32(max(0, rect.origin.x)), y: UInt32(max(0, rect.origin.y)),
                width: UInt32(max(0, rect.size.width)), height: UInt32(max(0, rect.size.height))
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
                        buffer: try index.buffer.slot.get(), format: index.format,
                        offset: UInt64(index.offset), size: UInt64(index.buffer.length - index.offset)
                    ),
                    vertexBuffers: try state.vertexBindings(),
                    uniforms: try state.uniformBindings(),
                    textures: try state.textureBindings(),
                    samplers: try state.samplerBindings(),
                    depth: target.depth,
                    resolve: target.resolve,
                    additionalColors: target.additionalColors,
                    raster: state.raster,
                    storageBuffers: try state.storageBindings(),
                    colorStore: target.colorStore
                )
            }
            return true
        }

        func drawIndexed(indexCount: Int, indexBufferOffset: Int, instanceCount: Int) {
            drawIndexed(indexCount: indexCount, indexBufferOffset: indexBufferOffset, instanceCount: instanceCount, firstInstance: 0)
        }

        func drawIndexed(indexCount: Int, indexBufferOffset: Int, instanceCount: Int, firstInstance: Int) {
            guard let index, let state = captureState() else { return }
            let draw = IndexedDraw(
                indexCount: UInt32(indexCount),
                firstIndex: UInt32(indexBufferOffset / Int(index.format.byteSize)),
                instances: DrawInstances(count: UInt32(instanceCount), first: UInt32(firstInstance))
            )
            let indexSlot = index.buffer.slot
            let indexBinding = (format: index.format, offset: UInt64(index.offset), length: UInt64(index.buffer.length - index.offset))
            #if SAGA_METAL_NATIVE_PASS
            if let indexedDrawGrouping {
                buffer.recordIndexedDrawGrouping(indexedDrawGrouping)
            }
            #endif
            emit { target in
                .renderIndexed(
                    pipeline: try state.pipeline.slot.get(),
                    target: target.color0,
                    colorLoad: target.colorLoad,
                    indexBuffer: IndexBufferBinding(
                        buffer: try indexSlot.get(), format: indexBinding.format,
                        offset: indexBinding.offset, size: indexBinding.length
                    ),
                    draw: draw,
                    vertexBuffers: try state.vertexBindings(),
                    uniforms: try state.uniformBindings(),
                    textures: try state.textureBindings(),
                    samplers: try state.samplerBindings(),
                    depth: target.depth,
                    resolve: target.resolve,
                    additionalColors: target.additionalColors,
                    raster: state.raster,
                    storageBuffers: try state.storageBindings(),
                    colorStore: target.colorStore
                )
            }
        }

        func draw(type _: IndexPrimitive, vertexStart: Int, vertexCount: Int, instanceCount: Int) {
            guard let state = captureState() else { return }
            emit { target in
                .render(
                    pipeline: try state.pipeline.slot.get(),
                    target: target.color0,
                    colorLoad: target.colorLoad,
                    vertexCount: UInt32(vertexCount),
                    vertexBuffers: try state.vertexBindings(),
                    firstVertex: UInt32(vertexStart),
                    instances: DrawInstances(count: UInt32(instanceCount)),
                    uniforms: try state.uniformBindings(),
                    textures: try state.textureBindings(),
                    samplers: try state.samplerBindings(),
                    depth: target.depth,
                    resolve: target.resolve,
                    additionalColors: target.additionalColors,
                    raster: state.raster,
                    storageBuffers: try state.storageBindings(),
                    colorStore: target.colorStore
                )
            }
        }

        func endRenderPass() {
            guard !drewInPass, !colors.isEmpty || depth != nil else { return }
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
        private struct DrawState: @unchecked Sendable {
            let pipeline: SAGARenderPipeline
            let vertex: [(slot: UInt32, buffer: ResourceSlot<ResourceID>, offset: UInt64)]
            let uniforms: [(ComputeBindingSlot, ResourceSlot<ResourceID>, UInt64, UInt64)]
            let textures: [(ComputeBindingSlot, ResourceSlot<ResourceID>)]
            let accelerationStructures: [(ComputeBindingSlot, ResourceSlot<ResourceID>)]
            let samplers: [(ComputeBindingSlot, ResourceSlot<ResourceID>)]
            let raster: RenderRasterState
            let retained: [AnyObject]

            func vertexBindings() throws -> [VertexBufferBinding] {
                try vertex.map { VertexBufferBinding(buffer: try $0.buffer.get(), offset: $0.offset, slot: $0.slot) }
            }

            func uniformBindings() throws -> [ComputeBindingSlot: ComputeBufferBinding] {
                var result: [ComputeBindingSlot: ComputeBufferBinding] = [:]
                for (slot, buffer, offset, size) in uniforms where pipeline.uniformSlots.contains(slot) {
                    result[slot] = ComputeBufferBinding(buffer: try buffer.get(), offset: offset, size: size)
                }
                return result
            }

            func storageBindings() throws -> [ComputeBindingSlot: ComputeBufferBinding] {
                var result: [ComputeBindingSlot: ComputeBufferBinding] = [:]
                for (slot, buffer, offset, size) in uniforms where pipeline.storageSlots.contains(slot) {
                    result[slot] = ComputeBufferBinding(buffer: try buffer.get(), offset: offset, size: size)
                }
                return result
            }

            func textureBindings() throws -> [ComputeBindingSlot: ResourceID] {
                var result: [ComputeBindingSlot: ResourceID] = [:]
                for (slot, texture) in textures where pipeline.textureSlots.contains(slot) {
                    result[slot] = try texture.get()
                }
                // A render command binds acceleration structures through its texture map, by pipeline slot.
                for (slot, structure) in accelerationStructures where pipeline.accelerationStructureSlots.contains(slot) {
                    result[slot] = try structure.get()
                }
                return result
            }

            func samplerBindings() throws -> [ComputeBindingSlot: ResourceID] {
                var result: [ComputeBindingSlot: ResourceID] = [:]
                for (slot, sampler) in samplers where pipeline.samplerSlots.contains(slot) {
                    result[slot] = try sampler.get()
                }
                return result
            }
        }

        private func captureState() -> DrawState? {
            guard let pipeline else { return nil }
            var retained: [AnyObject] = []
            var vertex: [(slot: UInt32, buffer: ResourceSlot<ResourceID>, offset: UInt64)] = []
            for (engineSlot, gpuSlot) in pipeline.vertexBufferSlots.sorted(by: { $0.value < $1.value }) {
                guard let bound = vertexBuffers[engineSlot] else { continue }
                vertex.append((gpuSlot, bound.buffer.slot, UInt64(bound.offset)))
                retained.append(bound.buffer)
            }
            let uniformList = uniforms.map { slot, bound -> (ComputeBindingSlot, ResourceSlot<ResourceID>, UInt64, UInt64) in
                retained.append(bound.buffer)
                return (slot, bound.buffer.slot, UInt64(bound.offset), UInt64(bound.size))
            }
            let textureList = textures.map { slot, texture -> (ComputeBindingSlot, ResourceSlot<ResourceID>) in
                retained.append(texture)
                return (slot, texture.sampledSlot)
            }
            let accelerationList = accelerationStructures.map { slot, structure -> (ComputeBindingSlot, ResourceSlot<ResourceID>) in
                retained.append(structure)
                return (slot, structure.slot)
            }
            let samplerList = samplers.map { slot, sampler -> (ComputeBindingSlot, ResourceSlot<ResourceID>) in
                retained.append(sampler)
                return (slot, sampler.slot)
            }
            retained.append(pipeline)
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
                print("[SAGA] pipeline '\(pipeline.descriptor.debugName)' vertex attrs=\(attrs) layouts=\(layouts) mapped=\(pipeline.vertexBufferSlots) boundEngineSlots=\(vertexBuffers.keys.sorted()) shaderInputs=\(pipeline.vertexInputLocations)")
                print("[SAGA] pipeline '\(pipeline.descriptor.debugName)' declares uniforms=\(names(pipeline.uniformSlots)) textures=\(names(pipeline.textureSlots)) samplers=\(names(pipeline.samplerSlots)); unbound uniforms=\(names(missingBuffers)) textures=\(names(missingTextures)) samplers=\(names(missingSamplers))")
            }
            return DrawState(
                pipeline: pipeline,
                vertex: vertex,
                uniforms: uniformList,
                textures: textureList,
                accelerationStructures: accelerationList,
                samplers: samplerList,
                raster: drawRaster,
                retained: retained
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
            source: Texture, sourceOrigin: Origin3D, sourceSize: Size3D, sourceMipLevel: Int, sourceSlice: Int,
            destination: Texture, destinationOrigin: Origin3D, destinationMipLevel: Int, destinationSlice: Int
        ) {
            guard let from = source.gpuTexture as? SAGAGPUTexture, let to = destination.gpuTexture as? SAGAGPUTexture else { return }
            let region = TextureCopyRegion(
                x: UInt32(sourceOrigin.x), y: UInt32(sourceOrigin.y),
                width: UInt32(sourceSize.width), height: UInt32(sourceSize.height),
                mipLevel: UInt32(sourceMipLevel), arrayLayer: UInt32(sourceSlice)
            )
            let origin = TextureCopyOrigin(
                x: UInt32(destinationOrigin.x), y: UInt32(destinationOrigin.y),
                mipLevel: UInt32(destinationMipLevel), arrayLayer: UInt32(destinationSlice)
            )
            let (src, dst) = (from.slot, to.slot)
            buffer.append {
                .copyTextureToTexture(source: try src.get(), destination: try dst.get(), sourceRegion: region, destinationOrigin: origin)
            }
        }

        func copyBufferToBuffer(source: Buffer, sourceOffset: Int, destination: Buffer, destinationOffset: Int, size: Int) {
            guard let from = source as? SAGABuffer, let to = destination as? SAGABuffer else { return }
            to.excludeFromShadowCache()
            let (src, dst) = (from.slot, to.slot)
            buffer.append {
                .copy(
                    source: try src.get(), sourceOffset: UInt64(sourceOffset),
                    destination: try dst.get(), destinationOffset: UInt64(destinationOffset), byteCount: UInt64(size)
                )
            }
        }

        func copyBufferToTexture(
            source: Buffer, sourceOffset: Int, sourceBytesPerRow: Int, sourceBytesPerImage: Int, sourceSize: Size3D,
            destination: Texture, destinationOrigin: Origin3D, destinationMipLevel: Int, destinationSlice: Int
        ) {
            guard let from = source as? SAGABuffer, let to = destination.gpuTexture as? SAGAGPUTexture else { return }
            let layout = TextureBufferLayout(
                offset: UInt64(sourceOffset), bytesPerRow: UInt32(sourceBytesPerRow),
                rowsPerImage: sourceBytesPerRow > 0 ? UInt32(sourceBytesPerImage / sourceBytesPerRow) : nil
            )
            let region = TextureCopyRegion(
                x: UInt32(destinationOrigin.x), y: UInt32(destinationOrigin.y),
                width: UInt32(sourceSize.width), height: UInt32(sourceSize.height),
                mipLevel: UInt32(destinationMipLevel), arrayLayer: UInt32(destinationSlice)
            )
            let (src, dst) = (from.slot, to.slot)
            buffer.append {
                .copyBufferToTexture(source: try src.get(), layout: layout, destination: try dst.get(), region: region)
            }
        }

        func copyTextureToBuffer(
            source: Texture, sourceOrigin: Origin3D, sourceMipLevel: Int, sourceSlice: Int, sourceSize: Size3D,
            destination: Buffer, destinationOffset: Int, destinationBytesPerRow: Int, destinationBytesPerImage: Int
        ) {
            guard let from = source.gpuTexture as? SAGAGPUTexture, let to = destination as? SAGABuffer else { return }
            to.excludeFromShadowCache()
            let layout = TextureBufferLayout(
                offset: UInt64(destinationOffset), bytesPerRow: UInt32(destinationBytesPerRow),
                rowsPerImage: destinationBytesPerRow > 0 ? UInt32(destinationBytesPerImage / destinationBytesPerRow) : nil
            )
            let region = TextureCopyRegion(
                x: UInt32(sourceOrigin.x), y: UInt32(sourceOrigin.y),
                width: UInt32(sourceSize.width), height: UInt32(sourceSize.height),
                mipLevel: UInt32(sourceMipLevel), arrayLayer: UInt32(sourceSlice)
            )
            let (src, dst) = (from.slot, to.slot)
            buffer.append {
                .copyTextureRegionToBuffer(source: try src.get(), destination: try dst.get(), layout: layout, region: region)
            }
        }

        func endBlitPass() {}
    }
#endif
