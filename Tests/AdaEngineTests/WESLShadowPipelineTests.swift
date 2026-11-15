#if canImport(AdaWGSLCompiler) && !os(WASI)
import AdaAssets
@testable import AdaRender
@testable import AdaUI
import Foundation
import Math
import Testing

extension Render3DGPUTests {
    @MainActor
    struct WESLShadowPipelineTests {
        @Test
        func linkedModuleFailuresPropagate() throws {
            #expect(throws: HookFailure.unavailable) {
                try CustomMaterial(FailingLinkedMaterial()).makeShaderModule(defines: [])
            }
        }

        @Test(.enabled(if: ProcessInfo.processInfo.environment["ADAENGINE_VALIDATE_WGSL"] == "1"))
        func customMaterialRetainsLinkedModuleAndDistinctIdentity() async throws {
            unsafe RenderEngine.configurations.preferredBackend = .saga
            try RenderEngine.setupRenderEngine()
            let material = CustomMaterial(UIShadowMaterial())
            let module = try material.makeShaderModule(defines: [])
            #expect(module.getShader(for: .vertex)?.entryPoint == "ui_shadow_vertex")
            #expect(module === (try material.makeShaderModule(defines: [])))
            #expect(material.shaderSource.stages.isEmpty)
            let storage = MaterialStorageData()
            storage.updateUniformBuffers(from: module)
            unsafe MaterialStorage.shared.setMaterialData(storage, for: material)
            material.parameters = UIShadowParameters(color: .black, geometry: Vector4(10, 20, 30, 4), style: Vector4(1, 2, 3, 0.5))
            material.update()
            let gpuBuffer = try #require(storage.uniformBufferSet["UIShadowMaterial"])
            let bytes = try await gpuBuffer.readData()
            let uploaded = bytes.withUnsafeBytes { unsafe $0.loadUnaligned(as: UIShadowParameters.self) }
            #expect(uploaded.geometry == Vector4(10, 20, 30, 4))
            #expect(uploaded.style == Vector4(1, 2, 3, 0.5))
            let other = CustomMaterial(UIShadowMaterial())
            #expect(material != other)
            #expect(Set([material, other]).count == 2)
            #expect(throws: (any Error).self) {
                try material.makeShaderModule(defines: [.init(name: "UNSUPPORTED", value: "1")])
            }
        }

        @Test(.enabled(if: ProcessInfo.processInfo.environment["ADAENGINE_VALIDATE_WGSL"] == "1"))
        func shadowModuleLoadsBothStagesAndPreservesBindings() throws {
            unsafe RenderEngine.configurations.preferredBackend = .saga
            try RenderEngine.setupRenderEngine()
            let module = try #require(try UIShadowMaterial.shaderModule())
            #expect(Set(module.stages) == [.vertex, .fragment])
            let vertex = try #require(module.getShader(for: .vertex))
            let fragment = try #require(module.getShader(for: .fragment))
            #expect(vertex.entryPoint == "ui_shadow_vertex")
            #expect(fragment.entryPoint == "ui_shadow_fragment")
            let vertexBindings = try #require(vertex.reflectionData.descriptorSets.first)
            let fragmentBindings = try #require(fragment.reflectionData.descriptorSets.first)
            #expect(Set(vertexBindings.uniformsBuffers.keys) == [2])
            #expect(Set(fragmentBindings.uniformsBuffers.keys) == [0])
            // These sizes must come from the validated shader, never from a host-stride override.
            #expect(vertexBindings.uniformsBuffers[2]?.size == 192)
            #expect(fragmentBindings.uniformsBuffers[0]?.size == 48)
            #expect(module.reflectionData.shaderBuffers["UIShadowMaterial"]?.size == MemoryLayout<UIShadowParameters>.stride)
            #expect(fragmentBindings.sampledImages.isEmpty)
            #expect(fragmentBindings.samplers.isEmpty)
        }
    }
}

private enum HookFailure: Error { case unavailable }

private struct FailingLinkedMaterial: UIShaderMaterial {
    static func shaderModule() throws -> ShaderModule? { throw HookFailure.unavailable }
}
#endif
