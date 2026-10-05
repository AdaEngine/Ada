#if canImport(Metal)
    @_spi(Internal) @testable import AdaRender
    import Foundation
    import Math
    @unsafe @preconcurrency import Metal
    import Testing

    @Suite
    struct MetalVisibilityProcessorTests {
        @Test
        func compactsCurrentDepthAndRecoversFromCameraMotionAndOccluderRemoval() async throws {
            let backend = MetalRenderBackend()
            let device = try #require(backend.createLocalRenderDevice() as? MetalRenderDevice)
            let processor = try MetalVisibilityProcessor(device: device.device)
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
                let output = try #require(processor.encode(on: command, depth: texture, viewProjection: projection, instances: input, instanceStride: 4, candidates: entries, draws: draws))
                let nativeCommand = try #require(command as? MetalCommandEncoder)
                let nativeOutput = try #require(output.instances as? MetalBuffer)
                let staging = try #require(device.device.makeBuffer(length: 8, options: .storageModeShared))
                let blit = try #require(nativeCommand.commandBuffer.makeBlitCommandEncoder())
                blit.copy(from: nativeOutput.buffer, sourceOffset: 0, to: staging, destinationOffset: 0, size: 8)
                blit.endEncoding()
                await withCheckedContinuation { continuation in
                    command.addCompletedHandler { continuation.resume() }
                    command.commit()
                }
                let bytes = try await output.arguments.readData()
                let counts = bytes.withUnsafeBytes { raw in [unsafe raw.loadUnaligned(fromByteOffset: 4, as: UInt32.self), unsafe raw.loadUnaligned(fromByteOffset: 24, as: UInt32.self)] }
                let values = [unsafe staging.contents().load(as: UInt32.self), unsafe staging.contents().advanced(by: 4).load(as: UInt32.self)]
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
    }
#endif
