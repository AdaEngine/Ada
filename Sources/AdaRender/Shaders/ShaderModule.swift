//
//  ShaderModule.swift
//  AdaEngine
//
//  Created by v.prusakov on 3/14/23.
//

import AdaAssets
import AdaUtils
import Foundation

/// A shader module that stores shaders.
public final class ShaderModule: Asset, @unchecked Sendable {
    /// The shaders in the shader module.
    private var shaders: [ShaderStage: Shader] = [:]

    /// The reflection data of the shader module.
    var reflectionData: ShaderReflectionData

    /// Initialize a new shader module.
    ///
    /// - Parameters:
    ///   - shaders: The shaders in the shader module.
    init(shaders: [ShaderStage: Shader] = [:], reflectionData: ShaderReflectionData) {
        self.shaders = shaders
        self.reflectionData = reflectionData
    }

    /// Add a shader to the shader module.
    ///
    /// - Parameters:
    ///   - shader: The shader to add.
    ///   - stage: The stage of the shader.
    public func addShader(_ shader: Shader, for stage: ShaderStage) {
        self.shaders[stage] = shader
    }

    /// Get a shader from the shader module.
    ///
    /// - Parameter stage: The stage of the shader.
    /// - Returns: The shader.
    public func getShader(for stage: ShaderStage) -> Shader? {
        return self.shaders[stage]
    }

    /// The stages of the shader module.
    public var stages: [ShaderStage] {
        return Array(self.shaders.keys)
    }

    /// Set a macro for a shader stage.
    ///
    /// - Parameters:
    ///   - name: The name of the macro.
    ///   - value: The value of the macro.
    ///   - shaderStage: The stage of the shader.
    public func setMacro(_ name: String, value: String, for shaderStage: ShaderStage) {
        self.shaders[shaderStage]?.setMacro(name, value: value)
    }

    /// The asset meta info of the shader module.
    public var assetMetaInfo: AssetMetaInfo?

    /// Initialize a new shader module from a decoder.
    ///
    /// - Parameter decoder: The decoder to initialize the shader module from.
    /// - Throws: An error if the shader module cannot be initialized from the decoder.
    public init(from decoder: AssetDecoder) throws {
        let filePath = decoder.assetMeta.filePath
        let module = try Self.create(from: filePath)
        self.shaders = module.shaders
        self.reflectionData = module.reflectionData
    }

    /// Encode the shader module to an encoder.
    ///
    /// - Parameter encoder: The encoder to encode the shader module to.
    /// - Throws: An error if the shader module cannot be encoded to the encoder.
    public func encodeContents(with _: AssetEncoder) throws {
        throw AssetError.message("ShaderModule encoding is unsupported.")
    }

    /// The extensions of the shader module.
    public static func extensions() -> [String] {
        ["mat"]
    }
}

extension ShaderModule {
    /// Whether the active renderer can load bundled WESL shader modules.
    public static var supportsBundledWESL: Bool {
        #if (WASM && WEBGPU_ENABLED) || (SAGA_RENDER && canImport(AdaWGSLCompiler))
            return unsafe RenderEngine.shared.type.consumesWGSL
        #else
            return false
        #endif
    }

    /// Create a new shader module from a file url.
    ///
    /// - Parameter fileUrl: The file url to create the shader module from.
    /// - Returns: The shader module.
    public static func create(from fileUrl: URL) throws -> ShaderModule {
        #if canImport(AdaWGSLCompiler) && SAGA_RENDER && !WASM
            if fileUrl.pathExtension.lowercased() == "wesl" {
                return try createWESL(from: fileUrl)
            }
        #endif
        #if WASM && WEBGPU_ENABLED
            if fileUrl.pathExtension.lowercased() == "wesl" {
                guard let module = try createWGSLModuleIfAvailable(at: fileUrl, reflectActiveBindings: true) else {
                    throw ShaderModuleError.notFound(fileUrl.path + ".{vert,frag}.wgsl")
                }
                return module
            }
        #endif
        return try ShaderCompiler(from: fileUrl).compileShaderModule()
    }

