//
//  Shader.swift
//  AdaEngine
//
//  Created by v.prusakov on 11/4/21.
//

import AdaAssets
import AdaUtils
import Foundation

// TODO: Need store binaries using MTLBinaryArchive for metal

/// Contains native compiled GPU device shader.
public protocol CompiledShader: AnyObject {}

// TODO: (Vlad) Add reflection data
// TODO: (Vlad) I'm not sure that we should save compiled shader inside `Shader` object.

/// Contains shader data.
public final class Shader: Asset, @unchecked Sendable {
    public enum Source: Hashable {
        /// Contains SPIRV data
        case spirv(Data)
        /// Contains source code
        case code(String)
    }

    /// Return compiled shader which used for specific render backend.
    public internal(set) var compiledShader: CompiledShader!

    /// Contains information about shader stage.
    public let stage: ShaderStage

    public private(set) var source: Source
    public private(set) var entryPoint: String

    public internal(set) var reflectionData: ShaderReflectionData = ShaderReflectionData()

    public init(
        source: String,
        entryPoint: String,
        stage: ShaderStage,
        reflectionData: ShaderReflectionData = ShaderReflectionData()
    ) {
        self.source = .code(source)
        self.entryPoint = entryPoint
        self.stage = stage
        self.compiledShader = nil
        self.reflectionData = reflectionData
    }

    /// Sets a legacy source macro. Select WESL features when linking the module.
    public func setMacro(_ name: String, value: String) {
    }

    public func compile() throws {
        self.compiledShader = unsafe try RenderEngine.shared.renderDevice.compileShader(from: self)
    }

    /// Recreates the device shader from its linked stage.
    public func recompile() throws {
        try self.compile()
    }

    // MARK: Shader

    public var assetMetaInfo: AssetMetaInfo?

    public init(from decoder: AssetDecoder) throws {
        let filePath = decoder.assetMeta.filePath
        throw ShaderCompiler.CompileError.weslRequired(filePath.path)
    }

    public func encodeContents(with _: AssetEncoder) throws {
        fatalErrorMethodNotImplemented()
    }

    public static func extensions() -> [String] {
        ["mat"]
    }
}

// MARK: UniqueHashable

extension Shader: UniqueHashable {
    public static func == (lhs: Shader, rhs: Shader) -> Bool {
        lhs.source == rhs.source && lhs.stage == rhs.stage && lhs.assetPath == rhs.assetPath
    }

    public func hash(into hasher: inout FNVHasher) {
        hasher.combine(self.assetPath)
    }
}

extension RenderBackendType {
    /// Whether the renderer consumes linked WGSL stages.
    var consumesWGSL: Bool {
        self == .webgpu || self == .saga
    }
}
