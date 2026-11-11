#if canImport(AdaWGSLCompiler) && !os(WASI) && !os(Android)
import AdaWGSLCompiler
import Foundation
import Testing

struct WESLBackendCompilerTests {
    @Test(arguments: ["fragment", "compute"])
    func webGPUUniformSizesUseShaderPaddingAndExcludeUnusedBindings(stage: String) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("main.wesl")
        let entry = stage == "fragment"
            ? "@fragment fn main() -> @location(0) vec4f { return vec4f(params.tint * params.gain, params.transform[0].x); }"
            : "@compute @workgroup_size(1) fn main() { result[0] = params.gain + params.transform[0].x; }"
        try """
        struct Params { tint: vec3f, gain: f32, transform: mat3x3f, }
        @group(2) @binding(5) var<uniform> params: Params;
        @group(0) @binding(0) var<uniform> unused: vec4f;
        @group(0) @binding(1) var<storage, read_write> result: array<f32>;
        \(entry)
        """.write(to: file, atomically: true, encoding: .utf8)
        let module = try WESLHostCompiler.compile(sourceFile: file, packageRoot: root)
        let entryPoint = try #require(module.entryPoints.first)
        let layouts = try WESLBackendCompiler.webGPUUniformBuffers(module, entryPoint: entryPoint)
        #expect(layouts.count == 1)
        let layout = try #require(layouts.first)
        #expect(layout.group == 2)
        #expect(layout.binding == 5)
        // mat3x3f has a 16-byte column stride; the shader block is 64 bytes, not 52.
        #expect(layout.minimumByteSize == 64)
    }

    @Test(arguments: ["f32", "vec3f", "mat3x3f", "array<vec4f, 3>"])
    func nonStructUniformRootsFollowHelperCalls(type: String) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("main.wesl")
        let access = type == "f32" ? "params" : (type == "vec3f" ? "params.x" : "params[0].x")
        try """
        @group(1) @binding(3) var<uniform> params: \(type);
        @group(0) @binding(0) var<uniform> unused: vec4f;
        fn readValue() -> f32 { return \(access); }
        fn shade() -> vec4f { return vec4f(readValue()); }
        @fragment fn main() -> @location(0) vec4f { return shade(); }
        """.write(to: file, atomically: true, encoding: .utf8)
        let module = try WESLHostCompiler.compile(sourceFile: file, packageRoot: root)
        let entry = try #require(module.entryPoints.first)
        let layouts = try WESLBackendCompiler.webGPUUniformBuffers(module, entryPoint: entry)
        #expect(layouts.count == 1)
        let layout = try #require(layouts.first)
        #expect(layout.group == 1)
        #expect(layout.binding == 3)
        let expected: UInt64 = type == "f32" ? 4 : (type == "vec3f" ? 12 : 48)
        #expect(layout.minimumByteSize == expected)
    }

    @Test
    func nativeStagesRetainEntryPointsAndMetalBindingRemapping() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = root.appendingPathComponent("Sources/AdaCorePipelines/Assets/Shaders/quad.wesl")
        let module = try WESLHostCompiler.compile(
            sourceFile: source,
            packageRoot: source.deletingLastPathComponent(),
            dependencies: ["ada_engine": root.appendingPathComponent("Sources/AdaRender/Assets/Shaders/WESL")]
        )
        let stages = try WESLBackendCompiler.compile(module, to: .msl)
        #expect(Set(stages.map(\.stage)) == ["vertex", "fragment"])
        let vertex = try #require(stages.first { $0.stage == "vertex" })
        guard case .render(let reflection) = vertex.reflection else {
            Issue.record("Vertex stage must retain render reflection")
            return
        }
        #expect(vertex.sourceEntryPoint == reflection.sourceEntryPoint)
        #expect(vertex.entryPoint == reflection.entryPoint)
        let metalSource = try #require(String(data: vertex.data, encoding: .utf8))
        #expect(metalSource.contains(reflection.entryPoint))
        let view = try #require(reflection.uniformBindings.first { $0.binding.group == 0 && $0.binding.binding == 2 })
        let slot = try #require(view.flatBindingIndex)
        #expect(view.minimumByteSize == 3 * 64)
        #expect(slot != view.binding.binding)
        #expect(metalSource.contains("[[buffer(\(slot))]]"))
    }
}
#endif
