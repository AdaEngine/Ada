//
//  Light2DPipelines.swift
//  AdaEngine
//

import AdaAssets
import AdaCorePipelines
import AdaECS
import AdaRender
import AdaUtils
import Math

/// GPU uniform for ``light2d_point.glsl`` (std140 layout).
public struct PointLightUBOGPU: Sendable {
    public var invViewProjection: Transform3D
    public var lightXYRadius: Vector4
    public var lightRGBEnergy: Vector4
    public var flags: Vector4

    public init(
        invViewProjection: Transform3D,
        lightXYRadius: Vector4,
        lightRGBEnergy: Vector4,
        flags: Vector4
    ) {
        self.invViewProjection = invViewProjection
        self.lightXYRadius = lightXYRadius
        self.lightRGBEnergy = lightRGBEnergy
        self.flags = flags
    }
}

/// GPU uniform for ``light2d_directional.glsl``.
public struct DirectionalLightUBOGPU: Sendable {
    public var lightRGBEnergy: Vector4
    public var flags: Vector4

    public init(lightRGBEnergy: Vector4, flags: Vector4) {
        self.lightRGBEnergy = lightRGBEnergy
        self.flags = flags
    }
}

/// Render pipelines and sampler used by ``Light2DCompositeRenderNode``.
public struct Light2DRenderPipelines: Resource {
    public let compositePipeline: RenderPipeline
    public let pointLightPipeline: RenderPipeline
    public let directionalLightPipeline: RenderPipeline
    public let shadowFinPipeline: RenderPipeline
    public let sampler: Sampler

    public init(device: RenderDevice) {
        let compositeShader = ShaderModule.loadRequiredBundled(at: "Assets/light2d_composite.glsl", from: .module)
        var compositeDesc = RenderPipelineDescriptor(
            vertex: compositeShader.asset.requiredShader(for: .vertex),
            fragment: compositeShader.asset.getShader(for: .fragment),
            debugName: "Light2D Composite",
            backfaceCulling: false,
            depthPixelFormat: .none
        )
        compositeDesc.colorAttachments = [
            RenderPipelineColorAttachmentDescriptor(format: .bgra8, isBlendingEnabled: false)
        ]
        self.compositePipeline = device.createRenderPipeline(from: compositeDesc)

        let pointShader = ShaderModule.loadRequiredBundled(at: "Assets/light2d_point.glsl", from: .module)
        var pointDesc = RenderPipelineDescriptor(
            vertex: pointShader.asset.requiredShader(for: .vertex),
            fragment: pointShader.asset.getShader(for: .fragment),
            debugName: "Light2D Point",
            backfaceCulling: false,
            depthPixelFormat: .none
        )
        pointDesc.colorAttachments = [
            RenderPipelineColorAttachmentDescriptor(
                format: .rgba_16f,
                isBlendingEnabled: true,
                sourceRGBBlendFactor: .one,
                sourceAlphaBlendFactor: .one,
                destinationAlphaBlendFactor: .one,
                destinationRGBBlendFactor: .one
            )
        ]
        self.pointLightPipeline = device.createRenderPipeline(from: pointDesc)

        let dirShader = ShaderModule.loadRequiredBundled(at: "Assets/light2d_directional.glsl", from: .module)
        var dirDesc = RenderPipelineDescriptor(
            vertex: dirShader.asset.requiredShader(for: .vertex),
            fragment: dirShader.asset.getShader(for: .fragment),
            debugName: "Light2D Directional",
            backfaceCulling: false,
            depthPixelFormat: .none
        )
        dirDesc.colorAttachments = pointDesc.colorAttachments
        self.directionalLightPipeline = device.createRenderPipeline(from: dirDesc)

        let quadShader = CorePipelineShaders.loadRequiredBundled(at: "Shaders/quad.glsl")
        var shadowDesc = RenderPipelineDescriptor(
            vertex: quadShader.asset.requiredShader(for: .vertex),
            fragment: quadShader.asset.getShader(for: .fragment),
            debugName: "Light2D Shadow Fin",
            backfaceCulling: false,
            depthPixelFormat: .none
        )
        shadowDesc.vertexDescriptor.attributes.append([
            .attribute(.vector4, name: "a_Position"),
            .attribute(.vector4, name: "a_Color"),
            .attribute(.vector2, name: "a_TexCoordinate"),
        ])
        shadowDesc.vertexDescriptor.layouts[0].stride = MemoryLayout<QuadVertexData>.stride
        shadowDesc.colorAttachments = [
            RenderPipelineColorAttachmentDescriptor(format: .bgra8, isBlendingEnabled: false)
        ]
        self.shadowFinPipeline = device.createRenderPipeline(from: shadowDesc)

        self.sampler = device.createSampler(from: SamplerDescriptor())
    }
}
