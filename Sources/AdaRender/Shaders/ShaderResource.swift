//
//  ShaderResource.swift
//  AdaEngine
//
//  Created by v.prusakov on 3/19/23.
//

/// Name space for shader resources.
public enum ShaderResource {
    public struct DescriptorSet: Codable, Sendable {
        public var uniformsBuffers: [Int: ShaderBuffer] = [:]
        public var constantBuffers: [Int: ShaderBuffer] = [:]
        public var sampledImages: [Int: ImageSampler] = [:]
        public var samplers: [Int: Sampler] = [:]
    }

    public enum ResourceAccess: Codable, Sendable {
        case read
        case write
        case readWrite
    }

    /// Resource type that will be searching into shader.
    enum ResourceType: CaseIterable, Codable {
        case uniformBuffer
        case storageBuffer
        case pushConstantBuffer
        case image
        case sampledImage
        case storageImage
        case inputAttachment
        case sampler
    }

    /// Describe reflected uniform buffer information.
    public struct UniformBuffer: Codable {
        public let name: String
        public let binding: Int
        public let size: Int
        public let resourceAccess: ResourceAccess
    }

    /// Describe reflected sampler information.
    public struct Sampler: Codable, Sendable {
        public let name: String
        public let binding: Int
        public internal(set) var shaderStage: ShaderStageFlags
    }

    /// Describe reflected texture information.
    public struct ImageSampler: Codable, Sendable {
        public let name: String
        public let binding: Int
        public let textureType: Texture.TextureType
        public let descriptorSet: Int
        public let arraySize: Int
        public internal(set) var shaderStage: ShaderStageFlags
        public let resourceAccess: ResourceAccess
        // Optional so reflection cached before depth bindings were supported still decodes.
        var isDepth: Bool? = nil
    }

    /// Describe reflected shader buffer information. That shader buffer contains members (properties)
    public struct ShaderBuffer: Codable, Sendable {
        public let name: String
        public let size: Int
        public internal(set) var shaderStage: ShaderStageFlags
        public let binding: Int
        public let resourceAccess: ResourceAccess

        public let members: [String: ShaderBufferMember]
    }

    public struct ShaderBufferMember: Codable, Sendable {
        let name: String
        let size: Int
        let binding: Int
        let type: ShaderValueType
        let offset: Int
    }
}

/// Contains information about shader stages. For example, shader reflection data can have one or more stage flags for specific resource or buffer.
public struct ShaderStageFlags: OptionSet, Codable, Sendable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }
}

extension ShaderStageFlags {
    init(shaderStage: ShaderStage) {
        switch shaderStage {
        case .vertex:
            self = .vertex
        case .fragment:
            self = .fragment
        case .compute:
            self = .compute
        case .tesselationControl:
            self = .tesselationControl
        case .tesselationEvaluation:
            self = .tesselationEvaluation
        case .max:
            self = .max
        }
    }
}

extension ShaderStageFlags {
    public static let vertex = ShaderStageFlags(rawValue: 1 << 0)
    public static let fragment = ShaderStageFlags(rawValue: 1 << 1)
    public static let compute = ShaderStageFlags(rawValue: 1 << 2)
    public static let tesselationControl = ShaderStageFlags(rawValue: 1 << 3)
    public static let tesselationEvaluation = ShaderStageFlags(rawValue: 1 << 4)

    /// Include all stages.
    public static let max: ShaderStageFlags = [.vertex, .fragment, .compute, .tesselationControl, .tesselationEvaluation]
}

/// Contains relfection data of shader like uniforms buffers, textures and etc.
/// You can use this data to understand how to manipulate shader and how to build buffers for it.
public struct ShaderReflectionData: Codable, Sendable {
    public var descriptorSets: [ShaderResource.DescriptorSet] = []

    /// Collection information about shader buffers, like: Uniform, push values and etc.
    public var shaderBuffers: [String: ShaderResource.ShaderBuffer] = [:]

    /// Collection information about shader resources, like: textures, samplers.
    public var resources: [String: ShaderResource.ImageSampler] = [:]
    public var samplers: [String: ShaderResource.Sampler] = [:]

    /// Check if reflection data is empty.
    public var isEmpty: Bool {
        return self.shaderBuffers.isEmpty && self.resources.isEmpty && self.samplers.isEmpty && self.descriptorSets.isEmpty
    }

    public init() {}
}

extension ShaderReflectionData {
    /// Merge one ``ShaderReflectionData`` into another.
    public mutating func merge(_ data: ShaderReflectionData) {
        self.shaderBuffers.merge(data.shaderBuffers) { existing, new in
            ShaderResource.ShaderBuffer(
                name: new.name,
                size: new.size,
                shaderStage: existing.shaderStage.union(new.shaderStage),
                binding: new.binding,
                resourceAccess: new.resourceAccess,
                members: new.members
            )
        }
        self.resources.merge(data.resources) { existing, new in
            ShaderResource.ImageSampler(
                name: new.name,
                binding: new.binding,
                textureType: new.textureType,
                descriptorSet: new.descriptorSet,
                arraySize: new.arraySize,
                shaderStage: existing.shaderStage.union(new.shaderStage),
                resourceAccess: new.resourceAccess
            )
        }
        self.samplers.merge(data.samplers) { existing, new in
            ShaderResource.Sampler(
                name: new.name,
                binding: new.binding,
                shaderStage: existing.shaderStage.union(new.shaderStage)
            )
        }

        if !data.descriptorSets.isEmpty {
            if self.descriptorSets.count < data.descriptorSets.count {
                let missingCount = data.descriptorSets.count - self.descriptorSets.count
                self.descriptorSets.append(contentsOf: Array(repeating: ShaderResource.DescriptorSet(), count: missingCount))
            }

            for (index, descriptorSet) in data.descriptorSets.enumerated() {
                var mergedSet = self.descriptorSets[index]

                mergedSet.uniformsBuffers.merge(descriptorSet.uniformsBuffers) { existing, new in
                    var merged = new
                    merged.shaderStage.formUnion(existing.shaderStage)
                    return merged
                }
                mergedSet.constantBuffers.merge(descriptorSet.constantBuffers) { existing, new in
                    var merged = new
                    merged.shaderStage.formUnion(existing.shaderStage)
                    return merged
                }
                mergedSet.sampledImages.merge(descriptorSet.sampledImages) { existing, new in
                    var merged = new
                    merged.shaderStage.formUnion(existing.shaderStage)
                    return merged
                }
                mergedSet.samplers.merge(descriptorSet.samplers) { existing, new in
                    var merged = new
                    merged.shaderStage.formUnion(existing.shaderStage)
                    return merged
                }

                self.descriptorSets[index] = mergedSet
            }
        }
    }
}
