#if SAGA_NATIVE && (os(Windows) || os(Linux))
    import AdaUtils
    import Foundation
    import Math
    import Testing

    @_spi(Internal) @testable import AdaRender

    /// Runs DLSS Super Resolution on a real NVIDIA GPU. Set `ADAENGINE_DLSS=1` and `ADAENGINE_NGX_SDK_PATH` to a folder that
    /// holds `adaengine_ngx` and the NGX DLSS library (`python ada_tool.py build ngx-bridge` creates the bridge).
    @Suite(.serialized)
    struct DLSSSmokeTests {
        private static var enabled: Bool { ProcessInfo.processInfo.environment["ADAENGINE_DLSS"] == "1" }

        @Test(.enabled(if: DLSSSmokeTests.enabled))
        func superResolutionRunsOnTheGPU() async throws {
            let backend = try SAGANativeRenderBackend(windowless: true)
            let device = backend.renderDevice
            var waited = 0
            while !device.dlssStatus.isAvailable, waited < 200, case let reason = device.dlssStatus.unavailableReason ?? "", reason.contains("initializing") {
                try await Task.sleep(for: .milliseconds(50))
                waited += 1
            }
            try #require(device.dlssStatus.isAvailable, "DLSS status: \(device.dlssStatus)")

            let input = SizeInt(width: 960, height: 540)
            let output = SizeInt(width: 1920, height: 1080)
            let sampler = device.createSampler(from: SamplerDescriptor())
            func texture(_ size: SizeInt, _ format: PixelFormat, _ usage: Texture.Usage) -> Texture2D {
                let gpu = device.createTexture(from: TextureDescriptor(width: size.width, height: size.height, pixelFormat: format, textureUsage: usage, textureType: .texture2D))
                return Texture2D(gpuTexture: gpu, sampler: sampler, size: size)
            }
            let color = texture(input, .rgba_16f, [.renderTarget, .read, .write])
            let depth = texture(input, .depth_32f, [.renderTarget, .read])
            let motion = texture(input, .rgba_16f, [.renderTarget, .read, .write])
            let reactive = texture(input, .bgra8, [.renderTarget, .read, .write])
            let result = texture(output, .rgba_16f, [.renderTarget, .read, .write])

            let scaler = try #require(device.createTemporalUpscaler(inputSize: input, outputSize: output))
            let commands = device.createCommandQueue().makeCommandBuffer()
            #expect(
                scaler.encode(
                    commandBuffer: commands, color: color, depth: depth, motion: motion, reactive: reactive, output: result,
                    jitter: .zero, reset: true
                )
            )
            commands.commit()
            await backend.context.queue.drain()
            #expect(backend.context.errorLog.all.isEmpty, "SAGA device errors: \(backend.context.errorLog.all)")
            #expect(device.dlssStatus.isAvailable, "DLSS status after the frame: \(device.dlssStatus)")

            // Replacing the upscaler (a resize or scale change) must release the old feature only after its work retired.
            var replacement: (any TemporalUpscaler)? = device.createTemporalUpscaler(inputSize: SizeInt(width: 640, height: 360), outputSize: output)
            let smaller = texture(SizeInt(width: 640, height: 360), .rgba_16f, [.renderTarget, .read, .write])
            let smallerDepth = texture(SizeInt(width: 640, height: 360), .depth_32f, [.renderTarget, .read])
            let smallerMotion = texture(SizeInt(width: 640, height: 360), .rgba_16f, [.renderTarget, .read, .write])
            let again = device.createCommandQueue().makeCommandBuffer()
            #expect(
                try #require(replacement).encode(
                    commandBuffer: again, color: smaller, depth: smallerDepth, motion: smallerMotion, reactive: reactive, output: result,
                    jitter: .zero, reset: true
                )
            )
            again.commit()
            replacement = nil
            await backend.context.queue.drain()
            #expect(backend.context.errorLog.all.isEmpty, "SAGA device errors after replacing the upscaler: \(backend.context.errorLog.all)")
            #expect(device.dlssStatus.isAvailable, "DLSS status after replacing the upscaler: \(device.dlssStatus)")
        }
    }
#endif
