#if WEBGPU_ENABLED && canImport(WebGPU) && !WASM
    import Foundation
    import Math
    import Synchronization
    @unsafe @preconcurrency import WebGPU

    enum WGPUShadowClusterCullShaders {
        /// Consecutive visible clusters merged into one draw, at most. Clusters tile their part's index range
        /// in order, so a run of them is one contiguous index range. Merging keeps the number of indirect draws
        /// small: Dawn's D3D12 multi-draw stops the queue with tens of thousands of draws per call.
        static let maximumRun: UInt32 = 1024

        /// `classify`: one thread per (view, cluster) writes its visibility, with the test of `WGPUShadowCullShaders.cull`.
        /// `emit`: a visible cluster that starts a run (its part's first cluster, after an invisible one, or at a
        /// multiple of `maximumRun`) writes one draw covering the run, compacted per (view, part) with a counter.
        static let cull = """
            struct Cluster { minimum: vec4f, maximum: vec4f, firstIndex: u32, indexCount: u32, part: u32, instance: u32 }
            struct View {
                planes: array<vec4f, 6>, culls: u32, pad0: u32, pad1: u32, pad2: u32,
                distanceCamera: vec4f,
            }
            struct Params { clusterCount: u32, viewCount: u32, partCount: u32, pad0: u32 }
            struct Draw { indexCount: u32, instanceCount: u32, firstIndex: u32, baseVertex: i32, firstInstance: u32 }
            const maximumRun = \(maximumRun)u;
            @group(0) @binding(0) var<storage, read> clusters: array<Cluster>;
            @group(0) @binding(1) var<storage, read> views: array<View>;
            @group(0) @binding(2) var<storage, read> segments: array<u32>;
            @group(0) @binding(3) var<storage, read_write> draws: array<Draw>;
            @group(0) @binding(4) var<storage, read_write> counts: array<atomic<u32>>;
            @group(0) @binding(5) var<uniform> params: Params;
            @group(0) @binding(6) var<storage, read_write> visibility: array<u32>;
            fn finite(v: vec4f) -> bool {
                return all((bitcast<vec4u>(v) & vec4u(0x7fffffffu)) < vec4u(0x7f800000u));
            }
            fn visible(c: Cluster, view: View) -> bool {
                if (view.culls == 0u) { return true; }
                let center = (c.minimum.xyz + c.maximum.xyz) * 0.5;
                let half = (c.maximum.xyz - c.minimum.xyz) * 0.5;
                if (!finite(vec4f(center, 1.0)) || !finite(vec4f(half, 1.0))) { return true; }
                for (var i = 0u; i < 6u; i++) {
                    let plane = view.planes[i];
                    let radius = dot(abs(plane.xyz), half);
                    let distance = dot(plane.xyz, center) + plane.w + radius;
                    let scale = dot(abs(plane.xyz), abs(center) + half) + abs(plane.w);
                    if (!finite(vec4f(distance, scale, 0.0, 1.0))) { return true; }
                    if (distance < -0.0001 - scale * 0.00001) { return false; }
                }
                return true;
            }
            fn threadIndex(id: vec3u, groups: vec3u) -> u32 { return id.x + id.y * groups.x * 64u; }
            @compute @workgroup_size(64)
            fn classify(@builtin(global_invocation_id) id: vec3u, @builtin(num_workgroups) groups: vec3u) {
                let i = threadIndex(id, groups);
                if (i >= params.clusterCount * params.viewCount) { return; }
                let v = i / params.clusterCount;
                visibility[i] = select(0u, 1u, visible(clusters[i % params.clusterCount], views[v]));
            }
            @compute @workgroup_size(64)
            fn emit(@builtin(global_invocation_id) id: vec3u, @builtin(num_workgroups) groups: vec3u) {
                let i = threadIndex(id, groups);
                if (i >= params.clusterCount * params.viewCount || visibility[i] == 0u) { return; }
                let v = i / params.clusterCount;
                let index = i % params.clusterCount;
                let c = clusters[index];
                let first = segments[c.part];
                let local = index - first;
                if (local % maximumRun != 0u && visibility[i - 1u] != 0u) { return; }
                // The part's clusters end at the next part's first cluster, or at the end of the table.
                var end = params.clusterCount;
                if (c.part + 1u < params.partCount) { end = segments[c.part + 1u]; }
                var last = index;
                for (var k = 1u; k < maximumRun; k++) {
                    let next = index + k;
                    if (next >= end || visibility[i + k] == 0u) { break; }
                    last = next;
                }
                let tail = clusters[last];
                let slot = atomicAdd(&counts[v * params.partCount + c.part], 1u);
                draws[v * params.clusterCount + first + slot] = Draw(tail.firstIndex + tail.indexCount - c.firstIndex, 1u, c.firstIndex, 0, c.instance);
            }
            """
    }

    /// One render node and camera own this state. The lock protects its frame ring; GPU calls use the device lock.
    final class WGPUShadowClusterCullProcessor: GPUShadowClusterCullProcessor, @unchecked Sendable {
        private struct Params {
            var clusterCount: UInt32
            var viewCount: UInt32
            var partCount: UInt32
            var padding: UInt32 = 0
        }
        private struct Frame {
            var clusters: WebGPU.GPUBuffer
            var clusterBytes: Int
            var views: WebGPU.GPUBuffer
            var viewBytes: Int
            var segments: WebGPU.GPUBuffer
            var segmentBytes: Int
            var arguments: WGPUBuffer
            var counts: WGPUBuffer
            var visibility: WebGPU.GPUBuffer
            var visibilityBytes: Int
            var instances: WGPUBuffer
            var params: WebGPU.GPUBuffer
            var group: WebGPU.GPUBindGroup
            /// Revision of the input last uploaded into this frame's buffers.
            var revision: UInt64?
        }
        // Immutable vendor handles created under webGPUDeviceLock and only used under it afterwards.
        private struct Pipeline: @unchecked Sendable {
            let layout: WebGPU.GPUBindGroupLayout
            let classify: WebGPU.GPUComputePipeline
            let emit: WebGPU.GPUComputePipeline
        }
        private let lock = NSLock()
        private let context: WGPUContext
        private let layout: WebGPU.GPUBindGroupLayout
        private let classify: WebGPU.GPUComputePipeline
        private let emit: WebGPU.GPUComputePipeline
        private var frames: [Frame?]
        private var frame = 0
        private var validatedRevision: UInt64?
        private var isValidatedInputValid = false

        init(context: WGPUContext) {
            self.context = context
            let device = context.device
            let created = webGPUDeviceLock.withLock { _ in
                let layout = device.createBindGroupLayout(descriptor: .init(entries: [
                    .init(binding: 0, visibility: .compute, buffer: .init(type: .readOnlyStorage)),
                    .init(binding: 1, visibility: .compute, buffer: .init(type: .readOnlyStorage)),
                    .init(binding: 2, visibility: .compute, buffer: .init(type: .readOnlyStorage)),
                    .init(binding: 3, visibility: .compute, buffer: .init(type: .storage)),
                    .init(binding: 4, visibility: .compute, buffer: .init(type: .storage)),
                    .init(binding: 5, visibility: .compute, buffer: .init(type: .uniform)),
                    .init(binding: 6, visibility: .compute, buffer: .init(type: .storage)),
                ]))
                let shader = device.createShaderModule(descriptor: .init(
                    label: "Shadow cluster cull", nextInChain: WebGPU.GPUShaderSourceWGSL(code: WGPUShadowClusterCullShaders.cull)
                ))
                let pipelineLayout = device.createPipelineLayout(descriptor: .init(bindGroupLayouts: [layout]))
                func pipeline(_ entry: String) -> WebGPU.GPUComputePipeline {
                    device.createComputePipeline(descriptor: .init(
                        label: "Shadow cluster cull \(entry)", layout: pipelineLayout, compute: .init(module: shader, entryPoint: entry)
                    ))
                }
                return Pipeline(layout: layout, classify: pipeline("classify"), emit: pipeline("emit"))
            }
            layout = created.layout
            classify = created.classify
            emit = created.emit
            frames = Array(repeating: nil, count: max(1, unsafe RenderEngine.configurations.maxFramesInFlight))
        }

        func encode(on command: any CommandBuffer, input: GPUShadowClusterInput, views: [GPUShadowCullView]) -> GPUShadowClusterCullOutput? {
            guard let command = command as? WGPUCommandEncoder, !views.isEmpty else { return nil }
            // Validation walks every cluster: do it once per input revision, not every frame.
            let valid = lock.withLock { () -> Bool in
                if validatedRevision != input.revision {
                    validatedRevision = input.revision
                    isValidatedInputValid = input.isValid
                }
                return isValidatedInputValid
            }
            guard valid else { return nil }
            let argumentBytes = views.count * input.clusters.count * MemoryLayout<IndexedIndirectArguments>.stride
            guard argumentBytes <= GPUShadowClusterCullLimits.argumentBytes, views.count * input.clusters.count <= Int(UInt32.max) else {
                return nil
            }
            return lock.withLock {
                webGPUDeviceLock.withLock { _ in
                    encodeLocked(command, input: input, views: views, argumentBytes: argumentBytes)
                }
            }
        }

        private func encodeLocked(
            _ command: WGPUCommandEncoder,
            input: GPUShadowClusterInput,
            views: [GPUShadowCullView],
            argumentBytes: Int
        ) -> GPUShadowClusterCullOutput? {
            frame = (frame + 1) % frames.count
            let clusterBytes = input.clusters.count * MemoryLayout<GPUShadowCluster>.stride
            let viewBytes = views.count * MemoryLayout<GPUShadowCullView>.stride
            let segmentBytes = input.segments.count * MemoryLayout<UInt32>.stride
            let countBytes = views.count * input.segments.count * MemoryLayout<UInt32>.stride
            let visibilityBytes = views.count * input.clusters.count * MemoryLayout<UInt32>.stride
            if let current = frames[frame], current.clusterBytes >= clusterBytes, current.viewBytes >= viewBytes,
                current.segmentBytes >= segmentBytes, current.arguments.length >= argumentBytes,
                current.counts.length >= countBytes, current.visibilityBytes >= visibilityBytes,
                current.instances.length >= input.instances.count {
                // Reuse.
            } else {
                frames[frame] = makeFrame(
                    clusterBytes: clusterBytes, viewBytes: viewBytes, segmentBytes: segmentBytes,
                    argumentBytes: argumentBytes, countBytes: countBytes, visibilityBytes: visibilityBytes,
                    instanceBytes: input.instances.count
                )
            }
            guard var buffers = frames[frame] else { return nil }
            if buffers.revision != input.revision {
                write(input.clusters, to: buffers.clusters)
                write(input.segments, to: buffers.segments)
                write(input.instances, to: buffers.instances.buffer)
                buffers.revision = input.revision
                frames[frame] = buffers
            }
            write(views, to: buffers.views)
            // Counters start at zero; only the first `count` arguments of each segment are read by the draws.
            write([UInt32](repeating: 0, count: views.count * input.segments.count), to: buffers.counts.buffer)
            var params = Params(clusterCount: UInt32(input.clusters.count), viewCount: UInt32(views.count), partCount: UInt32(input.segments.count))
            unsafe withUnsafeBytes(of: &params) { bytes in
                unsafe context.device.queue.writeBuffer(buffer: buffers.params, bufferOffset: 0, data: bytes)
            }
            let groups = (views.count * input.clusters.count + 63) / 64
            let columns = min(groups, 65_535)
            let pass = command.commandEncoder.beginComputePass(descriptor: nil as WebGPU.GPUComputePassDescriptor?)
            pass.setBindGroup(groupIndex: 0, group: buffers.group, dynamicOffsets: [])
            // WebGPU orders the two dispatches: `emit` reads every visibility `classify` wrote.
            for pipeline in [classify, emit] {
                pass.setPipeline(pipeline: pipeline)
                pass.dispatchWorkgroups(workgroupCountX: UInt32(columns), workgroupCountY: UInt32((groups + columns - 1) / columns), workgroupCountZ: 1)
            }
            pass.end()
            return GPUShadowClusterCullOutput(
                arguments: buffers.arguments,
                counts: buffers.counts,
                instances: buffers.instances,
                viewCount: views.count,
                input: input
            )
        }

        private func makeFrame(
            clusterBytes: Int, viewBytes: Int, segmentBytes: Int, argumentBytes: Int, countBytes: Int, visibilityBytes: Int, instanceBytes: Int
        ) -> Frame? {
            let device = context.device
            // Grow geometrically so a slowly growing scene does not reallocate every frame.
            func size(_ bytes: Int) -> Int { max(256, (bytes + bytes / 2 + 255) & ~255) }
            let clusterSize = size(clusterBytes), viewSize = size(viewBytes), segmentSize = size(segmentBytes)
            let argumentSize = min(size(argumentBytes), GPUShadowClusterCullLimits.argumentBytes)
            let countSize = size(countBytes), instanceSize = size(instanceBytes), visibilitySize = size(visibilityBytes)
            let clusters: WebGPU.GPUBuffer? = device.createBuffer(descriptor: .init(usage: [.storage, .copyDst], size: UInt64(clusterSize)))
            let views: WebGPU.GPUBuffer? = device.createBuffer(descriptor: .init(usage: [.storage, .copyDst], size: UInt64(viewSize)))
            let segments: WebGPU.GPUBuffer? = device.createBuffer(descriptor: .init(usage: [.storage, .copyDst], size: UInt64(segmentSize)))
            let arguments: WebGPU.GPUBuffer? = device.createBuffer(descriptor: .init(usage: [.storage, .indirect], size: UInt64(argumentSize)))
            let counts: WebGPU.GPUBuffer? = device.createBuffer(descriptor: .init(usage: [.storage, .indirect, .copyDst], size: UInt64(countSize)))
            let instances: WebGPU.GPUBuffer? = device.createBuffer(descriptor: .init(usage: [.vertex, .copyDst], size: UInt64(instanceSize)))
            let visibility: WebGPU.GPUBuffer? = device.createBuffer(descriptor: .init(usage: [.storage], size: UInt64(visibilitySize)))
            let params: WebGPU.GPUBuffer? = device.createBuffer(descriptor: .init(usage: [.uniform, .copyDst], size: UInt64(MemoryLayout<Params>.stride)))
            guard let clusters, let views, let segments, let arguments, let counts, let instances, let visibility, let params else { return nil }
            let entries: [WebGPU.GPUBindGroupEntry] = [
                .init(binding: 0, buffer: clusters, size: UInt64(clusterSize)),
                .init(binding: 1, buffer: views, size: UInt64(viewSize)),
                .init(binding: 2, buffer: segments, size: UInt64(segmentSize)),
                .init(binding: 3, buffer: arguments, size: UInt64(argumentSize)),
                .init(binding: 4, buffer: counts, size: UInt64(countSize)),
                .init(binding: 5, buffer: params, size: UInt64(MemoryLayout<Params>.stride)),
                .init(binding: 6, buffer: visibility, size: UInt64(visibilitySize)),
            ]
            let group = device.createBindGroup(descriptor: .init(layout: layout, entries: entries))
            return Frame(
                clusters: clusters, clusterBytes: clusterSize,
                views: views, viewBytes: viewSize,
                segments: segments, segmentBytes: segmentSize,
                arguments: WGPUBuffer(buffer: arguments, device: device, instance: context.instance),
                counts: WGPUBuffer(buffer: counts, device: device, instance: context.instance),
                visibility: visibility, visibilityBytes: visibilitySize,
                instances: WGPUBuffer(buffer: instances, device: device, instance: context.instance),
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
