//
//  Upscaling.swift
//  AdaEngine
//
//  Created by Vladislav Prusakov on 26.11.2025.
//

import AdaApp
import AdaAssets
import AdaECS
import AdaRender
import AdaUtils
import Math

public struct UpscalePlugin: Plugin {
    public init() {}

    public func setup(in app: borrowing AdaApp.AppWorlds) {
        guard let renderWorld = app.getSubworldBuilder(by: .renderWorld) else {
            return
        }
        let renderDevice = renderWorld.getResource(RenderDeviceHandler.self)
            .unwrap(message: "Failed to fetch RenderDevice from world")
            .renderDevice

        renderWorld
            .insertResource(UpscalePipeline(device: renderDevice))
    }
}

public struct UpscalePipeline: Resource {
    public let renderPipeline: RenderPipeline
    public let sampler: Sampler

    public init(device: RenderDevice) {
        let spriteShader = ShaderModule.loadRequiredBundled(at: "Shaders/FullScreenShader.glsl", from: .module)

        var descriptor = RenderPipelineDescriptor(vertex: spriteShader.asset.requiredShader(for: .vertex))
        descriptor.debugName = "Upscale Pipeline"

        descriptor.fragment = spriteShader.asset.getShader(for: .fragment)
        descriptor.colorAttachments = [
            RenderPipelineColorAttachmentDescriptor(format: .bgra8)
        ]

        self.renderPipeline = device.createRenderPipeline(from: descriptor)
        self.sampler = device.createSampler(from: SamplerDescriptor())
    }
}
