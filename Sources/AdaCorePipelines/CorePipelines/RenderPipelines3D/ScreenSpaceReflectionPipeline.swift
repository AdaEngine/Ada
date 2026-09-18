//
//  ScreenSpaceReflectionPipeline.swift
//  AdaEngine
//

import AdaAssets
import AdaECS
import AdaRender
import Math

/// GPU resources used by the 3D environment composite pass.
public struct ScreenSpaceReflectionPipeline: Resource {
    public let renderPipeline: RenderPipeline
    public let sampler: Sampler

    public init(device: RenderDevice) {
        let shader = CorePipelineShaders.loadRequiredBundled(at: "Shaders/screen_space_reflection.glsl")
        var descriptor = RenderPipelineDescriptor(
            vertex: shader.asset.requiredShader(for: .vertex),
            fragment: shader.asset.getShader(for: .fragment),
            debugName: "Screen Space Reflection Composite",
            backfaceCulling: false,
            depthPixelFormat: .none
        )
        descriptor.colorAttachments = [
            RenderPipelineColorAttachmentDescriptor(format: .bgra8, isBlendingEnabled: false)
        ]
        self.renderPipeline = device.createRenderPipeline(from: descriptor)
        self.sampler = device.createSampler(
            from: SamplerDescriptor(
                minFilter: .linear,
                magFilter: .linear,
                mipFilter: .linear
            )
        )
    }
}

struct Environment3DUniform: Sendable {
    var projection: Transform3D
    var inverseProjection: Transform3D
    var inverseView: Transform3D
    var zenithColor: Vector4
    var horizonColor: Vector4
    var groundColor: Vector4
    var clearColor: Vector4
    var reflection: Vector4
    var reflectionQuality: Vector4
    var environmentFlags: Vector4
    var starfield: Vector4
}

public struct ScreenSpaceReflectionScratch: Resource, Sendable {
    var uniform = BufferData<Environment3DUniform>(label: "Environment 3D Uniform", elements: [])

    public init() {}
}
