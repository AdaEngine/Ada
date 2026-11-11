#if canImport(AdaWGSLCompiler) && canImport(WebGPU) && !WASM && !os(Android)
import AdaWGSLCompiler
import Foundation

extension ShaderModule {
    /// Link a local WESL module and create its WebGPU shader stages.
    public static func createWESL(
        from file: URL,
        packageRoot: URL? = nil,
        features: [String: Bool] = [:]
    ) throws -> ShaderModule {
        guard unsafe RenderEngine.shared.type.deviceLang == .wgsl else {
            throw WESLModuleError.requiresWebGPU
        }
        let engineRoot = Bundle.adaModule.resourceURL?.appendingPathComponent("Shaders/WESL", isDirectory: true)
        let artifact = try WESLHostCompiler.compile(
            sourceFile: file,
            packageRoot: packageRoot ?? file.deletingLastPathComponent(),
            features: features,
            dependencies: engineRoot.map { ["ada_engine": $0] } ?? [:]
        )
        var shaders: [ShaderStage: Shader] = [:]
        var reflection = ShaderReflectionData()
        for entry in artifact.entryPoints {
            guard let stage = ShaderStage(rawValue: entry.stage), shaders[stage] == nil else {
                throw WESLModuleError.invalidEntryPoints
            }
            let stageReflection = WGSLReflection.parse(from: artifact.wgsl, stage: stage, entryPoint: entry.name)
            let shader = Shader(source: artifact.wgsl, entryPoint: entry.name, stage: stage, reflectionData: stageReflection)
            try shader.compile()
            shaders[stage] = shader
            reflection.merge(stageReflection)
        }
        guard !shaders.isEmpty else { throw WESLModuleError.invalidEntryPoints }
        return ShaderModule(shaders: shaders, reflectionData: reflection)
    }
}

private enum WESLModuleError: LocalizedError {
    case requiresWebGPU
    case invalidEntryPoints

    var errorDescription: String? {
        switch self {
        case .requiresWebGPU: "WESL shader modules require the native WebGPU renderer."
        case .invalidEntryPoints: "A WESL shader module must have one entry point per active stage."
        }
    }
}
#endif
