#if os(macOS)
import AdaCorePipelines
@testable import AdaRender
@testable import AdaUI
import AdaUtils
import Foundation
import Math
import Testing

/// Run separately from headless UI tests to initialize the actual Metal backend.
@Suite(.serialized)
@MainActor
struct GlassMetalRenderingTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ADAENGINE_GLASS_METAL_SMOKE"] == "1"))
    func croppedSnapshotsPreservePixelsAndMeasureTheGlassPipeline() async throws {
        unsafe RenderEngine.configurations.preferredBackend = .saga
        try RenderEngine.setupRenderEngine()
        #expect(unsafe RenderEngine.shared.type == .saga)
        let device = unsafe RenderEngine.shared.renderDevice
        let size = SizeInt(width: 1200, height: 2400)
        var background = Image(width: size.width, height: size.height, color: .white)
        for y in 0..<size.height {
            for x in 0..<size.width {
                background.setPixel(in: Point(Float(x), Float(y)), color: Color(
                    red: Float(x % 120) / 119,
                    green: Float(y % 100) / 99,
                    blue: ((x / 40 + y / 40) % 2 == 0) ? 0.2 : 0.8,
                    alpha: 1
                ))
            }
        }
        let source = Texture2D(image: background)
        let viewport = Rect(x: 0, y: 0, width: Float(size.width), height: Float(size.height))
        let descriptor = GlassPipeline().configurate(with: RenderPipelineEmptyConfiguration())
        let pipeline = device.createRenderPipeline(from: descriptor)
        let projection = Transform3D.createUIProjection(width: viewport.width, height: viewport.height, scaleFactor: 1)
        let uniform = GlobalViewUniform(projectionMatrix: projection, viewProjectionMatrix: projection)
        let queue = device.createCommandQueue()
        var indices = BufferData<UInt32>(label: "glass-test-indices", elements: [0, 1, 2, 2, 3, 0])
        indices.write(to: device)

        func render(configuration: Glass, crop: Bool, pipeline: any RenderPipeline, drawsGlass: Bool = true) async throws -> (Image, Double) {
            let transform = Transform3D(translation: [600, -900, 0], rotation: Quat(axis: [0, 0, 1], angle: 0.12), scale: [900, 340, 1])
            let vertices = UITessellator().tessellateGlassQuad(
                transform: transform, halfSize: [450, 170], configuration: configuration, scaleFactor: 1
            )
            var buffer = BufferData<GlassVertexData>(label: "glass-test-vertices", elements: vertices)
            buffer.write(to: device)
            let snapshot = RenderTexture(size: size, scaleFactor: 1, format: .bgra8)
            let target = RenderTexture(size: size, scaleFactor: 1, format: .bgra8)
            let command = queue.makeCommandBuffer()
            // Poison uncopied pixels: insufficient optical padding must fail the comparison.
            let clear = command.beginRenderPass(RenderPassDescriptor(colorAttachments: [
                .init(texture: snapshot, operation: .init(loadAction: .clear, storeAction: .store), clearColor: Color(red: 1, green: 0, blue: 1, alpha: 1))
            ]))
            clear.endRenderPass()
            let rect = crop ? GlassBackgroundCapture.region(vertices: vertices, viewport: viewport, scaleFactor: 1, textureSize: size) : viewport
            let origin = Origin3D(x: Int(rect.minX), y: Int(rect.minY))
            let blit = command.beginBlitPass(.init())
            blit.copyTextureToTexture(
                source: source,
                sourceOrigin: origin,
                sourceSize: Size3D(width: Int(rect.width), height: Int(rect.height)),
                sourceMipLevel: 0,
                sourceSlice: 0,
                destination: snapshot,
                destinationOrigin: origin,
                destinationMipLevel: 0,
                destinationSlice: 0
            )
            blit.endBlitPass()
            let pass = command.beginRenderPass(RenderPassDescriptor(colorAttachments: [
                .init(texture: target, operation: .init(loadAction: .clear, storeAction: .store), clearColor: .black)
            ]))
            pass.setViewport(viewport)
            pass.setVertexBuffer(uniform, slot: GlobalBufferIndex.viewUniform)
            pass.setVertexBuffer(buffer, offset: 0, slot: 0)
            pass.setIndexBuffer(indices, indexFormat: .uInt32)
            pass.setRenderPipelineState(pipeline)
            pass.setResourceSet(RenderResourceSet(bindings: [
                .init(binding: 0, shaderStages: .fragment, resource: .texture(snapshot)),
                .init(binding: 1, shaderStages: .fragment, resource: .sampler(snapshot.sampler))
            ]), index: 0)
            if drawsGlass { pass.drawIndexed(indexCount: 6, indexBufferOffset: 0, instanceCount: 1) }
            pass.endRenderPass()
            let gpuSeconds = await withCheckedContinuation { continuation in
                command.addCompletedTimingHandler { continuation.resume(returning: $0 ?? 0) }
                command.commit()
            }
            return (try #require(try await device.readImage(from: target)), gpuSeconds * 1000)
        }
        for configuration in [Glass.regular, .clear, .regular.dispersionStrength(0.4).glassThickness(40), .regular.blurRadius(0)] {
            let full = try await render(configuration: configuration, crop: false, pipeline: pipeline)
            let cropped = try await render(configuration: configuration, crop: true, pipeline: pipeline)
            #expect(full.0.data == cropped.0.data, "Cropped capture must retain every texel the glass shader reads.")
            #expect(cropped.0.getPixel(x: 600, y: 900) != .black)
        }
        let optimized = try await render(configuration: .regular, crop: true, pipeline: pipeline)
        if let directory = ProcessInfo.processInfo.environment["ADAENGINE_GLASS_CAPTURE_DIRECTORY"] {
            try optimized.0.writePNG(to: URL(fileURLWithPath: directory).appendingPathComponent("glass-optimized.png"))
        }
        // Optional baseline is supplied by the benchmark invocation, never by app code.
        if let reference = ProcessInfo.processInfo.environment["ADAENGINE_GLASS_REFERENCE_SHADER"] {
            let module = try ShaderModule.create(from: URL(fileURLWithPath: reference))
            var oldDescriptor = descriptor
            oldDescriptor.vertex = try #require(module.getShader(for: .vertex))
            let referenceFragment: Shader = try #require(module.getShader(for: .fragment))
            oldDescriptor.fragment = referenceFragment
            let oldPipeline = device.createRenderPipeline(from: oldDescriptor)
            var oldTimes: [Double] = [], newTimes: [Double] = [], plainTimes: [Double] = []
            for iteration in 0..<8 {
                let old = try await render(configuration: .regular, crop: false, pipeline: oldPipeline)
                let new = try await render(configuration: .regular, crop: true, pipeline: pipeline)
                let plain = try await render(configuration: .regular, crop: true, pipeline: pipeline, drawsGlass: false)
                if iteration >= 2 { oldTimes.append(old.1); newTimes.append(new.1); plainTimes.append(plain.1) }
                if iteration == 7, let directory = ProcessInfo.processInfo.environment["ADAENGINE_GLASS_CAPTURE_DIRECTORY"] {
                    try old.0.writePNG(to: URL(fileURLWithPath: directory).appendingPathComponent("glass-reference.png"))
                }
            }
            func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }
            if (oldTimes + newTimes + plainTimes).allSatisfy({ $0 > 0 }) {
                print("Glass SAGA Metal GPU ms: reference=\(median(oldTimes)), optimized=\(median(newTimes)), no-glass=\(median(plainTimes))")
            } else {
                print("SAGA Metal did not report GPU timing for this benchmark.")
            }
        }
    }
}
#endif
