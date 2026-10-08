import Foundation

struct GLSLangShaderCompiler: ShaderDeviceCompilerEngine {
    func compile(
        spirvData: Data,
        entryPoint: String,
        stage: ShaderStage,
        defines _: [ShaderDefine]
    ) async throws -> DeviceCompiledShader {
        let spirvCompiler = try SpirvCompiler(spriv: spirvData, stage: stage, deviceLang: .deviceLang)
        spirvCompiler.renameEntryPoint(entryPoint)
        return try spirvCompiler.compile()
    }
}

extension ShaderLanguage {
    static let deviceLang: ShaderLanguage = {
        #if canImport(Metal)
            return .msl
        #else
            return .glsl
        #endif
    }()
}
