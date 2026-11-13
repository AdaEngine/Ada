@testable import AdaCorePipelines
@testable import AdaRender
import AdaSprite
import Foundation
import Testing

@MainActor
struct WESLUIPipelineTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ADAENGINE_VALIDATE_WGSL"] == "1"))
    func uiPrimitivesUseLinkedWESLAndPreserveBindings() throws {
        unsafe RenderEngine.configurations.preferredBackend = .webgpu
        try RenderEngine.setupRenderEngine()
        let device = unsafe RenderEngine.shared.renderDevice
        var quads = RenderPipelines(configurator: QuadPipeline())
        var circles = RenderPipelines(configurator: CirclePipeline())
        var lines = RenderPipelines(configurator: LinePipeline())
        let quad = quads.pipeline(device: device).descriptor
        for pipeline in [quad, circles.pipeline(device: device).descriptor, lines.pipeline(device: device).descriptor] {
            guard case .code(let source) = pipeline.vertex.source else {
                Issue.record("Expected WGSL for the UI pipeline")
                continue
            }
            #expect(source.contains("ada_wesl_"), "Expected the UI pipeline to link WESL")
            #expect(pipeline.vertex.reflectionData.descriptorSets.first?.uniformsBuffers[2] != nil)
        }
        #expect(quad.fragment?.reflectionData.descriptorSets.first?.sampledImages[0] != nil)
        #expect(quad.fragment?.reflectionData.descriptorSets.first?.samplers[1] != nil)

        let lights = Light2DRenderPipelines(device: device)
        for pipeline in [lights.compositePipeline, lights.pointLightPipeline, lights.directionalLightPipeline] {
            guard case .code(let source) = pipeline.descriptor.vertex.source else {
                Issue.record("Expected WGSL for the 2D light pipeline")
                continue
            }
            #expect(source.contains("ada_wesl_"), "Expected the 2D light pipeline to link WESL")
        }
        #expect(lights.compositePipeline.descriptor.fragment?.reflectionData.descriptorSets.first?.uniformsBuffers[3] != nil)
        #expect(lights.pointLightPipeline.descriptor.fragment?.reflectionData.descriptorSets.first?.uniformsBuffers[4] != nil)
        #expect(lights.directionalLightPipeline.descriptor.fragment?.reflectionData.descriptorSets.first?.uniformsBuffers[2] != nil)

        let upscale = UpscalePipeline(device: device).renderPipeline
        let presentation = PixelPerfectPipelines(device: device, outputPipeline: upscale).intermediate
        for pipeline in [upscale, presentation] {
            guard case .code(let source) = pipeline.descriptor.vertex.source else {
                Issue.record("Expected WGSL for fullscreen presentation")
                continue
            }
            #expect(source.contains("ada_wesl_"), "Expected fullscreen presentation to link WESL")
        }

        var temporal = Temporal3DPipelines(device: device)
        var screenQuality = ScreenQuality3DPipelines(device: device)
        let depth = temporal.depthPipeline(device: device)
        for pipeline in [temporal.skyPipeline(device: device), screenQuality.aaPipeline(device: device), depth] {
            guard case .code(let source) = pipeline.descriptor.vertex.source else {
                Issue.record("Expected WGSL for the 3D screen pass")
                continue
            }
            #expect(source.contains("ada_wesl_"), "Expected the 3D screen pass to link WESL")
        }
        if case .code(let source) = depth.descriptor.fragment?.source {
            #expect(source.contains("texture_depth_2d"))
        } else {
            Issue.record("Expected a depth fragment stage")
        }

        var irradiance = DynamicIrradiance3DViews()
        let fragment = try #require(irradiance.getPipeline(device).descriptor.fragment)
        guard case .code(let irradianceSource) = fragment.source else {
            Issue.record("Expected linked WGSL for dynamic irradiance")
            return
        }
        #expect(irradianceSource.contains("textureLoad"))
        let bindings = try #require(fragment.reflectionData.descriptorSets.first)
        #expect(Set(bindings.sampledImages.keys) == [0, 1, 2, 3, 6, 26])
        #expect(bindings.samplers.isEmpty)
    }
}
