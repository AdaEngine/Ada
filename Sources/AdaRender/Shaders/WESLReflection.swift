#if canImport(AdaWGSLCompiler) && !WASM && (SAGA_RENDER || !os(Android))
import AdaWGSLCompiler
import Foundation

enum WESLModuleError: LocalizedError {
    case requiresWebGPU
    case invalidEntryPoints
    case uniformLayoutUnavailable(group: Int, binding: Int)

    var errorDescription: String? {
        switch self {
        case .requiresWebGPU: "WESL shader modules require a native renderer with WGSL support."
        case .invalidEntryPoints: "A WESL shader module must have one entry point per active stage."
        case let .uniformLayoutUnavailable(group, binding):
            "Cannot adapt SAGA uniform layout at group \(group), binding \(binding); runtime reflection integration is incomplete."
        }
    }
}

extension ShaderModule {
    /// Reflection of one linked stage. Names and non-buffer resources come from the WGSL parser; buffer reachability and
    /// byte sizes are authoritative SAGA metadata, never host strides.
    static func weslStageReflection(
        artifact: WESLHostCompiler.Artifact,
        entry: WESLHostCompiler.EntryPoint,
        stage: ShaderStage
    ) throws -> ShaderReflectionData {
        var stageReflection = WGSLReflection.parse(from: artifact.wgsl, stage: stage, entryPoint: entry.name)
        let layouts = try WESLBackendCompiler.webGPUUniformBuffers(artifact, entryPoint: entry)
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
        return stageReflection
    }
}

extension ShaderGraphArchive.Fragment {
    /// Links `template` with the graph's WGSL on the host and captures its fragment stage for the web runtime.
    ///
    /// - Parameters:
    ///   - template: The template's name, such as `flat3d`; it is part of the fragment's identity.
    ///   - templateSource: The WESL text whose `// ADA_GRAPH_SOURCE_MARKER` line receives the graph.
    ///   - packageRoot: Where the template's `package::` imports resolve.
    ///   - macros: Feature names the template is linked with, besides `ADA_SHADER_GRAPH`.
    public static func bake(
        template: String,
        templateSource: String,
        program: ShaderGraphProgram,
        packageRoot: URL,
        macros: [String]
    ) throws -> ShaderGraphArchive.Fragment {
        guard program.format == .wgsl else { throw ShaderGraphDiagnostic(code: .invalidReference, nodeID: "\(template): the graph is not WGSL") }
        var features = Dictionary(uniqueKeysWithValues: macros.map { ($0, true) })
        features["ADA_SHADER_GRAPH"] = true
        let engineRoot = Bundle.adaModule.resourceURL?.appendingPathComponent("Shaders/WESL", isDirectory: true)
        let artifact = try WESLHostCompiler.compile(
            source: program.inserting(in: templateSource),
            packageRoot: packageRoot,
            features: features,
            dependencies: engineRoot.map { ["ada_engine": $0] } ?? [:]
        )
        guard let entry = artifact.entryPoints.first(where: { $0.stage == "fragment" }) else { throw WESLModuleError.invalidEntryPoints }
        return ShaderGraphArchive.Fragment(
            source: identity(template: template, graphSource: program.source),
            defines: Dictionary(uniqueKeysWithValues: macros.map { ($0, "1") }),
            entryPoint: entry.name,
            wgsl: artifact.wgsl,
            reflection: try ShaderModule.weslStageReflection(artifact: artifact, entry: entry, stage: .fragment)
        )
    }
}
#endif
