import AdaCorePipelines
@testable import AdaRender
import Foundation
import Testing

@MainActor
struct WESLGradientPipelineTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ADAENGINE_VALIDATE_WGSL"] == "1"))
    func gradientUsesLinkedWESLOnNativeWebGPU() throws {
        unsafe RenderEngine.configurations.preferredBackend = .webgpu
        try RenderEngine.setupRenderEngine()
        var pipelines = RenderPipelines(configurator: LinearGradientPipeline())
        let pipeline = pipelines.pipeline(device: unsafe RenderEngine.shared.renderDevice).descriptor
        guard case .code(let source) = pipeline.vertex.source else {
            Issue.record("Expected WGSL for the gradient pipeline")
            return
        }
        #expect(source.contains("ada_wesl_"), "Expected the bundled gradient pipeline to link WESL")
        #expect(pipeline.vertex.reflectionData.descriptorSets.first?.uniformsBuffers[2] != nil)
        #expect(pipeline.fragment?.reflectionData.descriptorSets.first?.uniformsBuffers[0] != nil)
    }
}
