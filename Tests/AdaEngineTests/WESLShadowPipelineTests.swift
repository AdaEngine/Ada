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
        func legacySourcesRemainAvailableAndModuleFailuresPropagate() throws {
            let legacy = CustomMaterial(UIShadowMaterial())
            if ShaderModule.supportsBundledWESL {
                // A renderer that consumes WESL links the material's module and never loads its GLSL fallback.
                #expect(legacy.shaderSource.stages.isEmpty)
            } else {
                #expect(legacy.shaderSource.getSource(for: .vertex) != nil)
                #expect(legacy.shaderSource.getSource(for: .fragment) != nil)
            }
            let failed = CustomMaterial(FailingLinkedMaterial())
            #expect(throws: HookFailure.unavailable) {
                try failed.makeShaderModule(defines: [])
            }
        }

        @Test(.enabled(if: ProcessInfo.processInfo.environment["ADAENGINE_VALIDATE_WGSL"] == "1"))
        func customMaterialRetainsLinkedModuleAndDistinctIdentity() async throws {
            unsafe RenderEngine.configurations.preferredBackend = .saga
            try RenderEngine.setupRenderEngine()
            let material = CustomMaterial(LinkedShadowMaterial())
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
            let other = CustomMaterial(LinkedShadowMaterial())
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
            let root = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let file = root.appendingPathComponent("Sources/AdaUI/Assets/Shaders/ui_shadow.wesl")
            let module = try ShaderModule.create(from: file)
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
            #expect(fragmentBindings.sampledImages.isEmpty)
            #expect(fragmentBindings.samplers.isEmpty)
        }
    }
}

private struct LinkedShadowMaterial: UIShaderMaterial {
    @Uniform(binding: 0, propertyName: "UIShadowMaterial") var parameters: UIShadowParameters

    init() {
        parameters = UIShadowParameters(color: .black, geometry: .zero, style: .zero)
    }

    static func shaderModule() throws -> ShaderModule? {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let compiled = try ShaderModule.create(from: root.appendingPathComponent("Sources/AdaUI/Assets/Shaders/ui_shadow.wesl"))
        // Explicit fixture ABI: production member/name mapping is not implemented yet.
        // This verifies complete-module passthrough and upload, not production shadow material reflection.
        var reflection = ShaderReflectionData()
        let uniform = ShaderResource.ShaderBuffer(
            name: "UIShadowMaterial",
            size: MemoryLayout<UIShadowParameters>.stride,
            shaderStage: .fragment,
            binding: 0,
            resourceAccess: .read,
            members: [:]
        )
        reflection.shaderBuffers[uniform.name] = uniform
        reflection.descriptorSets = [.init()]
        reflection.descriptorSets[0].uniformsBuffers[0] = uniform
        return ShaderModule(
            shaders: [.vertex: try #require(compiled.getShader(for: .vertex)), .fragment: try #require(compiled.getShader(for: .fragment))],
            reflectionData: reflection
        )
    }

    static func fragmentShader() throws -> AssetHandle<ShaderSource> {
        throw LinkedMaterialError.legacySourceMustNotBeRequested
    }

    private enum LinkedMaterialError: Error { case legacySourceMustNotBeRequested }
}

private enum HookFailure: Error { case unavailable }

private struct FailingLinkedMaterial: UIShaderMaterial {
    static func shaderModule() throws -> ShaderModule? { throw HookFailure.unavailable }
    static func fragmentShader() throws -> AssetHandle<ShaderSource> { throw HookFailure.unavailable }
}
#endif
