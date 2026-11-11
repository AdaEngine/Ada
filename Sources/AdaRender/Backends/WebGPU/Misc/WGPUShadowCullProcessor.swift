#if WEBGPU_ENABLED && canImport(WebGPU)
    import Foundation
    import Math
    import Synchronization
    @unsafe @preconcurrency import WebGPU

    #if WASM
        private typealias ShadowCullBinding = WebGPU.GPUBindGroupEntryEx
    #else
        private typealias ShadowCullBinding = WebGPU.GPUBindGroupEntry
    #endif

    /// One render node and camera own this state. The lock protects its frame ring; GPU calls use the device lock.
    final class WGPUShadowCullProcessor: GPUShadowCullProcessor, @unchecked Sendable {
        private struct Params {
            var casterCount: UInt32
            var viewCount: UInt32
            var partCount: UInt32
            var strideWords: UInt32
            var copiedWords: UInt32
            var distanceFadeWord: UInt32
            var padding1: UInt32 = 0
            var padding2: UInt32 = 0
        }
        private struct Frame {
            var casters: WebGPU.GPUBuffer
            var casterBytes: Int
            var views: WebGPU.GPUBuffer
            var viewBytes: Int
            var segments: WebGPU.GPUBuffer
            var segmentBytes: Int
            var input: WebGPU.GPUBuffer
            var inputBytes: Int
            var output: WGPUBuffer
            var arguments: WGPUBuffer
            var params: WebGPU.GPUBuffer
            var group: WebGPU.GPUBindGroup
            /// Revision of the input last uploaded into this frame's buffers.
            var revision: UInt64?
        }
        // Immutable vendor handles created under webGPUDeviceLock and only used under it afterwards.
        private struct Pipeline: @unchecked Sendable {
            let layout: WebGPU.GPUBindGroupLayout
            let pipeline: WebGPU.GPUComputePipeline
        }
        /// Baseline WebGPU `maxStorageBufferBindingSize`.
        private static let bindingLimit = 128 * 1_024 * 1_024
        private let lock = NSLock()
        private let context: WGPUContext
        private let layout: WebGPU.GPUBindGroupLayout
        private let pipeline: WebGPU.GPUComputePipeline
        private var frames: [Frame?]
        private var frame = 0

        init(context: WGPUContext) {
            self.context = context
            let device = context.device
            let created = webGPUDeviceLock.withLock { _ in
                let layout = device.createBindGroupLayout(descriptor: .init(entries: [
                    .init(binding: 0, visibility: .compute, buffer: .init(type: .readOnlyStorage)),
                    .init(binding: 1, visibility: .compute, buffer: .init(type: .readOnlyStorage)),
                    .init(binding: 2, visibility: .compute, buffer: .init(type: .readOnlyStorage)),
                    .init(binding: 3, visibility: .compute, buffer: .init(type: .readOnlyStorage)),
                    .init(binding: 4, visibility: .compute, buffer: .init(type: .storage)),
                    .init(binding: 5, visibility: .compute, buffer: .init(type: .storage)),
                    .init(binding: 6, visibility: .compute, buffer: .init(type: .uniform)),
                ]))
                #if WASM
                    let shader = device.createShaderModule(descriptor: .init(label: "Shadow cull", code: WGPUShadowCullShaders.cull))
                #else
                    let shader = device.createShaderModule(descriptor: .init(
                        label: "Shadow cull", nextInChain: WebGPU.GPUShaderSourceWGSL(code: WGPUShadowCullShaders.cull)
                    ))
                #endif
                let pipelineLayout = device.createPipelineLayout(descriptor: .init(bindGroupLayouts: [layout]))
                let pipeline = device.createComputePipeline(descriptor: .init(
                    label: "Shadow cull", layout: pipelineLayout, compute: .init(module: shader, entryPoint: "main")
                ))
                return Pipeline(layout: layout, pipeline: pipeline)
            }
            layout = created.layout
            pipeline = created.pipeline
            frames = Array(repeating: nil, count: max(1, unsafe RenderEngine.configurations.maxFramesInFlight))
        }

        func encode(on command: any CommandBuffer, input: GPUShadowCullInput, views: [GPUShadowCullView], firstInstance: Bool) -> GPUShadowCullOutput? {
            guard let command = command as? WGPUCommandEncoder, !views.isEmpty, input.isValid else { return nil }
            let outputBytes = views.count * input.casters.count * input.instanceStride
            let argumentBytes = views.count * input.parts.count * MemoryLayout<IndexedIndirectArguments>.stride
            guard outputBytes <= Self.bindingLimit, argumentBytes <= Self.bindingLimit, input.instances.count <= Self.bindingLimit,
                views.count * input.casters.count <= Int(UInt32.max)
            else { return nil }
            return lock.withLock {
                webGPUDeviceLock.withLock { _ in
                    encodeLocked(command, input: input, views: views, firstInstance: firstInstance, outputBytes: outputBytes, argumentBytes: argumentBytes)
                }
            }
        }

        private func encodeLocked(
            _ command: WGPUCommandEncoder,
            input: GPUShadowCullInput,
            views: [GPUShadowCullView],
            firstInstance: Bool,
            outputBytes: Int,
            argumentBytes: Int
        ) -> GPUShadowCullOutput? {
            frame = (frame + 1) % frames.count
            let casterBytes = input.casters.count * MemoryLayout<GPUShadowCaster>.stride
            let viewBytes = views.count * MemoryLayout<GPUShadowCullView>.stride
            let segmentBytes = input.segments.count * MemoryLayout<UInt32>.stride
            if let current = frames[frame], current.casterBytes >= casterBytes, current.viewBytes >= viewBytes,
                current.segmentBytes >= segmentBytes, current.inputBytes >= input.instances.count,
                current.output.length >= outputBytes, current.arguments.length >= argumentBytes {
                // Reuse.
            } else {
                frames[frame] = makeFrame(
                    casterBytes: casterBytes, viewBytes: viewBytes, segmentBytes: segmentBytes,
                    inputBytes: input.instances.count, outputBytes: outputBytes, argumentBytes: argumentBytes
                )
            }
            guard var buffers = frames[frame] else { return nil }
            if buffers.revision != input.revision {
                write(input.casters, to: buffers.casters)
                write(input.segments, to: buffers.segments)
                write(input.instances, to: buffers.input)
                buffers.revision = input.revision
                frames[frame] = buffers
            }
            write(views, to: buffers.views)
            var arguments: [IndexedIndirectArguments] = []
            arguments.reserveCapacity(views.count * input.parts.count)
            for view in views.indices {
                for part in input.parts.indices {
                    let start = view * input.casters.count + Int(input.segments[part])
                    arguments.append(IndexedIndirectArguments(
                        indexCount: input.parts[part].indexCount,
                        instanceCount: 0,
                        firstIndex: input.parts[part].firstIndex,
                        baseVertex: input.parts[part].baseVertex,
                        firstInstance: firstInstance ? UInt32(start) : 0
                    ))
                }
            }
            write(arguments, to: buffers.arguments.buffer)
            var params = Params(
                casterCount: UInt32(input.casters.count),
                viewCount: UInt32(views.count),
                partCount: UInt32(input.parts.count),
                strideWords: UInt32(input.instanceStride / 4),
                copiedWords: UInt32(input.copiedBytes / 4),
                distanceFadeWord: input.distanceFadeOffset.map { UInt32($0 / 4) } ?? UInt32.max
            )
            unsafe withUnsafeBytes(of: &params) { bytes in
                unsafe context.device.queue.writeBuffer(buffer: buffers.params, bufferOffset: 0, data: bytes)
            }
            let groups = (views.count * input.casters.count + 63) / 64
            let columns = min(groups, 65_535)
            let pass = command.commandEncoder.beginComputePass(descriptor: nil as WebGPU.GPUComputePassDescriptor?)
            pass.setPipeline(pipeline: pipeline)
            pass.setBindGroup(groupIndex: 0, group: buffers.group, dynamicOffsets: [])
            pass.dispatchWorkgroups(workgroupCountX: UInt32(columns), workgroupCountY: UInt32((groups + columns - 1) / columns), workgroupCountZ: 1)
            pass.end()
            return GPUShadowCullOutput(
                instances: buffers.output,
                arguments: buffers.arguments,
                viewCount: views.count,
                partCount: input.parts.count,
                casterCount: input.casters.count,
                instanceStride: input.instanceStride
            )
        }

        private func makeFrame(casterBytes: Int, viewBytes: Int, segmentBytes: Int, inputBytes: Int, outputBytes: Int, argumentBytes: Int) -> Frame? {
            let device = context.device
            // Grow geometrically so a slowly growing scene does not reallocate every frame.
            func size(_ bytes: Int) -> Int { max(256, (bytes + bytes / 2 + 255) & ~255) }
            let casterSize = size(casterBytes), viewSize = size(viewBytes), segmentSize = size(segmentBytes)
            let inputSize = size(inputBytes), outputSize = min(size(outputBytes), Self.bindingLimit), argumentSize = min(size(argumentBytes), Self.bindingLimit)
            let casters: WebGPU.GPUBuffer? = device.createBuffer(descriptor: .init(usage: [.storage, .copyDst], size: UInt64(casterSize)))
            let views: WebGPU.GPUBuffer? = device.createBuffer(descriptor: .init(usage: [.storage, .copyDst], size: UInt64(viewSize)))
            let segments: WebGPU.GPUBuffer? = device.createBuffer(descriptor: .init(usage: [.storage, .copyDst], size: UInt64(segmentSize)))
            let input: WebGPU.GPUBuffer? = device.createBuffer(descriptor: .init(usage: [.storage, .copyDst], size: UInt64(inputSize)))
            let output: WebGPU.GPUBuffer? = device.createBuffer(descriptor: .init(usage: [.storage, .vertex, .copySrc], size: UInt64(outputSize)))
            let arguments: WebGPU.GPUBuffer? = device.createBuffer(descriptor: .init(
                usage: [.storage, .indirect, .copyDst, .copySrc], size: UInt64(argumentSize)
            ))
            let params: WebGPU.GPUBuffer? = device.createBuffer(descriptor: .init(
                usage: [.uniform, .copyDst], size: UInt64(MemoryLayout<Params>.stride)
            ))
            guard let casters, let views, let segments, let input, let output, let arguments, let params else { return nil }
            let entries: [ShadowCullBinding] = [
                .init(binding: 0, buffer: casters, size: UInt64(casterSize)),
                .init(binding: 1, buffer: views, size: UInt64(viewSize)),
                .init(binding: 2, buffer: segments, size: UInt64(segmentSize)),
                .init(binding: 3, buffer: input, size: UInt64(inputSize)),
                .init(binding: 4, buffer: output, size: UInt64(outputSize)),
                .init(binding: 5, buffer: arguments, size: UInt64(argumentSize)),
                .init(binding: 6, buffer: params, size: UInt64(MemoryLayout<Params>.stride)),
            ]
            #if WASM
                let group = device.createBindGroup(layout: layout, entries: entries)
            #else
                let group = device.createBindGroup(descriptor: .init(layout: layout, entries: entries))
            #endif
            return Frame(
                casters: casters, casterBytes: casterSize,
                views: views, viewBytes: viewSize,
                segments: segments, segmentBytes: segmentSize,
                input: input, inputBytes: inputSize,
                output: WGPUBuffer(buffer: output, device: device, instance: context.instance),
                arguments: WGPUBuffer(buffer: arguments, device: device, instance: context.instance),
                params: params,
                group: group,
                revision: nil
            )
        }

        private func write<T>(_ values: [T], to buffer: WebGPU.GPUBuffer) {
            unsafe values.withUnsafeBytes { bytes in
                unsafe context.device.queue.writeBuffer(buffer: buffer, bufferOffset: 0, data: bytes)
            }
        }
    }
#endif
