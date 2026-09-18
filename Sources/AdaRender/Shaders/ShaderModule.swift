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
        let module = try ShaderCompiler(from: filePath).compileShaderModule()
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
    /// Create a new shader module from a file url.
    ///
    /// - Parameter fileUrl: The file url to create the shader module from.
    /// - Returns: The shader module.
    public static func create(from fileUrl: URL) throws -> ShaderModule {
        try ShaderCompiler(from: fileUrl).compileShaderModule()
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

        #if WASM && canImport(WebGPU)
            if path.hasSuffix(".glsl"), let wgslModule = try createWGSLModuleIfAvailable(for: url) {
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

#if WASM && canImport(WebGPU)
    extension ShaderModule {
        private static func createWGSLModuleIfAvailable(for glslURL: URL) throws -> ShaderModule? {
            let baseURL = glslURL.deletingPathExtension()
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

            let vertexReflection = makeWGSLReflection(from: vertexSource, stage: .vertex)
            let fragmentReflection = makeWGSLReflection(from: fragmentSource, stage: .fragment)
            let vertexShader = try makeWGSLShader(
                source: vertexSource,
                stage: .vertex,
                entryPoint: entryPoint(in: vertexSource, attribute: "vertex"),
                reflectionData: vertexReflection
            )
            let fragmentShader = try makeWGSLShader(
                source: fragmentSource,
                stage: .fragment,
                entryPoint: entryPoint(in: fragmentSource, attribute: "fragment"),
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
            let pattern = "@" + attribute + "\\s+fn\\s+([A-Za-z_][A-Za-z0-9_]*)"
            guard
                let regex = try? NSRegularExpression(pattern: pattern),
                let match = regex.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)),
                let range = Range(match.range(at: 1), in: source)
            else {
                return "main"
            }

            return String(source[range])
        }

        private static func makeWGSLReflection(from source: String, stage: ShaderStage) -> ShaderReflectionData {
            var reflection = ShaderReflectionData()
            let stageFlag = ShaderStageFlags(shaderStage: stage)
            let pattern = #"@group\((\d+)\)\s*@binding\((\d+)\)\s*var(?:<([^>]+)>)?\s+([A-Za-z_][A-Za-z0-9_]*)\s*:\s*([^;]+);"#
            guard let regex = try? NSRegularExpression(pattern: pattern) else {
                return reflection
            }

            let matches = regex.matches(in: source, range: NSRange(source.startIndex..., in: source))
            for match in matches {
                guard
                    let groupRange = Range(match.range(at: 1), in: source),
                    let bindingRange = Range(match.range(at: 2), in: source),
                    let nameRange = Range(match.range(at: 4), in: source),
                    let typeRange = Range(match.range(at: 5), in: source),
                    let group = Int(source[groupRange]),
                    let binding = Int(source[bindingRange])
                else {
                    continue
                }

                let addressSpace: String
                if let addressRange = Range(match.range(at: 3), in: source) {
                    addressSpace = String(source[addressRange])
                } else {
                    addressSpace = ""
                }
                let name = String(source[nameRange])
                let type = String(source[typeRange])

                reflection.ensureDescriptorSet(at: group)

                if addressSpace == "uniform" {
                    let buffer = ShaderResource.ShaderBuffer(
                        name: name,
                        size: 0,
                        shaderStage: stageFlag,
                        binding: binding,
                        resourceAccess: .read,
                        members: [:]
                    )
                    reflection.shaderBuffers[name] = buffer
                    reflection.descriptorSets[group].uniformsBuffers[binding] = buffer
                } else if type.hasPrefix("texture") {
                    let resource = ShaderResource.ImageSampler(
                        name: name,
                        binding: binding,
                        textureType: .texture2D,
                        descriptorSet: group,
                        arraySize: 1,
                        shaderStage: stageFlag,
                        resourceAccess: .read
                    )
                    reflection.resources[name] = resource
                    reflection.descriptorSets[group].sampledImages[binding] = resource
                } else if type.hasPrefix("sampler") {
                    let sampler = ShaderResource.Sampler(
                        name: name,
                        binding: binding,
                        shaderStage: stageFlag
                    )
                    reflection.samplers[name] = sampler
                    reflection.descriptorSets[group].samplers[binding] = sampler
                }
            }

            return reflection
        }
    }

    extension ShaderReflectionData {
        private mutating func ensureDescriptorSet(at index: Int) {
            guard index >= descriptorSets.count else {
                return
            }

            descriptorSets.append(contentsOf: Array(repeating: ShaderResource.DescriptorSet(), count: index - descriptorSets.count + 1))
        }
    }
#endif
