#if os(macOS) || os(Windows) || os(Linux)
@_spi(Internal) @testable import AdaRender
import AdaScene
import AdaUtils
import Foundation
import Math
import Testing

extension Render3DGPUTests {
    @Suite("Display quantization dithering", .enabled(if: GoldenFrame.isEnabled))
    @MainActor
    struct DisplayDither {
        @Test
        func warmShadowRoundingPreservesMeanAndBlack() async throws {
            // The production helper writes directly to a real BGRA8 target. The
            // control is the same fractional warm color without stochastic rounding.
            let image = try await render()
            let expected: [Float] = [1.35 / 255, 0.85 / 255, 0.40 / 255]
            var control = [Float](repeating: 0, count: 3)
            var actual = [Float](repeating: 0, count: 3)
            var codes = Array(repeating: Set<Int>(), count: 3)
            var maximumError: Float = 0
            var alteredBlack = 0
            var alteredWhite = 0
            var hueInversions = 0
            for y in 0..<image.height {
                for x in 0..<128 {
                    let black = image.getPixel(x: x, y: y)
                    let white = image.getPixel(x: x + 128, y: y)
                    if black.red != 0 || black.green != 0 || black.blue != 0 { alteredBlack += 1 }
                    if white.red != 1 || white.green != 1 || white.blue != 1 { alteredWhite += 1 }
                    let plain = channels(image.getPixel(x: x + 256, y: y))
                    let dithered = channels(image.getPixel(x: x + 384, y: y))
                    if dithered[0] < dithered[1] || dithered[1] < dithered[2] { hueInversions += 1 }
                    for channel in 0..<3 {
                        control[channel] += plain[channel]
                        actual[channel] += dithered[channel]
                        codes[channel].insert(Int((dithered[channel] * 255).rounded()))
                        maximumError = max(maximumError, abs(dithered[channel] - expected[channel]))
                    }
                }
            }
            let count = Float(128 * image.height)
            #expect(alteredBlack == 0, "Exact black must still quantize to code zero.")
            #expect(alteredWhite == 0, "Exact white must still quantize to code 255.")
            #expect(hueInversions == 0, "A shared RGB offset must not invent a green/blue hue inversion.")
            control = control.map { $0 / count }
            actual = actual.map { $0 / count }
            for channel in 0..<3 {
                #expect(abs(actual[channel] - expected[channel]) < 0.025 / 255,
                    "Dither must preserve the fractional display value in its spatial mean.")
                #expect(abs(actual[channel] - expected[channel]) < abs(control[channel] - expected[channel]) * 0.1)
                #expect(codes[channel].count == 2,
                    "Fractional low-light values must use neighboring codes, rather than solid colored contours.")
            }
            #expect(maximumError <= 1.001 / 255, "Dither is bounded to at most one quantized display step.")

            // A warm 0..24-code ramp checks gradients as well as constant patches.
            // Averaging 16 columns retains its energy without requiring a golden
            // reference image or accepting a brightness shift as debanding.
            var largestRampMeanError: Float = 0
            for block in 0..<8 {
                var mean = [Float](repeating: 0, count: 3)
                for y in 0..<image.height {
                    for column in 0..<16 {
                        let x = block * 16 + column
                        let rendered = channels(image.getPixel(x: 512 + x, y: y))
                        let t = (Float(x) + 0.5) / 128
                        let reference = [24 * t / 255, 15 * t / 255, 7 * t / 255]
                        for channel in 0..<3 {
                            mean[channel] += rendered[channel]
                            maximumError = max(maximumError, abs(rendered[channel] - reference[channel]))
                        }
                    }
                }
                let t = (Float(block * 16) + 8) / 128
                let reference = [24 * t / 255, 15 * t / 255, 7 * t / 255]
                for channel in 0..<3 {
                    let error = abs(mean[channel] / Float(16 * image.height) - reference[channel])
                    largestRampMeanError = max(largestRampMeanError, error)
                    #expect(error < 0.05 / 255, "Warm gradient block must retain its intended mean color.")
                }
            }
            #expect(maximumError <= 1.001 / 255)

            try FileManager.default.createDirectory(at: GoldenFrame.outputDirectory, withIntermediateDirectories: true)
            try image.writePNG(to: GoldenFrame.outputDirectory.appendingPathComponent("display-dither-bgra8.png"))
            let statistics = ["expected": expected, "controlMean": control, "ditherMean": actual,
                              "maximumError": [maximumError], "largestRampMeanError": [largestRampMeanError]]
            try JSONEncoder().encode(statistics)
                .write(to: GoldenFrame.outputDirectory.appendingPathComponent("display-dither-bgra8.json"))
        }

        private func channels(_ color: Color) -> [Float] {
            [color.red, color.green, color.blue]
        }

        private func render() async throws -> Image {
            let scene = try await DebugViews.makeScene()
            let device = scene.device
            let source = try ShaderSource(source: """
            #version 450 core
            #pragma stage : vert
            [[main]]
            void display_dither_vertex() {
                vec2 p[3] = vec2[](vec2(-1,-1), vec2(3,-1), vec2(-1,3));
                gl_Position = vec4(p[gl_VertexIndex], 0, 1);
            }
            #version 450 core
            #pragma stage : frag
            layout(location=0) out vec4 o_Color;
            #include <AdaEngine/Tonemapping.glsl>
            [[main]]
            void display_dither_fragment() {
                float x = floor(gl_FragCoord.x);
                vec3 color;
                if (x < 128.0) { color = vec3(0.0); }
                else if (x < 256.0) { color = vec3(1.0); }
                else if (x < 512.0) { color = vec3(1.35,0.85,0.40) / 255.0; }
                else { color = vec3(24.0,15.0,7.0) * ((x - 512.0 + 0.5) / 128.0) / 255.0; }
                if (x < 256.0 || x >= 384.0) { color = adaDitherDisplay(color, gl_FragCoord.xy); }
                o_Color = vec4(color,1.0);
            }
            """)
            let module = try ShaderCompiler(shaderSource: source).compileShaderModule()
            let pipeline = device.createRenderPipeline(from: RenderPipelineDescriptor(
                vertex: try #require(module.getShader(for: .vertex)), fragment: module.getShader(for: .fragment),
                debugName: "Display quantization regression", backfaceCulling: false,
                depthPixelFormat: .none, colorAttachments: [.init(format: .bgra8)]
            ))
            let target = RenderTexture(size: [640, 128], scaleFactor: 1, format: .bgra8)
            let command = device.createCommandQueue().makeCommandBuffer()
            let pass = command.beginRenderPass(.init(colorAttachments: [
                .init(texture: target, operation: .init(loadAction: .clear, storeAction: .store), clearColor: .red)
            ]))
            pass.setViewport(Rect(x: 0, y: 0, width: 640, height: 128))
            pass.setRenderPipelineState(pipeline)
            pass.draw(type: .triangle, vertexStart: 0, vertexCount: 3, instanceCount: 1)
            pass.endRenderPass()
            command.commit()
            return try #require(try await device.readImage(from: target))
        }
    }
}
#endif
