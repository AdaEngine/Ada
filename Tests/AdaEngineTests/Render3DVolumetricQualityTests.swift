#if os(macOS) || os(Windows) || os(Linux)
@testable import AdaCorePipelines
@_spi(Internal) @testable import AdaRender
import AdaScene
import AdaUtils
import Foundation
import Math
import Testing

extension Render3DGPUTests {
    @Suite("Volumetric sampling quality", .enabled(if: GoldenFrame.isEnabled))
    @MainActor
    struct VolumetricQuality {
        @Test
        func aPlanarShadowDoesNotFormCoherentMarchSlices() async throws {
            let scene = try await DebugViews.makeScene()
            let fixture = try Fixture(device: scene.device)
            let first = try await fixture.render(cameraDistance: 3)
            let moved = try await fixture.render(cameraDistance: 3.025)
            let repeated = try await fixture.render(cameraDistance: 3)
            var firstError: Double = 0
            var movedError: Double = 0
            var motionError: Double = 0
            var temporalChanges = 0
            var blocks = 0
            // A block covers several half-resolution fog texels but remains much
            // smaller than a visible depth slice. Compare with the closed-form
            // Beer-Lambert integral, not another discrete renderer or a golden.
            for by in stride(from: 0, to: Fixture.height, by: 16) {
                for bx in stride(from: 0, to: Fixture.width, by: 16) {
                    var firstResidual = 0.0
                    var movedResidual = 0.0
                    for y in by..<by + 16 {
                        for x in bx..<bx + 16 {
                            let a = Double(first.getPixel(x: x, y: y).red)
                            let b = Double(moved.getPixel(x: x, y: y).red)
                            firstResidual += a - Self.reference(x: x, y: y, cameraDistance: 3)
                            movedResidual += b - Self.reference(x: x, y: y, cameraDistance: 3.025)
                            if first.getPixel(x: x, y: y) != repeated.getPixel(x: x, y: y) { temporalChanges += 1 }
                        }
                    }
                    firstResidual /= 256
                    movedResidual /= 256
                    firstError += abs(firstResidual)
                    movedError += abs(movedResidual)
                    motionError += abs(movedResidual - firstResidual)
                    blocks += 1
                }
            }
            firstError /= Double(blocks)
            movedError /= Double(blocks)
            motionError /= Double(blocks)
            // Twelve samples across six metres have the same approximate 0.5 m
            // spacing as the corridor's 48 samples across 28 m. Fixed midpoints
            // give ~0.0033 coherent block error and ~0.0011 motion error in this
            // fixture; integrating the shadow crossing retains analytic energy.
            #expect(firstError < 0.0022, "Planar shadow integral has coherent slices: \(firstError)")
            #expect(movedError < 0.0022, "A small camera movement must not expose coherent slices: \(movedError)")
            #expect(motionError < 0.0008, "Shadow movement differs from the continuous integral: \(motionError)")
            #expect(temporalChanges == 0, "A static camera/light must not produce animated fog noise.")
            try FileManager.default.createDirectory(at: GoldenFrame.outputDirectory, withIntermediateDirectories: true)
            try first.writePNG(to: GoldenFrame.outputDirectory.appendingPathComponent("volumetric-planar-shadow.png"))
            try moved.writePNG(to: GoldenFrame.outputDirectory.appendingPathComponent("volumetric-planar-shadow-moved.png"))
            try JSONEncoder().encode(["firstMeanBlockError": firstError, "movedMeanBlockError": movedError,
                                      "motionMeanBlockError": motionError, "temporalChangedPixels": Double(temporalChanges)])
                .write(to: GoldenFrame.outputDirectory.appendingPathComponent("volumetric-planar-shadow.json"))
        }

        private static func reference(x: Int, y: Int, cameraDistance: Double) -> Double {
            let sx = (Double(x) + 0.5) / Double(Fixture.width) * 2 - 1
            let sy = (Double(y) + 0.5) / Double(Fixture.height) * 2 - 1
            let forward = 1 / (1 + sx * sx + sy * sy).squareRoot()
            let shadowDistance = min(6, cameraDistance / forward)
            return 1 - exp(-0.1 * shadowDistance)
        }

        private struct Fixture {
            static let width = 256
            static let height = 128
            let device: RenderDevice
            let pipeline: RenderPipeline
            let main: UniformBuffer
            let lights: UniformBuffer
            let matrices: UniformBuffer
            let volumes: UniformBuffer
            let position: Texture2D
            let shadow: Texture2D
            let sampler: Sampler
            let target: RenderTexture

