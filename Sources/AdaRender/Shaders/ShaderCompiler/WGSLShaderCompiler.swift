#if canImport(WebGPU) && !WASM && !os(Android)
    import AdaUtils
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
            guard let toolExecutable = Bundle.adaModule.tintExecutable else {
                throw ShaderCompilerError.tintNotFound
            }

            let tempFileURL = try getTempFileURL(from: spirvData)

            defer { try? FileManager.default.removeItem(at: tempFileURL) }
            let process = try await run(
                .path(FilePath(toolExecutable.path())),
                arguments: [
                    tempFileURL.path(),
                    "--format",
                    "wgsl",
                    "--allow-non-uniform-derivatives",
                    "true",
                ],
                output: .string(limit: .max),
                error: .string(limit: 1024)
            )
            if let error = process.standardError, !error.isEmpty {
                throw ShaderCompilerError.failed(error)
            }

            guard process.terminationStatus.isSuccess else {
                throw ShaderCompilerError.failed("Tint terminated with status \(process.terminationStatus)")
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
                    return "Tint tool not found. Run python3 script/ensure_tint.py, or set TINT_EXECUTABLE to a verified SPIR-V reader / WGSL writer."
                case let .failed(message):
                    return "Failed to compile shader: \(message)"
                }
            }
        }
    }

    extension Bundle {
        var tintExecutable: URL? {
            TintToolchain.executable(bundle: self)
        }
    }
#endif
