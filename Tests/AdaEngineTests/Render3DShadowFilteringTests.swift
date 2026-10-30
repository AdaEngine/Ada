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
        // Execute the production GLSL helper on an eight-texel step. A nearest 3x3 PCF
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
            let source = try ShaderSource(source: """
            #version 450 core
            #pragma stage : vert
            layout(location=0) out vec2 v_UV;
            [[main]]
            void shadow_test_vertex() {
                vec2 p[3] = vec2[](vec2(-1,-1), vec2(3,-1), vec2(-1,3));
                gl_Position = vec4(p[gl_VertexIndex], 0, 1);
                v_UV = p[gl_VertexIndex] * 0.5 + 0.5;
            }
            #version 450 core
            #pragma stage : frag
            layout(location=0) in vec2 v_UV;
            layout(location=0) out vec4 o_Color;
            layout(binding=10) uniform texture2D u_DirectionalShadowTexture;
            layout(binding=11) uniform sampler u_DirectionalShadowSampler;
            #include <AdaEngine/ShadowPCF.glsl>
            [[main]]
            void shadow_test_fragment() {
                vec2 texel = vec2(\(pcss ? "0.015625" : "0.125"), 1.0);
                \(pcss ? """
                vec4 settings=vec4(1.0,0.5,24.0,16.0);
                float close=adaDirectionalShadowPCSS(vec2(v_UV.x,0.5),texel,vec2(0.0078125,0.5),vec2(0.9921875,0.5),0.21,mat4(1.0),settings,1.0);
                float far=adaDirectionalShadowPCSS(vec2(v_UV.x,0.5),texel,vec2(0.0078125,0.5),vec2(0.9921875,0.5),0.8,mat4(1.0),settings,1.0);
                o_Color=vec4(close,far,0.0,1.0);
                """ : tile ? """
                float shadow = adaDirectionalShadowPCF(vec2(v_UV.x * 0.5, 0.5), texel, vec2(0.0625, 0.5), vec2(0.4375, 0.5), 0.5);
                float light = adaDirectionalShadowPCF(vec2(0.5 + v_UV.x * 0.5, 0.5), texel, vec2(0.5625, 0.5), vec2(0.9375, 0.5), 0.5);
                o_Color = vec4(shadow, light, 0.0, 1.0);
                """ : """
                float visibility = adaDirectionalShadowPCF(vec2(v_UV.x, 0.5), texel, vec2(0.0625, 0.5), vec2(0.9375, 0.5), 0.5);
                o_Color = vec4(vec3(visibility), 1.0);
                """)
            }
            """)
            let module = try ShaderCompiler(shaderSource: source).compileShaderModule()
            let pipeline = device.createRenderPipeline(from: RenderPipelineDescriptor(
                vertex: try #require(module.getShader(for: .vertex)), fragment: module.getShader(for: .fragment),
                debugName: "Shadow PCF regression", backfaceCulling: false,
                depthPixelFormat: .none, colorAttachments: [.init(format: .bgra8)]
            ))
            let size = pcss ? 64 : 8
            var depths = Image(width: size, height: 1, color: pcss ? Color(red:0.2,green:0.2,blue:0.2) : .black)
            for x in size/2..<size { depths.setPixel(in: [Float(x), 0], color: .white) }
            let texture = Texture2D(image: depths)
            let sampler = device.createSampler(from: .init(minFilter: .nearest, magFilter: .nearest))
            let target = RenderTexture(size: [128, 4], scaleFactor: 1, format: .bgra8)
            let command = device.createCommandQueue().makeCommandBuffer()
            let pass = command.beginRenderPass(.init(colorAttachments: [
                .init(texture: target, operation: .init(loadAction: .clear, storeAction: .store), clearColor: .red)
            ]))
            pass.setViewport(Rect(x: 0, y: 0, width: 128, height: 4))
            pass.setRenderPipelineState(pipeline)
            pass.setFragmentTexture(texture, slot: 10)
            pass.setFragmentSamplerState(sampler, slot: 11)
            pass.draw(type: .triangle, vertexStart: 0, vertexCount: 3, instanceCount: 1)
            pass.endRenderPass()
            command.commit()
            return try #require(try await device.readImage(from: target))
        }
    }
}
#endif