            init(device: RenderDevice) throws {
                self.device = device
                let shader = try CorePipelineShaders.loadBundled(at: "Shaders/local_volumetric_fog_3d.glsl")
                pipeline = device.createRenderPipeline(from: RenderPipelineDescriptor(
                    vertex: try #require(shader.asset.getShader(for: .vertex)),
                    fragment: shader.asset.getShader(for: .fragment), debugName: "Planar fog integral regression",
                    backfaceCulling: false, depthPixelFormat: .none, colorAttachments: [.init(format: .bgra8)]))
                main = device.createUniformBuffer(VolumetricFog3DUniform.self, binding: 4)
                lights = device.createUniformBuffer(Vector4.self, count: 135, binding: 25)
                matrices = device.createUniformBuffer(Vector4.self, count: 97, binding: 28)
                volumes = device.createUniformBuffer(Vector4.self, count: 25, binding: 5)
                var zeroLights = [Vector4](repeating: .zero, count: 135)
                var zeroMatrices = [Vector4](repeating: .zero, count: 97)
                lights.setElements(&zeroLights)
                matrices.setElements(&zeroMatrices)
                var medium = [Vector4](repeating: .zero, count: 25)
                medium[0] = [0, 0, 0, 1]
                medium[1] = [-20, -20, -20, 0.1]
                medium[2] = [20, 20, 20, 0.01]
                medium[3] = [1, 1, 1, 1]
                volumes.setElements(&medium)
                // Zero position denotes sky, so the production shader marches the
                // fixed six-metre range rather than a synthetic surface distance.
                position = Texture2D(image: Image(width: 1, height: 1, color: .black))
                sampler = device.createSampler(from: .init(minFilter: .nearest, magFilter: .nearest))
                shadow = Texture2D(descriptor: .init(width: 1, height: 1, pixelFormat: .r32f,
                    textureUsage: [.read], textureType: .texture2D,
                    samplerDescription: .init(minFilter: .nearest, magFilter: .nearest)))
                // Initialize every stored property before the upload closure
                // captures the fixture's shadow texture.
                target = RenderTexture(size: [Self.width, Self.height], scaleFactor: 1, format: .bgra8)
                var storedDepth: Float = 0.5
                unsafe withUnsafePointer(to: &storedDepth) { pointer in
                    unsafe shadow.replaceRegion(RectInt(x: 0, y: 0, width: 1, height: 1),
                        withBytes: UnsafeRawPointer(pointer), bytesPerRow: MemoryLayout<Float>.stride)
                }
                // Use BGRA8 solely for portable GPU readback. All analytic error
                // thresholds include its quantization. Runtime fog remains FP16.
            }

            func render(cameraDistance: Float) async throws -> Image {
                // Shadow depth = 0.5 + 0.1 * world.z, with stored depth exactly
                // 0.5 in R32F. The sun is visible precisely until world.z = 0.
                let shadowMatrix = Transform3D([0.05, 0, 0, 0], [0, 0.05, 0, 0],
                    [0, 0, 0.1, 0], [0, 0, 0.5, 1])
                main.setData(VolumetricFog3DUniform(
                    inverseView: Transform3D(translation: [0, 0, -cameraDistance]), inverseProjection: .identity,
                    shadowViewProjection0: shadowMatrix, shadowViewProjection1: shadowMatrix, shadowViewProjection2: shadowMatrix,
                    cascadeSplits: [100, 100, 100, 1], shadowAtlas: [1, 1, 0, 1], sunDirection: [0, 1, 0, 0],
                    sunRadiance: [4 * Float.pi, 4 * Float.pi, 4 * Float.pi, 1], medium: .zero, march: [12, 6, 0, 0.9]))
                let command = device.createCommandQueue().makeCommandBuffer()
                let pass = command.beginRenderPass(.init(colorAttachments: [
                    .init(texture: target, operation: .init(loadAction: .clear, storeAction: .store), clearColor: .red)
                ]))
                pass.setViewport(Rect(x: 0, y: 0, width: Float(Self.width), height: Float(Self.height)))
                pass.setRenderPipelineState(pipeline)
                pass.setFragmentBuffer(main, offset: 0, slot: 4)
                pass.setFragmentBuffer(lights, offset: 0, slot: 25)
                pass.setFragmentBuffer(matrices, offset: 0, slot: 28)
                pass.setFragmentBuffer(volumes, offset: 0, slot: 5)
                pass.setFragmentTexture(position, slot: 0)
                pass.setFragmentTexture(shadow, slot: 1)
                pass.setFragmentTexture(Texture2D.whiteTexture, slot: 26)
                pass.setFragmentSamplerState(sampler, slot: 2)
                pass.draw(type: .triangle, vertexStart: 0, vertexCount: 3, instanceCount: 1)
                pass.endRenderPass()
                command.commit()
                return try #require(try await device.readImage(from: target))
            }
        }
    }
}
#endif
