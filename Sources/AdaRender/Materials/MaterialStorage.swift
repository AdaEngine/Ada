//
//  MaterialStorage.swift
//  AdaEngine
//
//  Created by v.prusakov on 4/2/23.
//

import AdaAssets
import AdaUtils

// TODO: I don't like that solution
// - Remove or replace RenderEngine
// - Should be a class or be open for inheritance?
open class MaterialStorageData {
    public var reflectionData: ShaderReflectionData = ShaderReflectionData()
    public var uniformBufferSet: [String: UniformBuffer] = [:]
    public var textures: [String: MaterialTexture] = [:]
    public init() {}

    public func updateUniformBuffers(from module: ShaderModule) {
        self.reflectionData.merge(module.reflectionData)

        module.reflectionData.shaderBuffers.forEach { bufferName, bufferDesc in
            if self.uniformBufferSet[bufferName] == nil {
                let uniformBuffer = unsafe RenderEngine.shared.renderDevice.createUniformBuffer(
                    length: bufferDesc.size,
                    binding: bufferDesc.binding
                )
                uniformBuffer.label = "\(module.assetName) \(bufferDesc.name) \(bufferDesc.shaderStage)"
                self.uniformBufferSet[bufferName] = uniformBuffer
            }
        }
    }
}

public struct MaterialTexture {
    public let texture: Texture
    public let samplerName: String

    public init(texture: Texture, samplerName: String) {
        self.texture = texture
        self.samplerName = samplerName
    }
}

public final class MaterialStorage {
    nonisolated(unsafe) public static let shared: MaterialStorage = MaterialStorage()
    private var materialData: [RID: MaterialStorageData] = [:]

    private init() {}

    // MARK: - Material

    public func setValue<T>(_ value: T, for name: String, in material: Material) {
        guard let data = self.materialData[material.rid] else {
            return
        }

        guard let bufferDesc = self.getUniformDescription(for: name, in: data) else {
            return
        }

        assert(MemoryLayout<T>.stride == bufferDesc.size, "Failed to set value with type \(type(of: value)) to property with type \(bufferDesc)")

        let buffer = data.uniformBufferSet[bufferDesc.name]
        unsafe withUnsafePointer(to: value) { pointer in
            let dataPtr = unsafe UnsafeMutableRawPointer(mutating: UnsafeRawPointer(pointer))
            unsafe buffer?.setData(dataPtr, byteCount: bufferDesc.size)
        }
    }

    public func getValue<T>(for name: String, in material: Material) -> T? {
        guard let data = self.materialData[material.rid] else {
            return nil
        }

        guard let bufferDesc = self.getUniformDescription(for: name, in: data) else {
            return nil
        }

        assert(MemoryLayout<T>.stride == bufferDesc.size, "Failed to get value with type \(T.self) from property with type \(bufferDesc)")
        let buffer = data.uniformBufferSet[bufferDesc.name]
        return unsafe buffer?.contents().load(fromByteOffset: 0, as: T.self)
    }

    public func getUniformDescription(for name: String, in material: MaterialStorageData) -> ShaderResource.ShaderBuffer? {
        let reflectionData = material.reflectionData
        return reflectionData.shaderBuffers[name]
    }

    public func setTexture(_ texture: MaterialTexture, for name: String, in material: Material) {
        guard let data = self.materialData[material.rid] else {
            return
        }

        guard let samplerDescription = self.getResourceDescription(for: name, in: data) else {
            return
        }
        data.textures[samplerDescription.name] = texture
    }

    public func getTexture(for name: String, in material: Material) -> MaterialTexture? {
        guard let data = self.materialData[material.rid] else {
            return nil
        }

        guard let samplerDescription = self.getResourceDescription(for: name, in: data) else {
            return nil
        }

        return data.textures[samplerDescription.name]
    }

    public func getResourceDescription(for name: String, in material: MaterialStorageData) -> ShaderResource.ImageSampler? {
        let reflectionData = material.reflectionData
        return reflectionData.resources[name]
    }

    public func getSamplerDescription(for name: String, in material: MaterialStorageData) -> ShaderResource.Sampler? {
        let reflectionData = material.reflectionData
        return reflectionData.samplers[name]
    }

    public func setMaterialData(_ materialData: MaterialStorageData, for material: Material) {
        self.materialData[material.rid] = materialData
    }

    public func getMaterialData(for material: Material) -> MaterialStorageData? {
        return self.materialData[material.rid]
    }
}
