#if canImport(WebGPU) && !WASM && !os(Android)
    import AdaUtils
    import Foundation
    import Logging
    import Subprocess
    import WebGPU
    #if os(Windows)
        import WinSDK
    #endif
    #if canImport(System)
        @unsafe @preconcurrency import System
    #else
        @unsafe @preconcurrency import SystemPackage
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
            var options = PlatformOptions()
            #if os(Windows)
            // Studio and exported games have no parent console. Without this
            // flag Windows creates a flashing console for every Tint invocation.
            options.windowStyle = .hidden
            options.preSpawnProcessConfigurator = { flags, _ in
                flags |= DWORD(CREATE_NO_WINDOW)
            }
            #endif
            let process = try await run(
                .path(FilePath(toolExecutable.path)),
                arguments: [
                    tempFileURL.path,
                    "--format",
                    "wgsl",
                    "--allow-non-uniform-derivatives",
                    "true",
                ],
                platformOptions: options,
                output: .string(limit: .max),
                error: .string(limit: 1024)
            )
            guard process.terminationStatus.isSuccess else {
                throw ShaderCompilerError.failed(process.standardError ?? "Tint terminated with status \(process.terminationStatus)")
            }
            if let warnings = process.standardError, !warnings.isEmpty {
                Logger(label: "org.adaengine.wgsl").warning("Tint: \(warnings)")
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
