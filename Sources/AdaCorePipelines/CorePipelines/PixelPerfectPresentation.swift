import AdaAssets
import AdaECS
@_spi(Internal) import AdaRender
import AdaUtils
import Foundation
import Math
import Synchronization

/// Pipelines and sampler used to scale a pixel-perfect camera's low-resolution picture up to its output.
public struct PixelPerfectPipelines: Resource {
    /// Draws into the intermediate full-resolution picture the UI is composed onto.
    public let intermediate: RenderPipeline
    /// Draws into the window or texture the camera presents to.
    public let output: RenderPipeline
    /// Nearest sampling without mip levels, so scaled pixels stay square and sharp.
    public let sampler: Sampler

    public init(device: RenderDevice, outputPipeline: RenderPipeline) {
        let shader = CorePipelineShaders.loadRequiredBuiltin("FullScreenShader")
        var descriptor = RenderPipelineDescriptor(vertex: shader.asset.requiredShader(for: .vertex))
        descriptor.debugName = "Pixel Perfect Intermediate Pipeline"
        descriptor.backfaceCulling = false
        descriptor.fragment = shader.asset.getShader(for: .fragment)
        descriptor.colorAttachments = [RenderPipelineColorAttachmentDescriptor(format: .bgra8)]
        self.intermediate = device.createRenderPipeline(from: descriptor)
        self.output = outputPipeline
        self.sampler = device.createSampler(from: SamplerDescriptor(minFilter: .nearest, magFilter: .nearest, mipFilter: .notMipmapped))
    }
}

/// Full-resolution pictures that pixel-perfect cameras compose their UI onto, one per camera.
///
/// The UI node draws the scaled-up scene and then the UI into the camera's picture; the upscale node later copies
/// that picture to the output. A camera whose UI node did not run in a frame has no fresh picture, and the upscale
/// node presents the low-resolution scene directly.
public final class PixelPerfectPictures: Resource, @unchecked Sendable {
    private struct Entry {
        var texture: RenderTexture
        var isFresh: Bool
    }

    private struct Retired {
        var texture: RenderTexture
        var remainingFrames: Int
    }

    private let state = Mutex<(entries: [Entity.ID: Entry], retired: [Retired])>(([:], []))

    public init() {}

    /// Returns the picture for a view at the given size, creating it if the size changed. The old texture stays alive
    /// for the frames still in flight, because the GPU may be reading it.
    public func picture(for view: Entity.ID, size: SizeInt) -> RenderTexture {
        state.withLock { state in
            if let entry = state.entries[view], entry.texture.width == size.width, entry.texture.height == size.height {
                return entry.texture
            }
            if let old = state.entries[view] {
                state.retired.append(Retired(texture: old.texture, remainingFrames: max(1, unsafe RenderEngine.configurations.maxFramesInFlight) * 4))
            }
            let texture = RenderTexture(
                size: size,
                scaleFactor: 1,
                format: .bgra8,
                debugLabel: "Pixel Perfect Picture",
                samplerDescription: SamplerDescriptor(minFilter: .nearest, magFilter: .nearest, mipFilter: .notMipmapped)
            )
            state.entries[view] = Entry(texture: texture, isFresh: false)
            return texture
        }
    }

    /// Records that this frame's picture for the view was composed.
    public func markComposed(_ view: Entity.ID) {
        state.withLock { $0.entries[view]?.isFresh = true }
    }

    /// Returns the composed picture for the view and forgets that it was composed, so each frame starts clean.
    public func takeComposed(_ view: Entity.ID) -> RenderTexture? {
        state.withLock { state in
            guard let entry = state.entries[view], entry.isFresh else { return nil }
            state.entries[view]?.isFresh = false
            return entry.texture
        }
    }

    /// Ages retired textures. Called once per presented camera, so with several cameras they are released a little sooner
    /// than a frame count suggests; the margin in ``picture(for:size:)`` covers that.
    public func advanceFrame() {
        state.withLock { state in
            for index in state.retired.indices { state.retired[index].remainingFrames -= 1 }
            state.retired.removeAll { $0.remainingFrames <= 0 }
        }
    }
}

/// Encodes the scaling draws of pixel-perfect presentation.
public enum PixelPerfectPresenter {
    /// Draws `source` into `destination` scaled to `layout.rect`, after filling the whole destination with the border colour.
    public static func present(
        source: Texture,
        into destination: RenderTexture,
        layout: PixelPerfectLayout,
        letterboxColor: Color,
        pipeline: RenderPipeline,
        sampler: Sampler,
        commandBuffer: CommandBuffer,
        label: String
    ) {
        draw(source: source, into: destination, viewport: layout.rect, clear: letterboxColor, pipeline: pipeline, sampler: sampler, commandBuffer: commandBuffer, label: label)
    }

    /// Copies a picture that is already the size of `destination`.
    public static func copy(
        source: Texture,
        into destination: RenderTexture,
        pipeline: RenderPipeline,
        sampler: Sampler,
        commandBuffer: CommandBuffer,
        label: String
    ) {
        let full = Rect(x: 0, y: 0, width: Float(destination.width), height: Float(destination.height))
        draw(source: source, into: destination, viewport: full, clear: .black, pipeline: pipeline, sampler: sampler, commandBuffer: commandBuffer, label: label)
    }

    private static func draw(
        source: Texture,
        into destination: RenderTexture,
        viewport: Rect,
        clear: Color,
        pipeline: RenderPipeline,
        sampler: Sampler,
        commandBuffer: CommandBuffer,
        label: String
    ) {
        let pass = commandBuffer.beginRenderPass(
            RenderPassDescriptor(
                label: label,
                colorAttachments: [
                    .init(
                        texture: destination,
                        operation: OperationDescriptor(loadAction: .clear, storeAction: .store),
                        clearColor: clear
                    )
                ],
                depthStencilAttachment: nil
            )
        )
        pass.setResourceSet(
            RenderResourceSet(bindings: [
                RenderResourceSet.Binding(binding: 0, shaderStages: .fragment, resource: .texture(source)),
                RenderResourceSet.Binding(binding: 1, shaderStages: .fragment, resource: .sampler(sampler)),
            ]),
            index: 0
        )
        pass.setViewport(viewport)
        pass.setRenderPipelineState(pipeline)
        pass.draw(type: .triangle, vertexStart: 0, vertexCount: 3, instanceCount: 1)
        pass.endRenderPass()
    }
}
