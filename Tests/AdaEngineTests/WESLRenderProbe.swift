#if os(macOS) || os(Windows) || os(Linux)
@testable import AdaRender
import Foundation
import Testing

#if canImport(Metal)
import AdaWGSLCompiler
import SAGAShaderIR
#endif

/// Runs the same WGSL probe through SAGA and the legacy Metal reference renderer.
struct WESLRenderProbe {
    let vertex: Shader
    let fragment: Shader

    #if canImport(Metal)
    private var metalFragment: RenderStageArtifact?
    #endif

    init(source: String) throws {
        let file = URL(fileURLWithPath: #filePath)
        let sourceRoot = ProcessInfo.processInfo.environment["ADAENGINE_SHADER_SOURCE_ROOT"].map { URL(fileURLWithPath: $0) }
            ?? file.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let packageRoot = sourceRoot.appendingPathComponent("Sources/AdaCorePipelines/Assets/Shaders")
        #if canImport(Metal)
        if unsafe RenderEngine.shared.type == .metal {
            let library = sourceRoot.appendingPathComponent("Sources/AdaRender/Assets/Shaders/WESL")
            let linked = try WESLHostCompiler.compile(
                source: source, packageRoot: packageRoot, dependencies: ["ada_engine": library]
            )
            let stages = try WESLBackendCompiler.compile(linked, to: .msl)
            let vertex = try #require(stages.first { $0.stage == "vertex" })
            let fragment = try #require(stages.first { $0.stage == "fragment" })
            let vertexShader = Shader(source: String(decoding: vertex.data, as: UTF8.self), entryPoint: vertex.entryPoint, stage: .vertex)
            let fragmentShader = Shader(source: String(decoding: fragment.data, as: UTF8.self), entryPoint: fragment.entryPoint, stage: .fragment)
            try vertexShader.compile()
            try fragmentShader.compile()
            self.vertex = vertexShader
            self.fragment = fragmentShader
            if case let .render(artifact) = fragment.reflection { metalFragment = artifact }
            return
        }
        #endif
        let module = try ShaderModule.createWESL(source: source, packageRoot: packageRoot)
        vertex = try #require(module.getShader(for: .vertex))
        fragment = try #require(module.getShader(for: .fragment))
    }

    func textureSlot(_ binding: UInt32) throws -> Int {
        #if canImport(Metal)
        if let metalFragment {
            return try Int(#require(metalFragment.sampledTextures.first { $0.binding.binding == binding }?.flatBindingIndex))
        }
        #endif
        return Int(binding)
    }

    func samplerSlot(_ binding: UInt32) throws -> Int {
        #if canImport(Metal)
        if let metalFragment {
            return try Int(#require(metalFragment.samplerBindings.first { $0.binding.binding == binding }?.flatBindingIndex))
        }
        #endif
        return Int(binding)
    }

    func uniformSlot(_ binding: UInt32) throws -> Int {
        #if canImport(Metal)
        if let metalFragment {
            return try Int(#require(metalFragment.uniformBindings.first { $0.binding.binding == binding }?.flatBindingIndex))
        }
        #endif
        return Int(binding)
    }

    static func complete(_ commands: any CommandBuffer) async {
        await withCheckedContinuation { continuation in
            commands.addCompletedHandler { continuation.resume() }
            commands.commit()
        }
    }
}
#endif
