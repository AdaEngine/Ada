//
//  ShaderSource.swift
//  AdaEngine
//
//  Created by v.prusakov on 3/13/23.
//

import AdaAssets
import AdaUtils
import Foundation

public enum ShaderLanguage: String, Sendable, Codable {
    /// OpenGL/WebGL-style GLSL.
    case glsl

    /// High Level Shading Language (DirectX)
    case hlsl

    /// Metal Shading Language
    case msl

    /// WebGPU Shading Language
    case wgsl
}

public enum ShaderStage: String, Hashable, Codable, Sendable {
    case vertex
    case fragment
    case compute
    case tesselationControl
    case tesselationEvaluation
    case max
}

/// Contains collection of shader sources splitted by stages.
public final class ShaderSource: Asset, @unchecked Sendable {
    enum Error: LocalizedError {
        case failedToRead(String)
        case message(String)

        var errorDescription: String? {
            switch self {
            case let .failedToRead(path):
                return "[ShaderSource] Failed to read file at path \(path)."
            case let .message(message):
                return "[ShaderSource] \(message)"
            }
        }
    }

    /// Provide search path for includes in your shader.
    public enum IncludeSearchPath: Equatable, Codable {
        case _local(URL)
        // ModuleName, Path to Module Search Path
        case _module(String, URL)
    }

    /// Defined language of shader sources.
    public private(set) var language: ShaderLanguage = .glsl

    private var sources: [ShaderStage: String] = [:]
    private var sourceFileURLs: [ShaderStage: URL] = [:]

    /// Contains include search paths for shaders.
    public var includeSearchPaths: [ShaderSource.IncludeSearchPath] = []

    /// Contains url to shader sources if ShaderSource was created from file.
    var fileURL: URL?

    /// Create a shader source from a file. Automatic detect language and split to stages (for GLSL only).
    public init(from fileURL: URL) throws {
        let language = ShaderUtils.shaderLang(from: fileURL.pathExtension)
        if language == .glsl {
            try ShaderCompiler.requireLegacySupport(for: fileURL.path)
        }
        guard let data = FileSystem.current.readFile(at: fileURL) else {
            throw Error.failedToRead(fileURL.path)
        }

        self.fileURL = fileURL

        let sourceCode = String(bytes: data, encoding: .utf8) ?? ""
        self.language = language
        self.includeSearchPaths = [.local(fileURL.deletingLastPathComponent())]

        self.sources = [.max: sourceCode]
        self.sourceFileURLs = [.max: fileURL]
    }

    /// Create a shader source from raw string.
    /// - Parameter source: A source code of shader.
    /// - Parameter lang: Set the source code lang. GLSL by default.
    /// - Parameter includeSearchPath: If you source needs your own includes, provide search path for them. Empty by default.
    public init(
        source: String,
        lang: ShaderLanguage = .glsl,
        includeSearchPaths: [ShaderSource.IncludeSearchPath] = []
    ) throws {
        self.includeSearchPaths = includeSearchPaths
        self.language = lang

        if lang == .glsl {
            try ShaderCompiler.requireLegacySupport(for: "inline shader")
        }
        self.sources = [.max: source]
    }

    /// Create an empty shader sources
    public init() {}

    /// Set new shader source code for specific stage.
    public func setSource(_ source: String, for stage: ShaderStage, fileURL: URL? = nil) {
        self.sources[stage] = source
        self.sourceFileURLs[stage] = fileURL
    }

    /// Get source code for specific stage.
    /// - Returns: Raw string code or nil if source code not saved for specific stage.
    public func getSource(for stage: ShaderStage) -> String? {
        return self.sources[stage]
    }

    /// Get entry point for specific code.
    public func getEntryPoint(for stage: ShaderStage) -> String {
        return "main"
    }

    /// Return collection of stages available in this shader source.
    public var stages: [ShaderStage] {
        return Array(self.sources.keys)
    }

    func getSourceFileURL(for stage: ShaderStage) -> URL? {
        return self.sourceFileURLs[stage] ?? self.fileURL
    }

    // MARK: - Asset

    public var assetMetaInfo: AssetMetaInfo?

    public init(from assetDecoder: AssetDecoder) throws {
        let fileURL = assetDecoder.assetMeta.filePath
        let language = ShaderUtils.shaderLang(from: fileURL.pathExtension)
        if language == .glsl {
            try ShaderCompiler.requireLegacySupport(for: fileURL.path)
        }
        self.fileURL = fileURL

        guard let data = FileSystem.current.readFile(at: fileURL) else {
            throw Error.failedToRead(fileURL.path)
        }

        let sourceCode = String(bytes: data, encoding: .utf8) ?? ""
        self.language = language
        self.includeSearchPaths = [.local(fileURL.deletingLastPathComponent())]

        self.sources = [.max: sourceCode]
        self.sourceFileURLs = [.max: fileURL]
    }

    public func encodeContents(with _: AssetEncoder) throws {
        fatalErrorMethodNotImplemented()
    }


    public static func extensions() -> [String] {
        ["mat"]
    }
}

extension ShaderSource.IncludeSearchPath {
    /// Create search path for ""-style include.
    ///
    /// Example:
    /// ```
    /// #include "PATH_TO_FILE"
    /// ```
    public static func local(_ fileDirectory: URL) -> Self {
        return ._local(fileDirectory)
    }

    /// Create search path for <>-style include.
    ///
    /// Example:
    /// ```
    /// #include <MODULE_NAME/PATH_TO_FILE>
    /// ```
    public static func module(name: String, modulePath: URL) -> Self {
        return ._module(name, modulePath)
    }
}

// MARK: - UniqueHashable

extension ShaderSource: UniqueHashable {
    public static func == (lhs: ShaderSource, rhs: ShaderSource) -> Bool {
        lhs.includeSearchPaths == rhs.includeSearchPaths && lhs.language == rhs.language && lhs.sources == rhs.sources
    }

    public func hash(into hasher: inout FNVHasher) {
        for (stage, source) in self.sources {
            hasher.combine(stage.rawValue)
            hasher.combine(source)
        }

        for include in includeSearchPaths {
            switch include {
            case let ._local(url):
                hasher.combine(url.path)
            case let ._module(moduleName, url):
                hasher.combine(moduleName)
                hasher.combine(url.path)
            }
        }
    }
}

extension ShaderSource: Hashable {
    public func hash(into hasher: inout Hasher) {
        for (stage, source) in self.sources {
            hasher.combine(stage.rawValue)
            hasher.combine(source)
        }

        for include in includeSearchPaths {
            switch include {
            case let ._local(url):
                hasher.combine(url.path)
            case let ._module(moduleName, url):
                hasher.combine(moduleName)
                hasher.combine(url.path)
            }
        }
    }
}
