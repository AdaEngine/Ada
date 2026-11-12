import Foundation

#if canImport(AdaWGSLCompiler) && (SAGA_RENDER || (canImport(WebGPU) && !os(Android))) && !WASM
import AdaWGSLCompiler
import Foundation

extension ShaderModule {
    /// Link a local WESL module and create its WebGPU shader stages.
    public static func createWESL(
        from file: URL,
        packageRoot: URL? = nil,
        features: [String: Bool] = [:]
    ) throws -> ShaderModule {
        guard unsafe RenderEngine.shared.type.consumesWGSL else {
            throw WESLModuleError.requiresWebGPU
        }
        let engineRoot = Bundle.adaModule.resourceURL?.appendingPathComponent("Shaders/WESL", isDirectory: true)
        let artifact = try WESLHostCompiler.compile(
            sourceFile: file,
            packageRoot: packageRoot ?? file.deletingLastPathComponent(),
            features: features,
            dependencies: engineRoot.map { ["ada_engine": $0] } ?? [:]
        )
        return try createModule(from: artifact)
    }

    /// Link generated WESL source (for example a Shader Graph spliced into a template) and create its shader stages.
    ///
    /// - Parameter packageRoot: Where `package::` imports resolve; defaults to a private temporary directory.
    public static func createWESL(source: String, packageRoot: URL? = nil, features: [String: Bool] = [:]) throws -> ShaderModule {
        guard unsafe RenderEngine.shared.type.consumesWGSL else {
            throw WESLModuleError.requiresWebGPU
        }
        let engineRoot = Bundle.adaModule.resourceURL?.appendingPathComponent("Shaders/WESL", isDirectory: true)
        let artifact = try WESLHostCompiler.compile(
            source: source,
            packageRoot: packageRoot ?? FileManager.default.temporaryDirectory,
            features: features,
            dependencies: engineRoot.map { ["ada_engine": $0] } ?? [:]
        )
        return try createModule(from: artifact)
    }

    private static func createModule(from artifact: WESLHostCompiler.Artifact) throws -> ShaderModule {
        var shaders: [ShaderStage: Shader] = [:]
        var reflection = ShaderReflectionData()
        for entry in artifact.entryPoints {
            guard let stage = ShaderStage(rawValue: entry.stage), shaders[stage] == nil else {
                throw WESLModuleError.invalidEntryPoints
            }
            let stageReflection = try weslStageReflection(artifact: artifact, entry: entry, stage: stage)
            let shader = Shader(source: artifact.wgsl, entryPoint: entry.name, stage: stage, reflectionData: stageReflection)
            try shader.compile()
            shaders[stage] = shader
            reflection.merge(stageReflection)
        }
        guard !shaders.isEmpty else { throw WESLModuleError.invalidEntryPoints }
        return ShaderModule(shaders: shaders, reflectionData: reflection)
    }
}


extension ShaderGraphMaterial {
    /// Replaces only the fragment stage of `base`, like ``pipeline(base:device:variant:defines:fragmentTemplate:)``, from a
    /// WESL template whose `// ADA_GRAPH_SOURCE_MARKER` line receives the graph's WGSL.
    public func weslPipeline(
        base: RenderPipelineDescriptor,
        device: RenderDevice,
        variant: String,
        defines: [ShaderDefine] = [],
        packageRoot: URL? = nil,
        templateName: String,
        fragmentTemplate: () throws -> String
    ) throws -> RenderPipeline {
        let key = ShaderGraphPipelineStorage.Key(
            device: ObjectIdentifier(device),
            vertex: ObjectIdentifier(base.vertex),
            layout: base.vertexDescriptor,
            variant: "wesl:" + variant,
            defines: defines.sorted { $0.name < $1.name }
        )
        let pipeline = try pipelineStorage.resolve(key, device: device, cacheFailure: true) {
            let template = try fragmentTemplate()
            guard template.contains("// ADA_GRAPH_SOURCE_MARKER") else {
                throw ShaderGraphDiagnostic(code: .invalidReference)
            }
            let generated = try wgslProgram().inserting(in: template)
            var sharedKey = key
            sharedKey.source = generated
            return try ShaderGraphPipelineStorage.shared.resolve(sharedKey, device: device, cacheFailure: false) {
                var features = Dictionary(uniqueKeysWithValues: defines.map { ($0.name, true) })
                features["ADA_SHADER_GRAPH"] = true
                let module = try ShaderModule.createWESL(source: generated, packageRoot: packageRoot, features: features)
                guard let fragment = module.getShader(for: .fragment) else { throw ShaderGraphDiagnostic(code: .invalidReference) }
                var descriptor = base
                descriptor.fragment = fragment
                descriptor.debugName += " Shader Graph"
                return device.createRenderPipeline(from: descriptor)
            }
        }
        recordPipelinePreparation()
        return pipeline
    }
}
#else
extension ShaderGraphMaterial {
    #if WASM
    /// A WebAssembly build links no shaders: it uses the fragment baked from the same template and graph.
    public func weslPipeline(
        base: RenderPipelineDescriptor,
        device: RenderDevice,
        variant: String,
        defines: [ShaderDefine] = [],
        packageRoot: URL? = nil,
        templateName: String,
        fragmentTemplate: () throws -> String
    ) throws -> RenderPipeline {
        let key = ShaderGraphPipelineStorage.Key(
            device: ObjectIdentifier(device),
            vertex: ObjectIdentifier(base.vertex),
            layout: base.vertexDescriptor,
            variant: "wesl:" + variant,
            defines: defines.sorted { $0.name < $1.name }
        )
        let pipeline = try pipelineStorage.resolve(key, device: device, cacheFailure: true) {
            let identity = ShaderGraphArchive.Fragment.identity(template: templateName, graphSource: try wgslProgram().source)
            guard let artifact = ShaderGraphRuntimeLibrary.fragment(source: identity, defines: defines) else {
                throw ShaderGraphDiagnostic(code: .invalidReference, nodeID: "Missing baked Shader Graph variant: \(templateName) \(variant)")
            }
            let shader = Shader(source: artifact.wgsl, entryPoint: artifact.entryPoint, stage: .fragment, reflectionData: artifact.reflection)
            try shader.compile()
            var descriptor = base
            descriptor.fragment = shader
            descriptor.debugName += " Shader Graph"
            return device.createRenderPipeline(from: descriptor)
        }
        recordPipelinePreparation()
        return pipeline
    }
    #else
    /// WESL templates need the native WGSL pipeline; this renderer cannot link them.
    public func weslPipeline(
        base: RenderPipelineDescriptor,
        device: RenderDevice,
        variant: String,
        defines: [ShaderDefine] = [],
        packageRoot: URL? = nil,
        templateName: String,
        fragmentTemplate: () throws -> String
    ) throws -> RenderPipeline {
        throw ShaderGraphDiagnostic(code: .invalidReference, nodeID: "WESL shader graph templates")
    }
    #endif
}
#endif
