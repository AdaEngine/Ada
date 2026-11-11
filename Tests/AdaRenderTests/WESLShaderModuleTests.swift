#if canImport(WebGPU) && !os(WASI) && !os(Android)
@testable import AdaRender
import Foundation
import Testing

@MainActor
@Suite("WESL modules on native WebGPU")
struct WESLShaderModuleTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ADAENGINE_VALIDATE_WGSL"] == "1"))
    func nativeShaderModuleLinksAndReflectsBothBindingLayouts() throws {
        unsafe RenderEngine.configurations.preferredBackend = .webgpu
        try RenderEngine.setupRenderEngine()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ada wesl \(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
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
