//
//  WGPURenderCommandEncoder.swift
//  AdaEngine
//
//  Created by Vladislav Prusakov on 23.11.2025.
//

#if WEBGPU_ENABLED && canImport(WebGPU)
    #if WASM
        import JavaScriptKit
    #endif
    import Math
    import Synchronization
    @unsafe @preconcurrency import WebGPU

    final class WGPURenderCommandEncoder: RenderCommandEncoder {
        let renderEncoder: WebGPU.GPURenderPassEncoder
        private var currentIndexBuffer: WebGPU.GPUBuffer?
        private var currentIndexType: WebGPU.GPUIndexFormat = .uint32
        private var currentPipeline: WGPURenderPipeline?
        private var genericBuffers: [Int: (buffer: WGPUBuffer, offset: UInt64, size: UInt64)] = [:]
        private var vertexBuffers: [Int: (buffer: WGPUBuffer, offset: UInt64, size: UInt64)] = [:]

        private var device: WebGPU.GPUDevice

        // Track if bind group needs update
        private var bindGroupDirty: Bool = false
        private var triangleFillMode: TriangleFillMode = .fill

        struct BindGroupResources {
            var uniformBuffers: [Int: (buffer: WGPUBuffer, offset: Int, size: UInt64)] = [:]
            var textures: [Int: WGPUGPUTexture] = [:]
            var samplers: [Int: WGPUSampler] = [:]
        }

        private var bindGroupResources: [Int: BindGroupResources] = [:]

        init(
            renderEncoder: WebGPU.GPURenderPassEncoder,
            device: WebGPU.GPUDevice
        ) {
            self.renderEncoder = renderEncoder
            self.device = device
        }

        func pushDebugName(_ string: String) {
            #if !WASM
                renderEncoder.pushDebugGroup(groupLabel: string)
            #endif
        }

        func popDebugName() {
            #if !WASM
                renderEncoder.popDebugGroup()
            #endif
        }

        func setRenderPipelineState(_ pipeline: RenderPipeline) {
            guard let wgpuPipeline = pipeline as? WGPURenderPipeline else {
                fatalError("RenderPipeline is not a WGPURenderPipeline")
            }

            // Save old pipeline before updating
            let oldPipeline = currentPipeline
            let pipelineChanged = oldPipeline !== wgpuPipeline
            guard pipelineChanged else {
                return
            }

            renderEncoder.setPipeline(pipeline: wgpuPipeline.renderPipeline)
            self.currentPipeline = wgpuPipeline

            let expected = expectedResourceKinds(for: wgpuPipeline, setIndex: 0)
            for (slot, binding) in genericBuffers where wgpuPipeline.vertexBufferSlots[slot] == nil && expected[slot] == .uniformBuffer {
                updateBindGroupResources(setIndex: 0) { resources in
                    resources.uniformBuffers[slot] = (binding.buffer, Int(binding.offset), binding.size)
                }
            }

            // Engine bindings persist across pipeline changes, as on Metal. Reflection
            // filters them when building each pipeline's bind group.
            for (engineSlot, gpuSlot) in wgpuPipeline.vertexBufferSlots {
                if let binding = vertexBuffers[engineSlot] {
                    renderEncoder.setVertexBuffer(slot: gpuSlot, buffer: binding.buffer.buffer, offset: binding.offset, size: binding.size)
                }
            }

            // Always mark dirty when pipeline changes so bind group uses correct layout
            if pipelineChanged {
                bindGroupDirty = true
            }

            // NOTE: Do NOT call commitBindGroup() here!
            // Resources (textures, samplers) may be set AFTER the pipeline is set.
            // Bind groups should only be committed right before draw calls.
        }

        func setVertexBuffer(_ buffer: UniformBuffer, offset: Int, slot: Int) {
            guard let wgpuBuffer = buffer as? WGPUUniformBuffer else {
                fatalError("UniformBuffer is not a WGPUUniformBuffer")
            }
            updateBindGroupResources(setIndex: 0) { resources in
                resources.uniformBuffers[slot] = (
                    buffer: wgpuBuffer,
                    offset: offset,
                    size: UInt64(wgpuBuffer.length)
                )
            }
        }

        func setVertexBuffer(_ buffer: VertexBuffer, offset: Int, slot: Int) {
            guard let wgpuBuffer = buffer as? WGPUVertexBuffer else {
                fatalError("VertexBuffer is not a WGPUVertexBuffer")
            }
            bindVertexBuffer(wgpuBuffer, offset: offset, engineSlot: slot)
        }

        func setFragmentBuffer(_ buffer: UniformBuffer, offset: Int, slot: Int) {
            guard let wgpuBuffer = buffer as? WGPUUniformBuffer else {
                fatalError("UniformBuffer is not a WGPUUniformBuffer")
            }
            updateBindGroupResources(setIndex: 0) { resources in
                resources.uniformBuffers[slot] = (
                    buffer: wgpuBuffer,
                    offset: offset,
                    size: UInt64(wgpuBuffer.length)
                )
            }
        }

        func setVertexBuffer<T>(_ bufferData: BufferData<T>, offset: Int, slot: Int) {
            guard let wgpuBuffer = bufferData.buffer as? WGPUBuffer else {
                fatalError("BufferData is not a WGPUBuffer")
            }

            let binding = (buffer: wgpuBuffer, offset: UInt64(offset), size: UInt64(wgpuBuffer.length - offset))
            genericBuffers[slot] = binding
            if let pipeline = currentPipeline, pipeline.vertexBufferSlots[slot] == nil,
                expectedResourceKinds(for: pipeline, setIndex: 0)[slot] == .uniformBuffer {
                updateBindGroupResources(setIndex: 0) { resources in
                    resources.uniformBuffers[slot] = (binding.buffer, offset, binding.size)
                }
            }
            bindVertexBuffer(wgpuBuffer, offset: offset, engineSlot: slot)
        }

        private func bindVertexBuffer(_ buffer: WGPUBuffer, offset: Int, engineSlot: Int) {
            let size = UInt64(buffer.length - offset)
            vertexBuffers[engineSlot] = (buffer, UInt64(offset), size)
            guard let gpuSlot = currentPipeline?.vertexBufferSlots[engineSlot] else {
                return
            }
            renderEncoder.setVertexBuffer(slot: gpuSlot, buffer: buffer.buffer, offset: UInt64(offset), size: size)
        }

        func setFragmentBuffer<T>(_ bufferData: BufferData<T>, offset: Int, slot: Int) {
            guard let wgpuBuffer = bufferData.buffer as? WGPUBuffer else {
                fatalError("BufferData is not a WGPUBuffer")
            }

            updateBindGroupResources(setIndex: 0) { resources in
                resources.uniformBuffers[slot] = (
                    buffer: wgpuBuffer,
                    offset: offset,
                    size: UInt64(wgpuBuffer.length)
                )
            }
        }

        func setIndexBuffer<T>(_ bufferData: BufferData<T>, indexFormat: IndexBufferFormat) {
            guard let wgpuBuffer = bufferData.buffer as? WGPUBuffer else {
                fatalError("BufferData is not a WGPUBuffer")
            }
            currentIndexBuffer = wgpuBuffer.buffer
            currentIndexType = indexFormat == .uInt32 ? .uint32 : .uint16
            renderEncoder.setIndexBuffer(
                buffer: wgpuBuffer.buffer,
                format: currentIndexType,
                offset: 0,
                size: UInt64(wgpuBuffer.length)
            )
        }

        func setVertexBytes(_ bytes: UnsafeRawPointer, length: Int, slot: Int) {
            nonisolated(unsafe) var createdBuffer: WebGPU.GPUBuffer?
            webGPUDeviceLock.withLock { _ in
                createdBuffer = device.createBuffer(
                    descriptor: WebGPU.GPUBufferDescriptor(
                        usage: [.uniform, .copyDst],
                        size: UInt64(length)
                    )
                )
            }
            guard let buffer = createdBuffer else {
                return
            }
            webGPUDeviceLock.withLock { _ in
                unsafe device.queue.writeBuffer(
                    buffer: buffer,
                    bufferOffset: 0,
                    data: UnsafeRawBufferPointer(start: bytes, count: length)
                )
            }
            updateBindGroupResources(setIndex: 0) { resources in
                resources.uniformBuffers[slot] = (
                    buffer: WGPUBuffer(buffer: buffer, device: device),
                    offset: 0,
                    size: UInt64(length)
                )
            }
        }

        func setFragmentTexture(_ texture: Texture, slot: Int) {
            guard let wgpuTexture = texture.gpuTexture as? WGPUGPUTexture else {
                fatalError("Texture's gpuTexture is not a WGPUGPUTexture")
            }
            updateBindGroupResources(setIndex: 0) { resources in
                resources.textures[slot] = wgpuTexture
            }
        }

        func setFragmentSamplerState(_ sampler: Sampler, slot: Int) {
            guard let wgpuSampler = sampler as? WGPUSampler else {
                fatalError("Sampler is not a WGPUSampler")
            }
            updateBindGroupResources(setIndex: 0) { resources in
                resources.samplers[slot] = wgpuSampler
            }
        }

        func setResourceSet(_ resourceSet: RenderResourceSet, index: Int) {
            updateBindGroupResources(setIndex: index) { resources in
                for binding in resourceSet.bindings {
                    switch binding.resource {
                    case let .uniformBuffer(uniformBuffer, offset):
                        guard let wgpuBuffer = uniformBuffer as? WGPUUniformBuffer else {
                            fatalError("UniformBuffer is not a WGPUUniformBuffer")
                        }
                        resources.uniformBuffers[binding.binding] = (
                            buffer: wgpuBuffer,
                            offset: offset,
                            size: UInt64(wgpuBuffer.length)
                        )
                    case .texture(let texture):
                        guard let wgpuTexture = texture.gpuTexture as? WGPUGPUTexture else {
                            fatalError("Texture's gpuTexture is not a WGPUGPUTexture")
                        }
                        resources.textures[binding.binding] = wgpuTexture
                    case .sampler(let sampler):
                        guard let wgpuSampler = sampler as? WGPUSampler else {
                            fatalError("Sampler is not a WGPUSampler")
                        }
                        resources.samplers[binding.binding] = wgpuSampler
                    }
                }
            }
        }

        private func updateBindGroupResources(setIndex: Int, update: (inout BindGroupResources) -> Void) {
            update(&bindGroupResources[setIndex, default: BindGroupResources()])
            bindGroupDirty = true
        }

        func setViewport(_ viewport: Rect) {
            #if WASM
                // Swan's browser wrapper has no setViewport API yet. Atlas tiles
                // still require the same viewport transform as native WebGPU.
                let object = renderEncoder.jsObject
                guard let setViewport = object["setViewport"].function else {
                    assertionFailure("WebGPU render pass is missing setViewport")
                    return
                }
                _ = setViewport.callAsFunction(
                    this: object,
                    Double(viewport.origin.x),
                    Double(viewport.origin.y),
                    Double(viewport.size.width),
                    Double(viewport.size.height),
                    0,
                    1
                )
            #else
                renderEncoder.setViewport(
                    x: Float(viewport.origin.x),
                    y: Float(viewport.origin.y),
                    width: Float(viewport.size.width),
                    height: Float(viewport.size.height),
                    minDepth: 0,
                    maxDepth: 1
                )
            #endif
        }

        func setScissorRect(_ rect: Rect) {
            renderEncoder.setScissorRect(
                x: UInt32(rect.origin.x),
                y: UInt32(rect.origin.y),
                width: UInt32(rect.size.width),
                height: UInt32(rect.size.height)
            )
        }

        func setTriangleFillMode(_: TriangleFillMode) {
        }

        func setIndexBuffer(_ buffer: IndexBuffer, offset: Int) {
            guard let wgpuIndexBuffer = buffer as? WGPUIndexBuffer else {
                fatalError("IndexBuffer is not a WGPUIndexBuffer")
            }
            self.currentIndexBuffer = wgpuIndexBuffer.buffer
            self.currentIndexType = (wgpuIndexBuffer.indexFormat == .uInt32) ? .uint32 : .uint16
            renderEncoder.setIndexBuffer(
                buffer: wgpuIndexBuffer.buffer,
                format: currentIndexType,
                offset: UInt64(offset),
                size: UInt64(buffer.length - offset)
            )
        }

        func drawIndexed(indexCount: Int, indexBufferOffset: Int, instanceCount: Int) {
            guard currentIndexBuffer != nil else {
                fatalError("Index buffer is not set. Call setIndexBuffer(_:offset:) before drawIndexed().")
            }

            // Ensure bind groups are committed before drawing
            if bindGroupDirty {
                commitBindGroup()
            }

            renderEncoder.drawIndexed(
                indexCount: UInt32(indexCount),
                instanceCount: UInt32(instanceCount),
                firstIndex: UInt32(indexBufferOffset / (currentIndexType == .uint32 ? 4 : 2)),
                baseVertex: 0,
                firstInstance: 0
            )
        }

        func draw(type _: IndexPrimitive, vertexStart: Int, vertexCount: Int, instanceCount: Int) {
            // Ensure bind groups are committed before drawing
            if bindGroupDirty {
                commitBindGroup()
            }

            renderEncoder.draw(
                vertexCount: UInt32(vertexCount),
                instanceCount: UInt32(instanceCount),
                firstVertex: UInt32(vertexStart),
                firstInstance: 0
            )
        }

        func endRenderPass() {
            renderEncoder.end()
        }
    }

    extension WGPURenderCommandEncoder {
        private func commitBindGroup() {
            guard let pipeline = currentPipeline else {
                // Pipeline not set yet, will commit when it's set
                return
            }

            bindGroupDirty = false

            for setIndex in bindGroupResources.keys.sorted() {
                guard let resources = bindGroupResources[setIndex] else {
                    continue
                }

                let expectedResources = expectedResourceKinds(for: pipeline, setIndex: setIndex)
                var keys: [WGPUBindingKey] = []
                var owners: [AnyObject] = []
                keys.reserveCapacity(expectedResources.count)
                owners.reserveCapacity(expectedResources.count)
                for slot in expectedResources.keys.sorted() {
                    switch expectedResources[slot] {
                    case .uniformBuffer:
                        if let uniform = resources.uniformBuffers[slot] {
                            keys.append(.init(slot: slot, owner: ObjectIdentifier(uniform.buffer), offset: uniform.offset, size: uniform.size))
                            owners.append(uniform.buffer)
                        }
                    case .texture:
                        if let texture = resources.textures[slot] {
                            keys.append(.init(slot: slot, owner: ObjectIdentifier(texture)))
                            owners.append(texture)
                        }
                    case .sampler:
                        if let sampler = resources.samplers[slot] {
                            keys.append(.init(slot: slot, owner: ObjectIdentifier(sampler)))
                            owners.append(sampler)
                        }
                    case nil: break
                    }
                }
                let key = WGPUBindGroupKey(set: setIndex, bindings: keys)
                let bindGroup = pipeline.cachedBindGroup(key: key, owners: owners) {
                    #if WASM
                        var entries: [WebGPU.GPUBindGroupEntryEx] = []
                    #else
                        var entries: [WebGPU.GPUBindGroupEntry] = []
                    #endif
                    for (bindingSlot, texture) in resources.textures
                    where shouldBind(
                        bindingSlot,
                        as: .texture,
                        expectedResources: expectedResources
                    ) {
                        #if WASM
                            entries.append(
                                WebGPU.GPUBindGroupEntryEx(
                                    binding: bindingSlot,
                                    textureView: texture.textureView
                                )
                            )
                        #else
                            entries.append(
                                WebGPU.GPUBindGroupEntry(
                                    binding: UInt32(bindingSlot),
                                    textureView: texture.textureView
                                )
                            )
                        #endif
                    }

                    for (bindingSlot, sampler) in resources.samplers
                    where shouldBind(
                        bindingSlot,
                        as: .sampler,
                        expectedResources: expectedResources
                    ) {
                        #if WASM
                            entries.append(
                                WebGPU.GPUBindGroupEntryEx(
                                    binding: bindingSlot,
                                    sampler: sampler.wgpuSampler
                                )
                            )
                        #else
                            entries.append(
                                WebGPU.GPUBindGroupEntry(
                                    binding: UInt32(bindingSlot),
                                    sampler: sampler.wgpuSampler
                                )
                            )
                        #endif
                    }

                    for (bindingSlot, uniform) in resources.uniformBuffers
                    where shouldBind(
                        bindingSlot,
                        as: .uniformBuffer,
                        expectedResources: expectedResources
                    ) {
                        #if WASM
                            entries.append(
                                WebGPU.GPUBindGroupEntryEx(
                                    binding: bindingSlot,
                                    buffer: uniform.buffer.buffer,
                                    offset: UInt64(uniform.offset),
                                    size: uniform.size
                                )
                            )
                        #else
                            entries.append(
                                WebGPU.GPUBindGroupEntry(
                                    binding: UInt32(bindingSlot),
                                    buffer: uniform.buffer.buffer,
                                    offset: UInt64(uniform.offset),
                                    size: uniform.size
                                )
                            )
                        #endif
                    }

                    guard !entries.isEmpty else {
                        return nil
                    }

                    // Get bind group layout - this will fail if the pipeline is invalid
                    // The layout will be null/invalid if the pipeline creation failed
                    #if WASM
                        let layout = pipeline.renderPipeline.getBindGroupLayout(index: UInt32(setIndex))
                    #else
                        guard let layout = pipeline.renderPipeline.getBindGroupLayout(groupIndex: UInt32(setIndex)) else {
                            return nil
                        }
                    #endif
                    return webGPUDeviceLock.withLock { _ in
                        #if WASM
                            device.createBindGroup(
                                label: pipeline.descriptor.debugName + " Bind Group \(setIndex)",
                                layout: layout,
                                entries: entries
                            )
                        #else
                            device.createBindGroup(
                                descriptor: WebGPU.GPUBindGroupDescriptor(
                                    label: pipeline.descriptor.debugName + " Bind Group \(setIndex)",
                                    layout: layout,
                                    entries: entries
                                )
                            )
                        #endif
                    }
                }
                renderEncoder.setBindGroup(
                    groupIndex: UInt32(setIndex),
                    group: bindGroup,
                    dynamicOffsets: []
                )
            }
        }

        private func expectedResourceKinds(
            for pipeline: WGPURenderPipeline,
            setIndex: Int
        ) -> [Int: WGPUBindingKind] {
            pipeline.bindingKinds.indices.contains(setIndex) ? pipeline.bindingKinds[setIndex] : [:]
        }

        private func shouldBind(
            _ binding: Int,
            as kind: WGPUBindingKind,
            expectedResources: [Int: WGPUBindingKind]
        ) -> Bool {
            guard let expectedKind = expectedResources[binding] else {
                return expectedResources.isEmpty
            }
            return expectedKind == kind
        }
    }

#endif
