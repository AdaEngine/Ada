#if os(macOS) || os(Windows) || os(Linux)
@_spi(Internal) @testable import AdaRender
import AdaScene
import AdaUtils
import Foundation
import Math
import Testing

extension Render3DGPUTests {
    @Suite("Continuous directional shadow filtering", .enabled(if: GoldenFrame.isEnabled))
    @MainActor
    struct ShadowFiltering {
        // Execute the production WESL helper on an eight-texel step. A nearest 3x3 PCF
        // jumps by 1/3; comparison-before-filter reconstruction must give a continuous ramp.
        @Test func subTexelMotionProducesContinuousVisibility() async throws {
            let image = try await render(tile: false)
            var largestStep: Float = 0
            for x in 0..<image.width {
                let expected = min(1, max(0, ((Float(x) + 0.5) / Float(image.width) * 8 - 2.5) / 3))
                let red = image.getPixel(x: x, y: 2).red
                #expect(abs(red - expected) < 0.01, "Shadow visibility at pixel \(x): \(red), expected \(expected)")
                if x > 0 { largestStep = max(largestStep, abs(red - image.getPixel(x: x - 1, y: 2).red)) }
            }
            #expect(largestStep < 0.03, "Filtering must not jump at texel boundaries: \(largestStep)")
        }

        @Test func filterFootprintCannotReadTheAdjacentCascade() async throws {
            let image = try await render(tile: true)
            for x in 0..<image.width {
                let pixel = image.getPixel(x: x, y: 2)
                #expect(pixel.red < 0.01, "Lit adjacent cascade leaked into shadow at pixel \(x)")
                #expect(pixel.green > 0.99, "Shadowed adjacent cascade leaked into light at pixel \(x)")
            }
        }

        @Test func pcssPenumbraGrowsWithBlockerSeparation() async throws {
            let image = try await render(tile: false, pcss: true)
            var near = 0, far = 0
            for x in 0..<image.width {
                let p = image.getPixel(x:x,y:2)
                if p.red > 0.1 && p.red < 0.9 { near += 1 }
                if p.green > 0.1 && p.green < 0.9 { far += 1 }
            }
            #expect(far > near * 2, "PCSS must widen the penumbra behind a distant blocker: \(near), \(far)")
        }

        private func render(tile: Bool, pcss: Bool = false) async throws -> Image {
            let scene = try await DebugViews.makeScene()
            let device = scene.device
            let probe = try WESLRenderProbe(source: """
            import ada_engine::shadow_pcf::{adaDirectionalShadowPCF, adaDirectionalShadowPCSS};
            import package::fullscreen::{FullscreenVertex, fullscreenVertex};

            @vertex fn vertexMain(@builtin(vertex_index) index: u32) -> FullscreenVertex {
                return fullscreenVertex(index);
            }

            @group(0) @binding(10) var shadowAtlas: texture_2d<f32>;

            @fragment fn fragmentMain(input: FullscreenVertex) -> @location(0) vec4f {
                let texel = vec2f(\(pcss ? "0.015625" : "0.125"), 1.0);
                let x = input.uv.x;
                \(pcss ? """
                    let settings = vec4f(1.0, 0.5, 24.0, 16.0);
                    let projection = mat4x4f(vec4f(1, 0, 0, 0), vec4f(0, 1, 0, 0), vec4f(0, 0, 1, 0), vec4f(0, 0, 0, 1));
                    let close = adaDirectionalShadowPCSS(shadowAtlas, vec2f(x, 0.5), texel, vec2f(0.0078125, 0.5), vec2f(0.9921875, 0.5), 0.21, projection, settings, 1.0);
                    let far = adaDirectionalShadowPCSS(shadowAtlas, vec2f(x, 0.5), texel, vec2f(0.0078125, 0.5), vec2f(0.9921875, 0.5), 0.8, projection, settings, 1.0);
                    return vec4f(close, far, 0.0, 1.0);
                    """ : tile ? """
                    let shadow = adaDirectionalShadowPCF(shadowAtlas, vec2f(x * 0.5, 0.5), texel, vec2f(0.0625, 0.5), vec2f(0.4375, 0.5), 0.5);
                    let light = adaDirectionalShadowPCF(shadowAtlas, vec2f(0.5 + x * 0.5, 0.5), texel, vec2f(0.5625, 0.5), vec2f(0.9375, 0.5), 0.5);
                    return vec4f(shadow, light, 0.0, 1.0);
                    """ : """
                    let visibility = adaDirectionalShadowPCF(shadowAtlas, vec2f(x, 0.5), texel, vec2f(0.0625, 0.5), vec2f(0.9375, 0.5), 0.5);
                    return vec4f(vec3f(visibility), 1.0);
                    """)
            }
            """)
            let pipeline = device.createRenderPipeline(from: RenderPipelineDescriptor(
                vertex: probe.vertex, fragment: probe.fragment,
                debugName: "Shadow PCF regression", backfaceCulling: false,
                depthPixelFormat: .none, colorAttachments: [.init(format: .bgra8)]
            ))
            let size = pcss ? 64 : 8
            var depths = Image(width: size, height: 1, color: pcss ? Color(red:0.2,green:0.2,blue:0.2) : .black)
            for x in size/2..<size { depths.setPixel(in: [Float(x), 0], color: .white) }
            let texture = Texture2D(image: depths)
            let target = RenderTexture(size: [128, 4], scaleFactor: 1, format: .bgra8)
            let command = device.createCommandQueue().makeCommandBuffer()
            let pass = command.beginRenderPass(.init(colorAttachments: [
                .init(texture: target, operation: .init(loadAction: .clear, storeAction: .store), clearColor: .red)
            ]))
            pass.setViewport(Rect(x: 0, y: 0, width: 128, height: 4))
            pass.setRenderPipelineState(pipeline)
            pass.setFragmentTexture(texture, slot: try probe.textureSlot(10))
            pass.draw(type: .triangle, vertexStart: 0, vertexCount: 3, instanceCount: 1)
            pass.endRenderPass()
            await WESLRenderProbe.complete(command)
            return try #require(try await device.readImage(from: target))
        }
    }
}
#endif
