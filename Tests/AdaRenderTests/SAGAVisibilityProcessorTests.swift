#if SAGA_NATIVE || (os(macOS) && SAGA_METAL_NATIVE_PASS)
    @_spi(Internal) @testable import AdaRender
    import Foundation
    import Math
    import Testing

    @Suite
    struct SAGAVisibilityProcessorTests {
        @Test(.enabled(if: sagaNativeTestDeviceAvailable()))
        func compactsCurrentDepthAndRecoversFromCameraMotionAndOccluderRemoval() async throws {
            #if os(macOS)
            let context = try SAGAMetalRenderBackend().context
            #else
            let context = try SAGAContext.vulkan(debugErrors: true)
            #endif
            let device = SAGARenderDevice(context: context)
            let processor = try #require(device.createGPUVisibilityProcessor())
            let descriptor = TextureDescriptor(width: 5, height: 3, pixelFormat: .rgba_32f, textureUsage: [.read], textureType: .texture2D)
            let texture = Texture2D(gpuTexture: device.createTexture(from: descriptor), sampler: device.createSampler(from: .init()), size: [5, 3])
            let input = device.createBuffer(label: "Visibility input", length: 8, options: .storageShared)
            var markers: [UInt32] = [101, 202]
            input.setElements(&markers)
            let hidden = AABB(center: [0, 0, 0.8], halfExtents: [0.02, 0.02, 0.02])
            let front = AABB(center: [0, 0, 0.2], halfExtents: [0.02, 0.02, 0.02])
            let candidates = [
                GPUVisibilityCandidate(bounds: hidden, draw: 0, source: 0, destination: 0, forceVisible: false),
                GPUVisibilityCandidate(bounds: front, draw: 1, source: 1, destination: 1, forceVisible: false),
            ]
            let draws = [IndexedIndirectArguments(indexCount: 3, instanceCount: 1), IndexedIndirectArguments(indexCount: 3, instanceCount: 1)]
            func evaluate(depth: Float, hole: Bool = false, projection: Transform3D = .identity, entries: [GPUVisibilityCandidate] = candidates) async throws -> ([UInt32], [UInt32]) {
                var pixels = [Float](repeating: depth, count: 5 * 3 * 4)
                if hole { pixels[(5 * 3 - 1) * 4] = 1 }
                unsafe pixels.withUnsafeBytes { bytes in
                    if let pointer = bytes.baseAddress {
                        unsafe texture.gpuTexture.replaceRegion(RectInt(x: 0, y: 0, width: 5, height: 3), mipmapLevel: 0, withBytes: pointer, bytesPerRow: 5 * 16)
                    }
                }
                let command = device.createCommandQueue().makeCommandBuffer()
                var prepared: GPUVisibilityOutput?
                // The first invocation prepares pipelines, then the pyramid and the selected frame.
                for _ in 0..<4 {
                    prepared = processor.encode(on: command, depth: texture, viewProjection: projection,
                                                instances: input, instanceStride: 4, candidates: entries, draws: draws)
                    if prepared != nil { break }
                    await context.queue.drain()
                }
                let output = try #require(prepared)
                command.commit()
                let bytes = try await output.arguments.readData()
                let counts = bytes.withUnsafeBytes { raw in
                    [raw.loadUnaligned(fromByteOffset: 4, as: UInt32.self), raw.loadUnaligned(fromByteOffset: 24, as: UInt32.self)]
                }
                let data = try await output.instances.readData()
                let values = data.withUnsafeBytes { raw in
                    [raw.loadUnaligned(fromByteOffset: 0, as: UInt32.self), raw.loadUnaligned(fromByteOffset: 4, as: UInt32.self)]
                }
                #expect(context.errorLog.all.isEmpty, "\(context.errorLog.all)")
                return (counts, values)
            }
            let occluded = try await evaluate(depth: 0.4)
            #expect(occluded.0 == [0, 1])
            #expect(occluded.1[1] == 202)
            // Camera movement must use the new projection rather than stale visibility.
            #expect(try await evaluate(depth: 0.4, projection: Transform3D(translation: [0, 0, -0.7])).0 == [1, 1])
            #expect(try await evaluate(depth: 1).0 == [1, 1])
            // A hole in the last row/column of odd mip dimensions must survive max reduction.
            #expect(try await evaluate(depth: 0.4, hole: true).0 == [1, 1])
            var force = candidates
            force[0].forceVisible = 1
            #expect(try await evaluate(depth: 0.4, entries: force).0 == [1, 1])
            var near = candidates
            near[0].minimum.z = -0.01
            #expect(try await evaluate(depth: 0.4, entries: near).0 == [1, 1])
        }

        @Test(.enabled(if: sagaNativeTestDeviceAvailable()))
        func failedDevicePreparationLeavesVisibilityOnTheCPU() async throws {
            enum TestError: Error { case unavailable }
            #if os(macOS)
            let native = try SAGAMetalRenderBackend().context
            #else
            let native = try SAGAContext.vulkan()
            #endif
            let unavailable = SAGAContext(
                capabilities: native.capabilities, supportsPresentation: false, shaderOutput: native.shaderOutput,
                makeDevice: { throw TestError.unavailable }
            )
            let device = SAGARenderDevice(context: unavailable)
            let processor = try #require(device.createGPUVisibilityProcessor())
            let depth = Texture2D(
                gpuTexture: device.createTexture(from: .init(
                    width: 1, height: 1, pixelFormat: .rgba_32f, textureUsage: [.read], textureType: .texture2D
                )), sampler: device.createSampler(from: .init()), size: [1, 1]
            )
            let instances = device.createBuffer(label: "Unavailable visibility input", length: 4, options: .storageShared)
            await unavailable.queue.drain()
            #expect(!unavailable.errorLog.all.isEmpty)
            #expect(processor.encode(
                on: device.createCommandQueue().makeCommandBuffer(), depth: depth, viewProjection: .identity,
                instances: instances, instanceStride: 4,
                candidates: [.init(bounds: nil, draw: 0, source: 0, destination: 0, forceVisible: true)],
                draws: [.init(indexCount: 3, instanceCount: 1)]
            ) == nil)
        }
    }
#endif
