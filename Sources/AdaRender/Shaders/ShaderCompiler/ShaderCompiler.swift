//
//  ShaderCompiler.swift
//  AdaEngine
//
//  Created by v.prusakov on 3/10/23.
//

import AdaUtils
import Foundation
import Logging
import SPIRV_Cross
import SPIRVCompiler
import Tracing

public struct DeviceCompiledShader: Codable {
    public struct EntryPoint: Codable {
        public let name: String
        public let stage: ShaderStage
    }

    public let language: ShaderLanguage
    public let entryPoints: [EntryPoint]
    public let reflection: ShaderReflectionData
    public let source: String
}

/// Compile shader for device specific language.
protocol ShaderDeviceCompilerEngine: Sendable {
    func compile(
        spirvData: Data,
        entryPoint: String,
        stage: ShaderStage,
        defines: [ShaderDefine]
    ) async throws -> DeviceCompiledShader
}

// TODO: Should we invert y-axis for vertex shader?
// TODO: We should remove cached shaders if their included content will change.

struct SpirvBinary {
    let stage: ShaderStage
    let data: Data
    let language: ShaderLanguage
    let entryPoint: String
    let version: Int
}

public struct ShaderDefine: Hashable, Sendable {
    public let name: String
    public let value: String

    public static func define(_ name: String, value: String = "1") -> Self {
        return Self(name: name, value: value)
    }
}

/// ShaderCompiler compile engine shader code to Shader objects (with SPIR-V binary).
public final class ShaderCompiler {
    enum CompileError: LocalizedError {
        case fileReadingFailed(String)
        case glslError(String)
        case failed(String)

        var errorDescription: String? {
            switch self {
            case let .fileReadingFailed(path):
                return "[ShaderCompiler] Failed to read file at path \(path)."
            case let .glslError(msg):
                return "[ShaderCompiler] GLSLang compile failed with error: \(msg)"
            case let .failed(msg):
                return "[ShaderCompiler] Failed: \(msg)."
            }
        }
    }

    /// Collection of include search paths available for your shader source.
    public private(set) var includeSearchPaths: [ShaderSource.IncludeSearchPath] = [
        .module(
            name: "AdaEngine",
            modulePath: Bundle.module.resourceURL?.appendingPathComponent("Shaders/Public") ?? Bundle.module.bundleURL
        )
    ]

    private var macros: [ShaderStage: [String: ShaderDefine]] = [:]
    private(set) var shaderSource: ShaderSource
    private let logger = Logger(label: "org.adaengine.shader-compiler")

    /// Create a new shader compiler from file source.
    public init(from fileUrl: URL) throws {
        self.shaderSource = try ShaderSource(from: fileUrl)
        self.includeSearchPaths.append(contentsOf: self.shaderSource.includeSearchPaths)
    }

    /// Create a new shader compiler from shader source.
    public init(shaderSource: ShaderSource) {
        self.shaderSource = shaderSource
        self.includeSearchPaths.append(contentsOf: shaderSource.includeSearchPaths)
    }

    public func addHeaderSearchPaths(_ paths: [ShaderSource.IncludeSearchPath]) {
        self.includeSearchPaths.append(contentsOf: paths)
    }

    public func setMacro(_ name: String, value: String, for shaderStage: ShaderStage) {
        self.macros[shaderStage, default: [:]][name] = ShaderDefine(name: name, value: value)
    }

    public func setShader(_ source: ShaderSource, for stage: ShaderStage) {
        guard let stageSource = source.getSource(for: stage) else {
            preconditionFailure("Shader source has no \(stage) stage.")
        }
        self.shaderSource.setSource(stageSource, for: stage)
    }

    /// Compile all shader sources to shader module.
    public func compileShaderModule() throws -> ShaderModule {
        var shaders: [ShaderStage: Shader] = [:]

        var reflectionData = ShaderReflectionData()

        for stage in self.shaderSource.stages {
            let shader = try self.compileShader(for: stage)
            shaders[stage] = shader
            // Merge
            reflectionData.merge(shader.reflectionData)
        }

        return ShaderModule(shaders: shaders, reflectionData: reflectionData)
    }

