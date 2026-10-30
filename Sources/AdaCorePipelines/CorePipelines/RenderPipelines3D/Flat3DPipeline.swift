//
//  Flat3DPipeline.swift
//  AdaEngine
//
//  Created by Codex on 07/06/26.
//

import AdaAssets
import AdaECS
import AdaRender
import AdaUtils
import Foundation
import Math

/// Per-instance data consumed by the flat 3D vertex pipeline.
public struct Flat3DInstanceData: Sendable, Equatable {
    public let modelMatrix: Transform3D
    public let color: Vector4
    public let material: Vector4
    public let textureFlags: Vector4
    public let shadowFlags: Vector4
    public let previousModelMatrix: Transform3D

    public init(
        modelMatrix: Transform3D,
        color: Vector4,
        material: Vector4,
        textureFlags: Vector4 = .zero,
        shadowFlags: Vector4 = [1, 0, 0, 0],
        previousModelMatrix: Transform3D? = nil
    ) {
        self.modelMatrix = modelMatrix
        self.color = color
        self.material = material
        self.textureFlags = textureFlags
        self.shadowFlags = shadowFlags
        self.previousModelMatrix = previousModelMatrix ?? modelMatrix
    }
}

/// Per-instance fallback values for mesh attributes that are optional in ``MeshDescriptor``.
public struct Flat3DDefaultVertexData: Sendable {
    public let textureCoordinate: Vector2
    public let padding: Vector2
    public let tangent: Vector4
    public let jointIndices: Vector4
    public let jointWeights: Vector4
    public let textureCoordinate1: Vector2
    public let padding1: Vector2
    public let vertexColor: Vector4

    public init(textureCoordinate: Vector2 = .zero, tangent: Vector4 = [1, 0, 0, 1]) {
        self.textureCoordinate = textureCoordinate
        padding = .zero
        self.tangent = tangent
        jointIndices = [-1, 0, 0, 0]
        jointWeights = [1, 0, 0, 0]
        textureCoordinate1 = .zero
        padding1 = .zero
        vertexColor = .one
    }
}

/// Triple-buffered instance data shared by the main and shadow 3D passes.
public struct Opaque3DInstanceBuffers: Resource {
    private struct Frame {
        var buffer: (any Buffer)?
        var instances: [Flat3DInstanceData] = []
        var count = 0
        var dirty = false
    }
    private var frames: [Frame]
    private var defaultVertexData: BufferData<Flat3DDefaultVertexData>
    private var currentIndex: Int

    public init() {
        let bufferCount = max(1, unsafe RenderEngine.configurations.maxFramesInFlight)
        frames = Array(repeating: Frame(), count: bufferCount)
        defaultVertexData = BufferData(
            label: "Opaque 3D Default Vertex Data",
            elements: [Flat3DDefaultVertexData()]
        )
        currentIndex = bufferCount - 1
    }

    public var currentBuffer: BufferData<Flat3DInstanceData>? {
        guard let buffer = frames[currentIndex].buffer else {
            return nil
        }

        var data = BufferData<Flat3DInstanceData>(elements: [])
        data.buffer = buffer
        return data
    }

    public var defaultVertexBuffer: BufferData<Flat3DDefaultVertexData>? {
        guard defaultVertexData.buffer != nil else {
            return nil
        }
        return defaultVertexData
    }

    public mutating func beginFrame() {
        currentIndex = (currentIndex + 1) % frames.count
        frames[currentIndex].count = 0
        frames[currentIndex].dirty = false
    }

    public mutating func append(_ instance: Flat3DInstanceData) -> Int32 {
        let index = frames[currentIndex].count
        if index < frames[currentIndex].instances.count {
            if frames[currentIndex].instances[index] != instance {
                frames[currentIndex].instances[index] = instance
                frames[currentIndex].dirty = true
            }
        } else {
            frames[currentIndex].instances.append(instance)
            frames[currentIndex].dirty = true
        }
        frames[currentIndex].count += 1
        return Int32(index)
    }

    public mutating func write(to renderDevice: RenderDevice) {
        let count = frames[currentIndex].count
        guard count > 0 else {
            return
        }

        // Fallback attributes advance per instance too, including multi-instance static batches.
        if defaultVertexData.count < count {
            for _ in defaultVertexData.count ..< count {
                defaultVertexData.append(Flat3DDefaultVertexData())
            }
            defaultVertexData.write(to: renderDevice)
        } else if defaultVertexData.buffer == nil {
            defaultVertexData.write(to: renderDevice)
        }

        let requiredLength = frames[currentIndex].instances.count * MemoryLayout<Flat3DInstanceData>.stride
        if frames[currentIndex].buffer?.length ?? 0 < requiredLength {
            frames[currentIndex].buffer = renderDevice.createBuffer(
                label: "Opaque 3D Instances \(currentIndex)",
                length: requiredLength,
                options: .storageShared
            )
            frames[currentIndex].dirty = true
        }
        // Each in-flight buffer owns its CPU snapshot. Static main/shadow lists
        // reuse the existing GPU contents; edits, reordering and growth upload again.
        if frames[currentIndex].dirty {
            let buffer = frames[currentIndex].buffer
            buffer?.setElements(&frames[currentIndex].instances)
            frames[currentIndex].dirty = false
        }
    }
}

/// Pipeline configurator for a simple unlit 3D mesh pass.
public struct Flat3DPipeline: RenderPipelineConfigurator {
    private let shader: AssetHandle<ShaderModule>
    private let variants = PBR3DShaderVariants()

    public init() {
        self.shader = ShaderModule.loadRequiredBundled(at: "Shaders/flat3d.glsl", from: .adaModule)
    }

