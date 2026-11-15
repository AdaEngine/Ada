//
//  ShaderCompiler.swift
//  AdaEngine
//
//  Created by v.prusakov on 3/10/23.
//

import Foundation

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

public struct ShaderDefine: Hashable, Sendable {
    public let name: String
    public let value: String

    public static func define(_ name: String, value: String = "1") -> Self {
        return Self(name: name, value: value)
    }
}

/// Compatibility API that diagnoses legacy shader inputs. Load WESL with ``ShaderModule``.
public final class ShaderCompiler {
    enum CompileError: LocalizedError {
        case weslRequired(String)

        var errorDescription: String? {
            switch self {
            case let .weslRequired(path):
                #if SAGA_WEBGPU
                return "Browser shader `\(path)` requires a prelinked WESL module. See the WESLShaders guide."
                #elseif WASM
                return "WASI shader `\(path)` requires a WESL module. See the WESLShaders guide."
                #else
                return "Shader `\(path)` requires a WESL module. See the WESLShaders guide."
                #endif
            }
        }
    }

    /// Collection of include search paths available for your shader source.
    public private(set) var includeSearchPaths: [ShaderSource.IncludeSearchPath] = []

    private var macros: [ShaderStage: [String: ShaderDefine]] = [:]
    private(set) var shaderSource: ShaderSource

    /// Create a new shader compiler from file source.
    public init(from fileUrl: URL) throws {
        throw CompileError.weslRequired(fileUrl.path)
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

    static func requireLegacySupport(for path: String) throws {
        throw CompileError.weslRequired(path)
    }

    /// Reports the migration diagnostic for an old shader module.
    public func compileShaderModule() throws -> ShaderModule {
        throw weslRequired(for: .max)
    }

    /// Reports the migration diagnostic for an old shader stage.
    public func compileShader(for stage: ShaderStage) throws -> Shader {
        throw weslRequired(for: stage)
    }

    private func weslRequired(for stage: ShaderStage) -> CompileError {
        .weslRequired(shaderSource.getSourceFileURL(for: stage)?.path ?? "inline shader")
    }
}
