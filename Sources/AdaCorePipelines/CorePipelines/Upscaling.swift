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
        let spriteShader = ShaderModule.loadRequiredBundled(at: "Shaders/FullScreenShader.glsl", from: .adaModule)

        var descriptor = RenderPipelineDescriptor(vertex: spriteShader.asset.requiredShader(for: .vertex))
        descriptor.debugName = "Upscale Pipeline"
        // Fullscreen triangles have no physical facing; presentation must survive backend winding conventions.
        descriptor.backfaceCulling = false

        descriptor.fragment = spriteShader.asset.getShader(for: .fragment)
        #if os(Android)
            // Android native swapchains expose RGBA; intermediate targets remain BGRA.
            let outputFormat: PixelFormat = .rgba8
        #else
            let outputFormat: PixelFormat = .bgra8
        #endif
        descriptor.colorAttachments = [RenderPipelineColorAttachmentDescriptor(format: outputFormat)]

        self.renderPipeline = device.createRenderPipeline(from: descriptor)
        self.sampler = device.createSampler(from: SamplerDescriptor())
    }
}