    public func configurate(with configuration: VertexDescriptor) -> RenderPipelineDescriptor {
        configurate(with: configuration, features: [])
    }

    /// A pipeline whose fragment shader only contains the shading layers in `features`.
    public func configurate(with configuration: VertexDescriptor, features: PBRMaterial.ShaderFeatures) -> RenderPipelineDescriptor {
        let shader = features.isEmpty ? shader : variants.shader(for: features, fallback: shader)
        var configuration = configuration
        if !configuration.attributes.containsAttribute(by: MeshDescriptor.textureCoordinates.id.name) {
            configuration.attributes[2] = .attribute(.vector2, name: "defaultTextureCoordinate", bufferIndex: 4, offset: 0)
        }
        if !configuration.attributes.containsAttribute(by: MeshDescriptor.tangents.id.name) {
            configuration.attributes[4] = .attribute(.vector4, name: "defaultTangent", bufferIndex: 4, offset: 16)
        }
        configureSkinningAttributes(&configuration)
        configuration.attributes[5] = .attribute(.vector4, name: "instanceModel0", bufferIndex: 3, offset: 0)
        configuration.attributes[6] = .attribute(.vector4, name: "instanceModel1", bufferIndex: 3, offset: 16)
        configuration.attributes[7] = .attribute(.vector4, name: "instanceModel2", bufferIndex: 3, offset: 32)
        configuration.attributes[8] = .attribute(.vector4, name: "instanceModel3", bufferIndex: 3, offset: 48)
        configuration.attributes[9] = .attribute(.vector4, name: "instanceColor", bufferIndex: 3, offset: 64)
        configuration.attributes[10] = .attribute(.vector4, name: "instanceMaterial", bufferIndex: 3, offset: 80)
        configuration.attributes[11] = .attribute(.vector4, name: "instanceTextureFlags", bufferIndex: 3, offset: 96)
        configuration.attributes[12] = .attribute(.vector4, name: "instanceShadowFlags", bufferIndex: 3, offset: 112)
        configuration.layouts[3] = VertexDescriptor.Layout(
            stride: MemoryLayout<Flat3DInstanceData>.stride,
            stepFunction: .perInstance
        )
        let defaults = ["defaultTextureCoordinate", "defaultTangent", "defaultJointIndices", "defaultJointWeights", "defaultTextureCoordinate1", "defaultVertexColor"]
        if defaults.contains(where: { configuration.attributes.containsAttribute(by: $0) }) {
            configuration.layouts[4] = VertexDescriptor.Layout(
                stride: MemoryLayout<Flat3DDefaultVertexData>.stride,
                stepFunction: .perInstance
            )
        }

        var descriptor = RenderPipelineDescriptor(vertex: shader.asset.requiredShader(for: .vertex))
        descriptor.fragment = shader.asset.getShader(for: .fragment)
        descriptor.debugName = features.isEmpty ? "Flat 3D Pipeline" : "Flat 3D Pipeline \(features.rawValue)"
        descriptor.vertexDescriptor = configuration
        #if os(Android)
            descriptor.frontFaceWinding = .clockwise
        #endif
        descriptor.depthStencilDescriptor = DepthStencilDescriptor(
            isDepthTestEnabled: true,
            isDepthWriteEnabled: true,
            depthCompareOperator: .less
        )
        descriptor.colorAttachments = [
            RenderPipelineColorAttachmentDescriptor(format: .rgba_16f, isBlendingEnabled: true),
            RenderPipelineColorAttachmentDescriptor(format: .rgba_16f),
            RenderPipelineColorAttachmentDescriptor(format: .rgba_16f),
            RenderPipelineColorAttachmentDescriptor(format: .rgba_16f),
        ]
        return descriptor
    }
}


/// Compiled shader variants by file and the features they include. A variant is compiled on first use and shared by every
/// pipeline that needs it. Fallbacks may drop optional shading layers, but retain morph and MRT contracts.
final class PBR3DShaderVariants: @unchecked Sendable {
    private struct Key: Hashable {
        let path: String
        let features: PBRMaterial.ShaderFeatures
    }

    private let lock = NSLock()
    private var variants: [Key: AssetHandle<ShaderModule>] = [:]

    func shader(
        at path: String = "Shaders/flat3d.glsl",
        for features: PBRMaterial.ShaderFeatures,
        fallback: AssetHandle<ShaderModule>
    ) -> AssetHandle<ShaderModule> {
        lock.lock()
        defer { lock.unlock() }
        let key = Key(path: path, features: features)
        if let existing = variants[key] {
            return existing
        }
        let variant: AssetHandle<ShaderModule>
        do {
            variant = AssetHandle(try ShaderModule.createBundled(at: path, from: .adaModule, defines: features.enablingMacros))
        } catch {
            assertionFailure("Shader variant \(features.rawValue) of \(path) failed to compile: \(error)")
            // A plain shader has no fifth fragment output and cannot safely write a hybrid render pass.
            // Morph changes the vertex contract too. These defines remain mandatory even when a layer fails.
            let required = features.intersection([.hybridReflection, .morph, .diffuseSurface, .lightmap, .irradianceGrid])
            if required.isEmpty {
                variant = fallback
            } else {
                let requiredKey = Key(path: path, features: required)
                if let compatible = variants[requiredKey] {
                    variant = compatible
                } else {
                    variant = ShaderModule.loadRequiredBundled(at: path, from: .adaModule, defines: required.enablingMacros)
                    variants[requiredKey] = variant
                }
            }
        }
        variants[key] = variant
        return variant
    }
}
