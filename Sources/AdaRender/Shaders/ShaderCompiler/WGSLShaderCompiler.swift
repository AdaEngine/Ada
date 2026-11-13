#if canImport(WebGPU) && !WASM && !os(Android)
    import AdaWGSLCompiler
    import Foundation

    struct WGSLShaderCompiler: ShaderDeviceCompilerEngine {
        func compile(
            spirvData: Data,
            entryPoint: String,
            stage: ShaderStage,
            defines _: [ShaderDefine]
        ) async throws -> DeviceCompiledShader {
            let target: AdaWGSLCompiler.Stage
            switch stage {
            case .vertex: target = .vertex
            case .fragment: target = .fragment
            case .compute: target = .compute
            default: throw CompilationError.unsupportedStage(stage)
            }
            let source = try AdaWGSLCompiler.compile(spirv: spirvData, entryPoint: entryPoint, stage: target)
            let reflection = try SpirvCompiler(spriv: spirvData, stage: stage, deviceLang: .glsl).reflection()
            return DeviceCompiledShader(
                language: .wgsl,
                entryPoints: [.init(name: entryPoint, stage: stage)],
                reflection: reflection,
                source: source
            )
        }

        private enum CompilationError: LocalizedError {
            case unsupportedStage(ShaderStage)

            var errorDescription: String? {
                switch self {
                case .unsupportedStage(let stage): "Cannot compile the \(stage.rawValue) stage to WGSL."
                }
            }
        }
    }
#endif
