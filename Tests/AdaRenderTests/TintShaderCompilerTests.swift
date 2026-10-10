#if canImport(WebGPU) && !os(WASI) && !os(Android)
@testable import AdaRender
import AdaUtils
import Foundation
import Testing

@MainActor
@Suite("Real Tint SPIR-V to WGSL")
struct TintShaderCompilerTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ADAENGINE_VALIDATE_TINT"] == "1"))
    func compilesFreshShader() async throws {
        unsafe RenderEngine.configurations.preferredBackend = .webgpu
        try RenderEngine.setupRenderEngine()
        _ = try #require(TintToolchain.executable(), "Tint is required for this dev validation. Run script/ensure_tint.py.")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tint-shader-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("fresh.glsl")
        try """
        #version 450 core
        #pragma stage : vert
        layout(location = 0) in vec2 corner;
        layout(location = 1) in vec4 instanceOrigin;
        layout(set = 0, binding = 2) uniform ViewUniform { mat4 projection; } view;
        void main() { gl_Position = view.projection * (instanceOrigin + vec4(corner, 0.0, 0.0)); }
        """.write(to: file, atomically: true, encoding: .utf8)
        let compiler = try ShaderCompiler(from: file)
        let spirv = try compiler.compileSpirvBin(for: .vertex, ignoreCache: true)
        let result = try await WGSLShaderCompiler().compile(spirvData: spirv.data, entryPoint: "sprite_validation", stage: .vertex, defines: [])
        #expect(result.language == .wgsl)
        #expect(result.source.contains("@vertex"))
        #expect(result.source.contains("fn sprite_validation("))
        let reflection = WGSLReflection.parse(from: result.source, stage: .vertex)
        #expect(reflection.descriptorSets.first?.uniformsBuffers[2] != nil)
        #expect(result.source.range(of: "@location\\(1u?\\)", options: .regularExpression) != nil)
    }
}
#endif
