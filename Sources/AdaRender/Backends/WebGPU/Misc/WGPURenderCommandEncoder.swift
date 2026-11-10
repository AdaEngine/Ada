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
        private var currentIndexOwner: WGPUIndexBuffer?
        private var currentIndexOffset: UInt64 = 0
        private var currentIndexSize: UInt64 = 0
        private var currentPipeline: WGPURenderPipeline?
        private var genericBuffers: [Int: (buffer: WGPUBuffer, offset: UInt64, size: UInt64)] = [:]
        private var vertexBuffers: [Int: (buffer: WGPUBuffer, offset: UInt64, size: UInt64)] = [:]

        private var device: WebGPU.GPUDevice

        // Track if bind group needs update
        private var bindGroupDirty: Bool = false
        // One bit per descriptor set whose bind group must be re-bound before the next draw.
        private var dirtyBindGroupSets: UInt64 = 0
        private var triangleFillMode: TriangleFillMode = .fill
        private var lastScissorRect: Rect?

        struct BindGroupResources {
            var uniformBuffers: [Int: (buffer: WGPUBuffer, offset: Int, size: UInt64, cacheable: Bool)] = [:]
            var textures: [Int: WGPUGPUTexture] = [:]
            var samplers: [Int: WGPUSampler] = [:]

            mutating func setUniform(_ buffer: WGPUBuffer, offset: Int, size: UInt64, slot: Int, cacheable: Bool = true) -> Bool {
                if let current = uniformBuffers[slot], current.buffer === buffer, current.offset == offset,
                    current.size == size, current.cacheable == cacheable { return false }
                uniformBuffers[slot] = (buffer, offset, size, cacheable)
                return true
            }

            mutating func setTexture(_ texture: WGPUGPUTexture, slot: Int) -> Bool {
                guard textures[slot] !== texture else { return false }
                textures[slot] = texture
                return true
            }

            mutating func setSampler(_ sampler: WGPUSampler, slot: Int) -> Bool {
                guard samplers[slot] !== sampler else { return false }
                samplers[slot] = sampler
                return true
            }
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
                    resources.setUniform(binding.buffer, offset: Int(binding.offset), size: binding.size, slot: slot)
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
                let count = min(wgpuPipeline.bindingKinds.count, UInt64.bitWidth)
                dirtyBindGroupSets = count == UInt64.bitWidth ? .max : (1 << UInt64(count)) - 1
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
                resources.setUniform(wgpuBuffer, offset: offset, size: UInt64(wgpuBuffer.length - offset), slot: slot)
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
                resources.setUniform(wgpuBuffer, offset: offset, size: UInt64(wgpuBuffer.length - offset), slot: slot)
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
                    resources.setUniform(binding.buffer, offset: offset, size: binding.size, slot: slot)
                }
            }
            bindVertexBuffer(wgpuBuffer, offset: offset, engineSlot: slot)
        }

        private func bindVertexBuffer(_ buffer: WGPUBuffer, offset: Int, engineSlot: Int) {
            let size = UInt64(buffer.length - offset)
            if let current = vertexBuffers[engineSlot], current.buffer === buffer, current.offset == UInt64(offset), current.size == size { return }
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
                resources.setUniform(wgpuBuffer, offset: offset, size: UInt64(wgpuBuffer.length - offset), slot: slot)
            }
        }

        func setIndexBuffer<T>(_ bufferData: BufferData<T>, indexFormat: IndexBufferFormat) {
            guard let wgpuBuffer = bufferData.buffer as? WGPUBuffer else {
                fatalError("BufferData is not a WGPUBuffer")
            }
            currentIndexBuffer = wgpuBuffer.buffer
            currentIndexType = indexFormat == .uInt32 ? .uint32 : .uint16
            currentIndexOwner = nil
            currentIndexOffset = 0
            currentIndexSize = UInt64(wgpuBuffer.length)
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
                // Inline bytes have a fresh identity on every call. Keeping their
                // bind groups in the pipeline cache retains one-use allocations
                // and displaces the reusable material/texture working set.
                resources.setUniform(WGPUBuffer(buffer: buffer, device: device), offset: 0, size: UInt64(length), slot: slot, cacheable: false)
            }
        }

        func setFragmentTexture(_ texture: Texture, slot: Int) {
            guard let wgpuTexture = texture.gpuTexture as? WGPUGPUTexture else {
                fatalError("Texture's gpuTexture is not a WGPUGPUTexture")
            }
            updateBindGroupResources(setIndex: 0) { resources in
                resources.setTexture(wgpuTexture, slot: slot)
            }
        }

        func setFragmentSamplerState(_ sampler: Sampler, slot: Int) {
            guard let wgpuSampler = sampler as? WGPUSampler else {
                fatalError("Sampler is not a WGPUSampler")
            }
            updateBindGroupResources(setIndex: 0) { resources in
                resources.setSampler(wgpuSampler, slot: slot)
            }
        }

        func setResourceSet(_ resourceSet: RenderResourceSet, index: Int) {
            updateBindGroupResources(setIndex: index) { resources in
                var changed = false
                for binding in resourceSet.bindings {
                    switch binding.resource {
                    case let .uniformBuffer(uniformBuffer, offset):
                        guard let wgpuBuffer = uniformBuffer as? WGPUUniformBuffer else {
                            fatalError("UniformBuffer is not a WGPUUniformBuffer")
                        }
                        if resources.setUniform(wgpuBuffer, offset: offset, size: UInt64(wgpuBuffer.length - offset), slot: binding.binding) { changed = true }
                    case .texture(let texture):
                        guard let wgpuTexture = texture.gpuTexture as? WGPUGPUTexture else {
                            fatalError("Texture's gpuTexture is not a WGPUGPUTexture")
                        }
                        if resources.setTexture(wgpuTexture, slot: binding.binding) { changed = true }
                    case .sampler(let sampler):
                        guard let wgpuSampler = sampler as? WGPUSampler else {
                            fatalError("Sampler is not a WGPUSampler")
                        }
                        if resources.setSampler(wgpuSampler, slot: binding.binding) { changed = true }
                    }
                }
                return changed
            }
        }

        private func updateBindGroupResources(setIndex: Int, update: (inout BindGroupResources) -> Bool) {
            guard update(&bindGroupResources[setIndex, default: BindGroupResources()]) else { return }
            bindGroupDirty = true
            assert(setIndex < UInt64.bitWidth, "Descriptor set index exceeds the dirty-set mask")
            dirtyBindGroupSets |= 1 << UInt64(setIndex & (UInt64.bitWidth - 1))
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
            guard lastScissorRect != rect else { return }
            lastScissorRect = rect
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
            let indexType: WebGPU.GPUIndexFormat = (wgpuIndexBuffer.indexFormat == .uInt32) ? .uint32 : .uint16
            let size = UInt64(buffer.length - offset)
            // Consecutive draws of one mesh part share its index buffer; Dawn validates every rebind.
            if currentIndexOwner === wgpuIndexBuffer, currentIndexBuffer != nil, currentIndexType == indexType,
                currentIndexOffset == UInt64(offset), currentIndexSize == size {
                return
            }
            self.currentIndexBuffer = wgpuIndexBuffer.buffer
            self.currentIndexOwner = wgpuIndexBuffer
            self.currentIndexType = indexType
            self.currentIndexOffset = UInt64(offset)
            self.currentIndexSize = size
            renderEncoder.setIndexBuffer(
                buffer: wgpuIndexBuffer.buffer,
                format: currentIndexType,
                offset: UInt64(offset),
                size: UInt64(buffer.length - offset)
            )
        }

        func drawIndexed(indexCount: Int, indexBufferOffset: Int, instanceCount: Int) {
            drawIndexed(indexCount: indexCount, indexBufferOffset: indexBufferOffset, instanceCount: instanceCount, firstInstance: 0)
        }

        func drawIndexed(indexCount: Int, indexBufferOffset: Int, instanceCount: Int, firstInstance: Int) {
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
                firstInstance: UInt32(firstInstance)
            )
        }

        func drawIndexedIndirect(arguments: any Buffer, offset: Int) -> Bool {
            guard let arguments = arguments as? WGPUBuffer, currentIndexBuffer != nil,
                offset >= 0, offset % 4 == 0, arguments.length >= MemoryLayout<IndexedIndirectArguments>.stride,
                offset <= arguments.length - MemoryLayout<IndexedIndirectArguments>.stride
            else { return false }
            if bindGroupDirty { commitBindGroup() }
            #if WASM
                // Swan's browser wrapper does not expose indexed indirect draws yet.
                let object = renderEncoder.jsObject
                guard let draw = object["drawIndexedIndirect"].function else { return false }
                _ = draw.callAsFunction(this: object, arguments.buffer.jsObject, Double(offset))
            #else
                renderEncoder.drawIndexedIndirect(indirectBuffer: arguments.buffer, indirectOffset: UInt64(offset))
            #endif
            return true
        }

        func multiDrawIndexedIndirect(arguments: any Buffer, offset: Int, drawCount: Int) -> Bool {
            #if WASM
                return false
            #else
                let stride = MemoryLayout<IndexedIndirectArguments>.stride
                guard drawCount > 0, let arguments = arguments as? WGPUBuffer, currentIndexBuffer != nil,
                    offset >= 0, offset % 4 == 0, offset + drawCount * stride <= arguments.length,
                    device.hasFeature(feature: .multiDrawIndirect)
                else { return false }
                if bindGroupDirty { commitBindGroup() }
                renderEncoder.multiDrawIndexedIndirect(
                    indirectBuffer: arguments.buffer,
                    indirectOffset: UInt64(offset),
                    maxDrawCount: UInt32(drawCount),
                    drawCountBuffer: nil,
                    drawCountBufferOffset: 0
                )
                return true
            #endif
        }

        func multiDrawIndexedIndirect(arguments: any Buffer, offset: Int, maxDrawCount: Int, drawCountBuffer: any Buffer, drawCountOffset: Int) -> Bool {
            #if WASM
                return false
            #else
                let stride = MemoryLayout<IndexedIndirectArguments>.stride
                guard maxDrawCount > 0, let arguments = arguments as? WGPUBuffer, let counts = drawCountBuffer as? WGPUBuffer,
                    currentIndexBuffer != nil, offset >= 0, offset % 4 == 0, offset + maxDrawCount * stride <= arguments.length,
                    drawCountOffset >= 0, drawCountOffset % 4 == 0, drawCountOffset + 4 <= counts.length,
                    device.hasFeature(feature: .multiDrawIndirect)
                else { return false }
                if bindGroupDirty { commitBindGroup() }
                renderEncoder.multiDrawIndexedIndirect(
                    indirectBuffer: arguments.buffer,
                    indirectOffset: UInt64(offset),
                    maxDrawCount: UInt32(maxDrawCount),
                    drawCountBuffer: counts.buffer,
                    drawCountBufferOffset: UInt64(drawCountOffset)
                )
                return true
            #endif
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

            // Only sets changed since the last draw (or all of them after a pipeline switch) are re-bound;
            // untouched sets keep their bind group in the pass encoder.
            var remainingSets = dirtyBindGroupSets
            dirtyBindGroupSets = 0
            while remainingSets != 0 {
                let setIndex = remainingSets.trailingZeroBitCount
                remainingSets &= remainingSets - 1
                guard pipeline.bindingKinds.indices.contains(setIndex), !pipeline.bindingKinds[setIndex].isEmpty else { continue }
                guard let resources = bindGroupResources[setIndex] else {
                    continue
                }

                let expectedResources = expectedResourceKinds(for: pipeline, setIndex: setIndex)
                var keys: [WGPUBindingKey] = []
                var cacheable = true
                // Inline-byte uniforms and opted-out textures are never cached. Render attachments may be
                // cached briefly (see TransientResourceCache) instead of creating a bind group every draw.
                var transientCacheable = true
                keys.reserveCapacity(expectedResources.count)
                let sortedSlots = pipeline.sortedBindingSlots.indices.contains(setIndex) ? pipeline.sortedBindingSlots[setIndex] : []
                for slot in sortedSlots {
                    switch expectedResources[slot] {
                    case .uniformBuffer:
                        if let uniform = resources.uniformBuffers[slot] {
                            cacheable = cacheable && uniform.cacheable
                            transientCacheable = transientCacheable && uniform.cacheable
                            keys.append(.init(slot: slot, owner: ObjectIdentifier(uniform.buffer), offset: uniform.offset, size: uniform.size))
                        }
                    case .texture:
                        if let texture = resources.textures[slot] {
                            cacheable = cacheable && texture.allowsBindingCache
                            transientCacheable = transientCacheable && texture.allowsTransientBindingCache
                            keys.append(.init(slot: slot, owner: ObjectIdentifier(texture)))
                        }
                    case .sampler:
                        if let sampler = resources.samplers[slot] {
                            keys.append(.init(slot: slot, owner: ObjectIdentifier(sampler)))
                        }
                    case nil: break
                    }
                }
                let key = WGPUBindGroupKey(set: setIndex, bindings: keys)
                // Owners keep ObjectIdentifier keys unique while an entry lives; only collected on insertion.
                let owners = { () -> [AnyObject] in
                    var owners: [AnyObject] = []
                    owners.reserveCapacity(sortedSlots.count)
                    for slot in sortedSlots {
                        switch expectedResources[slot] {
                        case .uniformBuffer: if let uniform = resources.uniformBuffers[slot] { owners.append(uniform.buffer) }
                        case .texture: if let texture = resources.textures[slot] { owners.append(texture) }
                        case .sampler: if let sampler = resources.samplers[slot] { owners.append(sampler) }
                        case nil: break
                        }
                    }
                    return owners
                }
                let bindGroup = pipeline.cachedBindGroup(key: key, owners: owners, cacheable: cacheable, transient: transientCacheable) {
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