    /// Compile a bundled shader with every name in `defines` set to `1` in the vertex and fragment stages.
    ///
    /// The variant is compiled from the file's text rather than the file, so it bypasses the on-disk shader cache, whose
    /// entries are keyed by file and stage and would mix up variants of one file. Callers should keep the result.
    /// WebAssembly loads shipped variants for terrain and wireframe, and uses the plain module for other optional features.
    public static func createBundled(at path: String, from bundle: Bundle, defines: [String]) throws -> ShaderModule {
        guard !defines.isEmpty else {
            return try loadBundled(at: path, from: bundle).asset
        }
        if path.hasSuffix(".wesl") {
            guard let resourceURL = bundle.resourceURL else {
                throw ShaderModuleError.notFound(path)
            }
            let url = resourceURL.appendingPathComponent(path)
            let names = Set(defines).sorted()
            #if WASM && WEBGPU_ENABLED
                let baseURL = url.appendingPathExtension(names.joined(separator: "."))
                guard let module = try createWGSLModuleIfAvailable(at: baseURL, reflectActiveBindings: true) else {
                    throw ShaderModuleError.notFound(baseURL.path)
                }
                return module
            #elseif canImport(AdaWGSLCompiler) && SAGA_RENDER
                let features = Dictionary(uniqueKeysWithValues: names.map { ($0, true) })
                return try createWESL(from: url, features: features)
            #else
                throw ShaderModuleError.notFound(path)
            #endif
        }
        #if WASM
            #if WEBGPU_ENABLED
                if path == "Shaders/flat3d.glsl" {
                    let variants = Set(defines).intersection(["ADA_TERRAIN", "ADA_WIREFRAME"]).sorted()
                    if !variants.isEmpty, let resourceURL = bundle.resourceURL {
                        let url = resourceURL.appendingPathComponent(path)
                        let baseURL = url.deletingPathExtension().appendingPathExtension(variants.joined(separator: "."))
                        guard let module = try createWGSLModuleIfAvailable(at: baseURL) else { throw ShaderModuleError.notFound(baseURL.path) }
                        return module
                    }
                }
            #endif
            return try loadBundled(at: path, from: bundle).asset
        #else
            guard let resourceURL = bundle.resourceURL else {
                throw ShaderModuleError.notFound(path)
            }
            let url = resourceURL.appendingPathComponent(path)
            guard let data = FileSystem.current.readFile(at: url) else {
                throw ShaderModuleError.notFound(path)
            }
            let source = try ShaderSource(
                source: String(bytes: data, encoding: .utf8) ?? "",
                includeSearchPaths: [.local(url.deletingLastPathComponent())]
            )
            let compiler = ShaderCompiler(shaderSource: source)
            for name in defines {
                for stage in [ShaderStage.vertex, .fragment] {
                    compiler.setMacro(name, value: "1", for: stage)
                }
            }
            return try compiler.compileShaderModule()
        #endif
    }

    /// Load a bundled shader module without the async asset pipeline.
    ///
    /// Browser startup still constructs render pipelines synchronously, so shader
    /// resources need a sync path that does not block on `UnsafeTask`.
    public static func loadBundled(at path: String, from bundle: Bundle) throws -> AssetHandle<ShaderModule> {
        guard let resourceURL = bundle.resourceURL else {
            throw ShaderModuleError.notFound(path)
        }

        let url = resourceURL.appendingPathComponent(path)
        guard FileSystem.current.itemExists(at: url) else {
            throw ShaderModuleError.notFound(path)
        }

        #if WASM && WEBGPU_ENABLED
            if path.hasSuffix(".glsl"), let wgslModule = try createWGSLModuleIfAvailable(at: url.deletingPathExtension()) {
                return AssetHandle(wgslModule)
            }
        #endif

        return AssetHandle(try create(from: url))
    }
}

private enum ShaderModuleError: LocalizedError {
    case notFound(String)

    var errorDescription: String? {
        switch self {
        case let .notFound(path):
            "Shader module not found at \(path)."
        }
    }
}

#if WASM && WEBGPU_ENABLED
    extension ShaderModule {
        private static func createWGSLModuleIfAvailable(
            at baseURL: URL, reflectActiveBindings: Bool = false
        ) throws -> ShaderModule? {
            let vertexURL = baseURL.appendingPathExtension("vert.wgsl")
            let fragmentURL = baseURL.appendingPathExtension("frag.wgsl")

            guard
                FileSystem.current.itemExists(at: vertexURL),
                FileSystem.current.itemExists(at: fragmentURL),
                let vertexData = FileSystem.current.readFile(at: vertexURL),
                let fragmentData = FileSystem.current.readFile(at: fragmentURL),
                let vertexSource = String(bytes: vertexData, encoding: .utf8),
                let fragmentSource = String(bytes: fragmentData, encoding: .utf8)
            else {
                return nil
            }

            let vertexEntry = entryPoint(in: vertexSource, attribute: "vertex")
            let fragmentEntry = entryPoint(in: fragmentSource, attribute: "fragment")
            let vertexReflection = WGSLReflection.parse(
                from: vertexSource, stage: .vertex, entryPoint: reflectActiveBindings ? vertexEntry : nil
            )
            let fragmentReflection = WGSLReflection.parse(
                from: fragmentSource, stage: .fragment, entryPoint: reflectActiveBindings ? fragmentEntry : nil
            )
            let vertexShader = try makeWGSLShader(
                source: vertexSource,
                stage: .vertex,
                entryPoint: vertexEntry,
                reflectionData: vertexReflection
            )
            let fragmentShader = try makeWGSLShader(
                source: fragmentSource,
                stage: .fragment,
                entryPoint: fragmentEntry,
                reflectionData: fragmentReflection
            )

            var reflection = ShaderReflectionData()
            reflection.merge(vertexReflection)
            reflection.merge(fragmentReflection)

            return ShaderModule(
                shaders: [
                    .vertex: vertexShader,
                    .fragment: fragmentShader,
                ],
                reflectionData: reflection
            )
        }

        private static func makeWGSLShader(
            source: String,
            stage: ShaderStage,
            entryPoint: String,
            reflectionData: ShaderReflectionData
        ) throws -> Shader {
            let shader = Shader(
                source: source,
                entryPoint: entryPoint,
                stage: stage,
                reflectionData: reflectionData
            )
            try shader.compile()
            return shader
        }

        private static func entryPoint(in source: String, attribute: String) -> String {
            let pattern = "@\\s*" + attribute + "\\s+fn\\s+([A-Za-z_][A-Za-z0-9_]*)"
            guard
                let regex = try? NSRegularExpression(pattern: pattern),
                let match = regex.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)),
                let range = Range(match.range(at: 1), in: source)
            else {
                return "main"
            }

            return String(source[range])
        }
    }
#endif
