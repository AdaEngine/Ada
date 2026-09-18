#if canImport(WebGPU) && !WASM
    import Foundation
    import Subprocess
    import WebGPU
    #if canImport(System)
        @unsafe @preconcurrency import System
    #else
        @preconcurrency import SystemPackage
    #endif

    struct WGSLShaderCompiler: ShaderDeviceCompilerEngine {
        func compile(
            spirvData: Data,
            entryPoint: String,
            stage: ShaderStage,
            defines _: [ShaderDefine]
        ) async throws -> DeviceCompiledShader {
            guard let toolExecutable = Bundle.module.tintExecutable else {
                throw ShaderCompilerError.tintNotFound
            }

            let tempFileURL = try getTempFileURL(from: spirvData)

            let process = try await run(
                .path(FilePath(toolExecutable.path())),
                arguments: [
                    tempFileURL.path(),
                    "--format",
                    "wgsl",
                ],
                output: .string(limit: .max),
                error: .string(limit: 1024)
            )
            try FileManager.default.removeItem(at: tempFileURL)

            if let error = process.standardError, !error.isEmpty {
                throw ShaderCompilerError.failed(error)
            }

            if case let .unhandledException(status) = process.terminationStatus, status != 0 {
                throw ShaderCompilerError.failed("Process terminated with status \(status)")
            }

            guard let source = process.standardOutput else {
                throw ShaderCompilerError.failed("No output")
            }
            let spirvCompiler = try SpirvCompiler(spriv: spirvData, stage: stage, deviceLang: .glsl)
            let processedSource = renameEntryPoint(in: source, entryPoint: entryPoint)
            return DeviceCompiledShader(
                language: .wgsl,
                entryPoints: [
                    .init(name: entryPoint, stage: stage)
                ],
                reflection: spirvCompiler.reflection(),
                source: processedSource
            )
        }

        private func getTempFileURL(from sprivData: Data) throws -> URL {
            let tempDirectory = FileManager.default.temporaryDirectory
            let fileName = UUID().uuidString + ".spv"
            let fileURL = tempDirectory.appendingPathComponent(fileName)
            try sprivData.write(to: fileURL)
            return fileURL
        }

        // TODO: (Vlad) This is a temporary solution to rename the entry point. We need to find a better way to do this.
        private func renameEntryPoint(in source: String, entryPoint: String) -> String {
            return source.replacingOccurrences(of: "fn main(", with: "fn \(entryPoint)(")
        }

        enum ShaderCompilerError: LocalizedError {
            case tintNotFound
            case failed(String)

            var errorDescription: String? {
                switch self {
                case .tintNotFound:
                    return "Tint tool not found"
                case let .failed(message):
                    return "Failed to compile shader: \(message)"
                }
            }
        }
    }

    extension Bundle {
        var tintExecutable: URL? {
            #if os(Windows)
                return url(forResource: "tint", withExtension: "exe")
            #else
                return url(forResource: "tint", withExtension: "")
            #endif
        }
    }
#endif
