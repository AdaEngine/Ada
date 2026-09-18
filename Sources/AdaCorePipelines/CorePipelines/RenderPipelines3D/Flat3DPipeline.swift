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
import Math

/// Per-instance data consumed by the flat 3D vertex pipeline.
public struct Flat3DInstanceData: Sendable {
    public let modelMatrix: Transform3D
    public let color: Vector4
    public let material: Vector4
    public let textureFlags: Vector4
    public let shadowFlags: Vector4

    public init(
        modelMatrix: Transform3D,
        color: Vector4,
        material: Vector4,
        textureFlags: Vector4 = .zero,
        shadowFlags: Vector4 = [1, 0, 0, 0]
    ) {
        self.modelMatrix = modelMatrix
        self.color = color
        self.material = material
        self.textureFlags = textureFlags
        self.shadowFlags = shadowFlags
    }
}

/// Per-instance fallback values for mesh attributes that are optional in ``MeshDescriptor``.
public struct Flat3DDefaultVertexData: Sendable {
    public let textureCoordinate: Vector2
    public let padding: Vector2
    public let tangent: Vector4

    public init(textureCoordinate: Vector2 = .zero, tangent: Vector4 = [1, 0, 0, 1]) {
        self.textureCoordinate = textureCoordinate
        self.padding = .zero
        self.tangent = tangent
    }
}

/// Triple-buffered instance data shared by the main and shadow 3D passes.
public struct Opaque3DInstanceBuffers: Resource {
    private var buffers: [(any Buffer)?]
    private var instances: [Flat3DInstanceData]
    private var defaultVertexData: BufferData<Flat3DDefaultVertexData>
    private var currentIndex: Int

    public init() {
        let bufferCount = max(1, unsafe RenderEngine.configurations.maxFramesInFlight)
        self.buffers = Array(repeating: nil, count: bufferCount)
        self.instances = []
        self.defaultVertexData = BufferData(
            label: "Opaque 3D Default Vertex Data",
            elements: [Flat3DDefaultVertexData()]
        )
        self.currentIndex = bufferCount - 1
    }

    public var currentBuffer: BufferData<Flat3DInstanceData>? {
        guard let buffer = buffers[currentIndex] else {
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
        currentIndex = (currentIndex + 1) % buffers.count
        instances.removeAll(keepingCapacity: true)
    }

    public mutating func append(_ instance: Flat3DInstanceData) -> Int32 {
        let index = Int32(instances.count)
        instances.append(instance)
        return index
    }

    public mutating func write(to renderDevice: RenderDevice) {
        guard !instances.isEmpty else {
            return
        }

        if defaultVertexData.buffer == nil {
            defaultVertexData.write(to: renderDevice)
        }

        let requiredLength = instances.count * MemoryLayout<Flat3DInstanceData>.stride
        if buffers[currentIndex]?.length ?? 0 < requiredLength {
            buffers[currentIndex] = renderDevice.createBuffer(
                label: "Opaque 3D Instances \(currentIndex)",
                length: requiredLength,
                options: .storageShared
            )
        }
        buffers[currentIndex]?.setElements(&instances)
    }
}

/// Pipeline configurator for a simple unlit 3D mesh pass.
public struct Flat3DPipeline: RenderPipelineConfigurator {
    private let shader: AssetHandle<ShaderModule>

    public init() {
        self.shader = ShaderModule.loadRequiredBundled(at: "Shaders/flat3d.glsl", from: .module)
    }

    public func configurate(with configuration: VertexDescriptor) -> RenderPipelineDescriptor {
        var configuration = configuration
        if !configuration.attributes.containsAttribute(by: MeshDescriptor.textureCoordinates.id.name) {
            configuration.attributes[2] = .attribute(.vector2, name: "defaultTextureCoordinate", bufferIndex: 4, offset: 0)
        }
        if !configuration.attributes.containsAttribute(by: MeshDescriptor.tangents.id.name) {
            configuration.attributes[4] = .attribute(.vector4, name: "defaultTangent", bufferIndex: 4, offset: 16)
        }
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
        configuration.layouts[4] = VertexDescriptor.Layout(
            stride: MemoryLayout<Flat3DDefaultVertexData>.stride,
            stepFunction: .perInstance
        )

        var descriptor = RenderPipelineDescriptor(vertex: shader.asset.requiredShader(for: .vertex))
        descriptor.fragment = shader.asset.getShader(for: .fragment)
        descriptor.debugName = "Flat 3D Pipeline"
        descriptor.vertexDescriptor = configuration
        descriptor.depthStencilDescriptor = DepthStencilDescriptor(
            isDepthTestEnabled: true,
            isDepthWriteEnabled: true,
            depthCompareOperator: .less
        )
        descriptor.colorAttachments = [
            RenderPipelineColorAttachmentDescriptor(format: .rgba_16f, isBlendingEnabled: true),
            RenderPipelineColorAttachmentDescriptor(format: .rgba_16f),
            RenderPipelineColorAttachmentDescriptor(format: .rgba_16f),
        ]
        return descriptor
    }
}
