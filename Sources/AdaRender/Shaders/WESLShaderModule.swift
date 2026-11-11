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
            var stageReflection = WGSLReflection.parse(from: artifact.wgsl, stage: stage, entryPoint: entry.name)
            let layouts = try WESLBackendCompiler.webGPUUniformBuffers(artifact, entryPoint: entry)
            // Transitional adapter: names and other resources still use the existing parser.
            // Buffer reachability and byte sizes are authoritative SAGA metadata, never host strides.
            let parsedSets = stageReflection.descriptorSets
            stageReflection.shaderBuffers.removeAll()
            for index in stageReflection.descriptorSets.indices {
                stageReflection.descriptorSets[index].uniformsBuffers.removeAll()
            }
            for layout in layouts {
                let group = Int(layout.group)
                let binding = Int(layout.binding)
                guard parsedSets.indices.contains(group),
                      let parsed = parsedSets[group].uniformsBuffers[binding],
                      let size = Int(exactly: layout.minimumByteSize), size > 0 else {
                    throw WESLModuleError.uniformLayoutUnavailable(group: group, binding: binding)
                }
                let buffer = ShaderResource.ShaderBuffer(
                    name: parsed.name,
                    size: size,
                    shaderStage: ShaderStageFlags(shaderStage: stage),
                    binding: binding,
                    resourceAccess: .read,
                    members: parsed.members
                )
                stageReflection.shaderBuffers[buffer.name] = buffer
                stageReflection.descriptorSets[group].uniformsBuffers[binding] = buffer
            }
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
    case uniformLayoutUnavailable(group: Int, binding: Int)

    var errorDescription: String? {
        switch self {
        case .requiresWebGPU: "WESL shader modules require the native WebGPU renderer."
        case .invalidEntryPoints: "A WESL shader module must have one entry point per active stage."
        case let .uniformLayoutUnavailable(group, binding):
            "Cannot adapt SAGA uniform layout at group \(group), binding \(binding); runtime reflection integration is incomplete."
        }
    }
}
#endif