    /// Compile shader by specific shader stage.
    /// - Returns: Compiled Shader object.
    /// - Throws: Error if something went wrong on compilation to SPIR-V.
    public func compileShader(for stage: ShaderStage) throws -> Shader {
        let span = AdaTrace.startSpan(lazyName: "ShaderCompiler.compileShader.\(stage.rawValue)")
        defer {
            span.end()
        }
        let version = self.getShaderVersion(for: stage)
        let hasChanges = ShaderCache.hasChanges(for: self.shaderSource, stage: stage, version: version)
        if !hasChanges {
            if let deviceCompiledShader = ShaderCache.getCachedDeviceCompiledShader(for: self.shaderSource, stage: stage) {
                return try Shader.make(from: deviceCompiledShader, entryPoint: deviceCompiledShader.entryPoints.first?.name ?? "", stage: stage)
            }
        }

        #if WASM
            if unsafe RenderEngine.shared.type == .headless {
                let binary = try self.compileSpirvBin(for: stage, ignoreCache: hasChanges)
                let shader = try Shader(spirv: binary, compiler: self)
                try shader.compile()
                return shader
            }

            #if canImport(WebGPU)
                if unsafe RenderEngine.shared.type.deviceLang == .wgsl {
                    guard let wgslSource = self.shaderSource.getWGSLSource(for: stage) else {
                        let sourcePath = self.shaderSource.getSourceFileURL(for: stage)?.path ?? "<unknown>"
                        throw CompileError.failed("WGSL sidecar for `\(stage.rawValue)` shader not found next to \(sourcePath)")
                    }

                    let binary = try self.compileSpirvBin(for: stage, ignoreCache: hasChanges)
                    let spirvCompiler = try SpirvCompiler(spriv: binary.data, stage: stage, deviceLang: .glsl)
                    let shader = Shader(
                        source: wgslSource,
                        entryPoint: self.shaderSource.getEntryPoint(for: stage),
                        stage: stage,
                        reflectionData: spirvCompiler.reflection()
                    )
                    try shader.compile()
                    return shader
                }
            #endif
        #endif

        let binary = try self.compileSpirvBin(for: stage, ignoreCache: hasChanges)

        #if canImport(WebGPU)
            if unsafe RenderEngine.shared.type.deviceLang == .wgsl {
                let shader = try Shader(spirv: binary, compiler: self)
                let spirvCompiler = try SpirvCompiler(spriv: binary.data, stage: stage, deviceLang: .glsl)
                shader.reflectionData = spirvCompiler.reflection()
                try shader.compile()
                do {
                    try ShaderCache.saveReflection(shader.reflectionData, for: self.shaderSource, stage: stage)
                } catch {
                    self.logger.warning("Failed to save reflection: \(error)")
                }
                return shader
            }
        #endif

        #if WASM
            throw CompileError.failed("Synchronous device shader compilation is unavailable on WebAssembly")
        #else
            let deviceShaderCompiler = self.makeDeviceShaderCompiler()
            let compiledShaderData = try UnsafeTask { [deviceShaderCompiler, macros] in
                try await deviceShaderCompiler.compile(
                    spirvData: binary.data,
                    entryPoint: binary.entryPoint,
                    stage: stage,
                    defines: Array(macros[stage, default: [:]].values)
                )
            }
            .get()
            do {
                try ShaderCache.saveDeviceCompiledShader(compiledShaderData, for: self.shaderSource, stage: stage)
            } catch {
                self.logger.warning("Failed to save device compiled shader to cache: \(error)")
            }
            let shader = try Shader.make(
                from: compiledShaderData,
                entryPoint: binary.entryPoint,
                stage: stage
            )
            if let reflection = ShaderCache.getReflection(for: self.shaderSource, stage: stage) {
                shader.reflectionData = reflection
            } else {
                try ShaderCache.saveReflection(shader.reflectionData, for: self.shaderSource, stage: stage)
            }

            return shader
        #endif
    }

    // MARK: - Private

