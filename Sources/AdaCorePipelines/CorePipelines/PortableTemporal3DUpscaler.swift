import AdaAssets
import AdaECS
import AdaRender
import Math

/// One camera owns these histories. Encoding is serialized by the render graph.
/// Uses the same rigid/skinned/morph/sky motion and reset rules as the native upscalers.
final class PortableTemporal3DUpscaler: TemporalUpscaler, @unchecked Sendable {
    private struct Constants: Sendable { var parameters: Vector4 }
    private let device: RenderDevice
    private let view: Entity.ID
    private let inputSize: SizeInt
    private let outputSize: SizeInt
    private let pipeline: any RenderPipeline
    private let sampler: any Sampler
    private let nearest: any Sampler
    private let colors: [RenderTexture]
    private let depths: [RenderTexture]
    private var uniforms = FrameUniformCache3D<Constants>()
    private var index = 0
    private var valid = false

    init(device: RenderDevice, inputSize: SizeInt, outputSize: SizeInt, view: Entity.ID) {
        self.device = device; self.view = view; self.inputSize = inputSize; self.outputSize = outputSize
        let shader = CorePipelineShaders.loadRequiredBundled(at: "Shaders/portable_temporal_3d.glsl")
        var descriptor = RenderPipelineDescriptor(vertex: shader.asset.requiredShader(for: .vertex),
            fragment: shader.asset.getShader(for: .fragment), debugName: "Portable temporal reconstruction",
            backfaceCulling: false, depthPixelFormat: .none)
        descriptor.colorAttachments = [.init(format: .rgba_16f), .init(format: .rgba_16f), .init(format: .r32f)]
        pipeline = device.createRenderPipeline(from: descriptor)
        sampler = device.createSampler(from: .init(minFilter: .linear, magFilter: .linear, mipFilter: .notMipmapped))
        nearest = device.createSampler(from: .init(minFilter: .nearest, magFilter: .nearest, mipFilter: .notMipmapped))
        colors = (0..<2).map { RenderTexture(size: outputSize, scaleFactor: 1, format: .rgba_16f, debugLabel: "TAA color history \($0)") }
        depths = (0..<2).map { RenderTexture(size: outputSize, scaleFactor: 1, format: .r32f, debugLabel: "TAA depth history \($0)") }
    }

    func encode(commandBuffer: CommandBuffer, color: Texture, depth: Texture, motion: Texture,
        reactive: Texture, output: Texture, jitter: Vector2, reset: Bool) -> Bool {
        let previous = 1-index
        let constants = uniforms.write(Constants(parameters: [jitter.x / Float(inputSize.width),
            jitter.y / Float(inputSize.height), reset || !valid ? 1 : 0, 0]), view: view, device: device)
        let pass = commandBuffer.beginRenderPass(.init(label: "Portable TAA resolve", colorAttachments: [
            .init(texture: output, operation: .init(loadAction: .clear, storeAction: .store)),
            .init(texture: colors[index], operation: .init(loadAction: .clear, storeAction: .store)),
            .init(texture: depths[index], operation: .init(loadAction: .clear, storeAction: .store))
        ]))
        pass.setViewport(Rect(x: 0, y: 0, width: Float(outputSize.width), height: Float(outputSize.height)))
        pass.setRenderPipelineState(pipeline)
        pass.setFragmentBuffer(constants, offset: 0, slot: 8)
        pass.setResourceSet(.init(bindings: [
            .init(binding: 0, shaderStages: .fragment, resource: .texture(color)),
            .init(binding: 1, shaderStages: .fragment, resource: .texture(depth)),
            .init(binding: 2, shaderStages: .fragment, resource: .texture(motion)),
            .init(binding: 3, shaderStages: .fragment, resource: .texture(reactive)),
            .init(binding: 4, shaderStages: .fragment, resource: .texture(colors[previous])),
            .init(binding: 5, shaderStages: .fragment, resource: .texture(depths[previous])),
            .init(binding: 6, shaderStages: .fragment, resource: .sampler(sampler)),
            .init(binding: 7, shaderStages: .fragment, resource: .sampler(nearest))
        ]), index: 0)
        pass.draw(type: .triangle, vertexStart: 0, vertexCount: 3, instanceCount: 1)
        pass.endRenderPass()
        valid = true; index = previous
        return true
    }
}
