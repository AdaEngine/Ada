import Foundation
import SAGACompiler
import SAGAFrontends
import SAGAShaderIR

public enum AdaWGSLCompiler {
    public enum Stage: Sendable {
        case vertex, fragment, compute
    }

    public static func compile(spirv: Data, entryPoint: String, stage: Stage) throws -> String {
        let wordSize = MemoryLayout<UInt32>.size
        guard !spirv.isEmpty, spirv.count.isMultiple(of: wordSize) else {
            throw CompilationError.invalidSPIRV
        }
        let words = unsafe spirv.withUnsafeBytes { bytes in
            stride(from: 0, to: bytes.count, by: wordSize).map { offset in
                UInt32(littleEndian: unsafe bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
            }
        }
        // AdaEngine's glslang input is already in the engine's WebGPU clip space.
        let compiler = IndependentShaderCompiler(
            spirvOptions: .init(adjustCoordinateSpace: false, allowNonUniformDerivatives: true)
        )
        let input = ShaderInput.spirv(words)
        let artifact: ShaderArtifact
        let generatedEntryPoint: String
        switch stage {
        case .vertex, .fragment:
            let result = try compiler.compileWebGPURenderStage(input, entryPoint: "main")
            artifact = result.artifact
            generatedEntryPoint = result.entryPoint
        case .compute:
            let result = try compiler.compileWebGPUCompute(input, entryPoint: "main")
            artifact = result.artifact
            generatedEntryPoint = result.entryPoint
        }

        guard case .text(.wgsl, let source) = artifact else {
            throw CompilationError.invalidOutput
        }
        return source.replacingOccurrences(of: "fn \(generatedEntryPoint)(", with: "fn \(entryPoint)(")
    }

    private enum CompilationError: LocalizedError {
        case invalidSPIRV
        case invalidOutput

        var errorDescription: String? {
            switch self {
            case .invalidSPIRV: "Invalid SPIR-V word data."
            case .invalidOutput: "SAGACompiler did not emit WGSL source."
            }
        }
    }
}