    // Get SPIRV from cache or compile new if something change in file.
    internal func compileSpirvBin(for stage: ShaderStage, ignoreCache: Bool = false) throws -> SpirvBinary {
        let version = self.getShaderVersion(for: stage)

        if !ignoreCache, !ShaderCache.hasChanges(for: self.shaderSource, stage: stage, version: version) {
            let entryPoint = self.shaderSource.getEntryPoint(for: stage)
            if let binary = ShaderCache.getCachedShader(
                for: self.shaderSource,
                stage: stage,
                version: version,
                entryPoint: entryPoint
            ) {
                return binary
            }
        }

        guard let code = self.shaderSource.getSource(for: stage) else {
            throw CompileError.failed("Sources for stage `\(stage.rawValue)` not found")
        }

        let processedCode = try ShaderIncluder.processIncludes(in: code, includeSearchPath: self.includeSearchPaths)
        let (entryPoint, ppCode) = try ShaderUtils.dropEntryPoint(from: processedCode)
        let spirv = try self.compileCode(ppCode, entryPoint: entryPoint, stage: stage)
        do {
            try ShaderCache.save(spirv, source: self.shaderSource, stage: stage, version: version)
        } catch {
            self.logger.warning("Failed to save spirv to cache: \(error)")
        }

        return spirv
    }

    internal func compileCode(_ code: String, entryPoint: String, stage: ShaderStage) throws -> SpirvBinary {
        let span = AdaTrace.startSpan(lazyName: "ShaderCompiler.compileCode.\(stage.rawValue)")
        defer {
            span.end()
        }
        guard glslang_initialize() != 0 else {
            throw CompileError.glslError("Can't create glslang process.")
        }

        defer {
            glslang_finalize()
        }

        var error: UnsafePointer<CChar>?
        let defines = self.getDefines(for: stage)
        let binary = unsafe defines.withCString { definesPtr in
            let options = unsafe spirv_options(preamble: definesPtr)

            return unsafe code.withCString { sourcePtr in
                unsafe compile_shader_glsl(
                    sourcePtr, /* source */
                    stage.toShaderCompiler, /* stage */
                    options, /* options */
                    &error /* output error */
                )
            }
        }

        if let error = unsafe error {
            let message = unsafe String(cString: error, encoding: .utf8) ?? "Failed to compile"
            throw CompileError.glslError(message)
        }

        guard let bytes = unsafe binary.bytes else {
            throw CompileError.glslError("Shader compiler returned no binary data.")
        }
        let data = unsafe Data(
            bytesNoCopy: UnsafeMutableRawPointer(mutating: bytes),
            count: Int(binary.length),
            deallocator: .free
        )

        return SpirvBinary(
            stage: stage,
            data: data,
            language: self.shaderSource.language,
            entryPoint: entryPoint,
            version: self.getShaderVersion(for: stage)
        )
    }

    private func getShaderVersion(for stage: ShaderStage) -> Int {
        return self.getDefines(for: stage).uniqueHashValue
    }

    private func getDefines(for stage: ShaderStage) -> String {
        guard let macros = self.macros[stage] else {
            return ""
        }

        var defines = ""

        for macro in macros.values {
            defines.append("#define \(macro.name.uppercased()) \(macro.value)\n")
        }

        return defines
    }
}

extension ShaderCompiler {
    func makeDeviceShaderCompiler() -> ShaderDeviceCompilerEngine {
        switch unsafe RenderEngine.shared.type.deviceLang {
        #if canImport(WebGPU) && !WASM
            case .wgsl:
                return WGSLShaderCompiler()
        #endif
        default:
            return GLSLangShaderCompiler()
        }
    }
}

extension ShaderStage {
    var toShaderCompiler: shaderc_stage {
        switch self {
        case .compute:
            return SHADER_STAGE_COMPUTE
        case .fragment:
            return SHADER_STAGE_FRAGMENT
        case .vertex:
            return SHADER_STAGE_VERTEX
        case .tesselationControl:
            return SHADER_STAGE_TESSELATION_CONTROL
        case .tesselationEvaluation:
            return SHADER_STAGE_TESSELATION_EVALUATION
        case .max:
            return SHADER_STAGE_MAX
        }
    }
}
