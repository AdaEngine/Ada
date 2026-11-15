#if canImport(AdaWGSLCompiler) && !os(WASI)
import AdaAssets
@testable import AdaRender
import Foundation
import Testing

@MainActor
@Suite("WESL modules on native SAGA")
struct WESLShaderModuleTests {
    @Test func shaderSourceRejectsLegacyGLSLBeforeParsing() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("shader-source-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let legacy = "#version 450 core\n#pragma stage : vert\nvoid main() {}\n"
        let glslFile = directory.appendingPathComponent("legacy.glsl")
        try legacy.write(to: glslFile, atomically: true, encoding: .utf8)
        #expect(throws: ShaderCompiler.CompileError.self) { try ShaderSource(from: glslFile) }
        #expect(throws: ShaderCompiler.CompileError.self) { try ShaderSource(source: legacy, lang: .glsl) }

        let wgsl = "@vertex fn main() -> @builtin(position) vec4f { return vec4f(0.0); }"
        let wgslFile = directory.appendingPathComponent("modern.wgsl")
        try wgsl.write(to: wgslFile, atomically: true, encoding: .utf8)
        let fileSource = try ShaderSource(from: wgslFile)
        let inlineSource = try ShaderSource(source: wgsl, lang: .wgsl)
        #expect(fileSource.language == .wgsl)
        #expect(fileSource.getSource(for: .max) == wgsl)
        #expect(inlineSource.getSource(for: .max) == wgsl)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ADAENGINE_VALIDATE_HEADLESS_WESL"] == "1"))
    func headlessLoadsTheBuiltinCanvasMaterialFromWESL() throws {
        if ProcessInfo.processInfo.environment["ADAENGINE_HEADLESS"] != "1" {
            unsafe RenderEngine.configurations.preferredBackend = .headless
        }
        try RenderEngine.setupRenderEngine()
        try #require(unsafe RenderEngine.shared.type == .headless)
        try #require(ShaderModule.supportsBundledWESL)
        let path = "Shaders/Materials/color_canvas_material"
        let builtin = try #require(ShaderModule.loadRequiredBuiltin(at: path, from: .adaModule).asset)
        let variant = try ShaderModule.createBundled(at: path + ".wesl", from: .adaModule, defines: ["VERTEX_POSITIONS"])
        for module in [builtin, variant] {
            let fragment = try #require(module.getShader(for: .fragment))
            let linkedSource = fragment.source
            #expect(throws: Never.self) { try fragment.recompile() }
            #expect(fragment.source == linkedSource)
            #expect(fragment.entryPoint == "color_canvas_mesh_fragment")
            if case .code = fragment.source {
                #expect(fragment.compiledShader != nil)
            } else {
                Issue.record("Expected WGSL for the headless shader stage")
            }
            #expect(module.reflectionData.shaderBuffers["ColorCanvasMaterial"]?.size == 16)
            let vertex = try #require(module.getShader(for: .vertex))
            let layout = try #require(vertex.reflectionData.descriptorSets.first)
            #expect(layout.uniformsBuffers[2]?.size == 192)
            #expect(layout.uniformsBuffers[3]?.size == 128)
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ADAENGINE_VALIDATE_WGSL"] == "1"))
    func nativeShaderModuleLinksAndReflectsBothBindingLayouts() throws {
        unsafe RenderEngine.configurations.preferredBackend = .saga
        try RenderEngine.setupRenderEngine()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ada wesl \(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let legacy = root.appendingPathComponent("old.glsl")
        #expect(throws: ShaderCompiler.CompileError.self) {
            _ = try ShaderModule.create(from: legacy)
        }
        do {
            _ = try ShaderCompiler(from: legacy)
            Issue.record("SAGA accepted a legacy GLSL compiler input")
        } catch {
            #expect(error.localizedDescription.contains("old.glsl"))
            #expect(error.localizedDescription.contains("requires a WESL module"))
        }
        let legacyMaterial = root.appendingPathComponent("old custom.mat")
        try """
        #version 450 core
        #pragma stage : vert
        void main() { gl_Position = vec4(0.0, 0.0, 0.0, 1.0); }
        """.write(to: legacyMaterial, atomically: true, encoding: .utf8)
        let material = Result { try AssetsManager.loadFreshSync(Material.self, at: legacyMaterial.path) }
        let diagnostic: String?
        switch material {
        case .success: diagnostic = nil
        case let .failure(error): diagnostic = error.localizedDescription
        }
        #expect(diagnostic?.contains("old custom.mat") == true, "Reject a GLSL material while loading the asset")
        #expect(diagnostic?.contains("WESLShaders") == true)

        let file = root.appendingPathComponent("main.wesl")
        try "fn tint() -> vec4f { return vec4f(1.0); }".write(
            to: root.appendingPathComponent("color.wesl"), atomically: true, encoding: .utf8
        )
        try """
        import package::color::tint;
        @if(textured) @group(0) @binding(0) var image: texture_2d<f32>;
        @fragment fn fragmentMain() -> @location(0) vec4f {
            @if(textured) return tint() * textureLoad(image, vec2i(0), 0);
            @else return tint();
        }
        """.write(to: file, atomically: true, encoding: .utf8)
        let plain = try ShaderModule.create(from: file)
        let textured = try ShaderModule.createWESL(from: file, features: ["textured": true])
        #expect(plain.getShader(for: .fragment)?.entryPoint == "fragmentMain")
        #expect(plain.reflectionData.resources.isEmpty)
        #expect(textured.reflectionData.resources["image"]?.binding == 0)
    }
}
#endif
