import AdaAssets
import AdaECS
import AdaRender
import Math

struct ScreenQuality3DPipelines: Resource {
    private var ao: RenderPipeline?
    private var aa: RenderPipeline?
    let nearest: Sampler
    let linear: Sampler

    init(device: RenderDevice) {
        nearest = device.createSampler(from: .init(minFilter: .nearest, magFilter: .nearest, mipFilter: .notMipmapped))
        linear = device.createSampler(from: .init(minFilter: .linear, magFilter: .linear, mipFilter: .notMipmapped))
    }

    mutating func aoPipeline(device: RenderDevice) -> RenderPipeline {
        if let ao {
            return ao
        }
        let pipeline = make("Shaders/ssao_3d.glsl", label: "SSAO 3D", device: device)
        ao = pipeline
        return pipeline
    }

    mutating func aaPipeline(device: RenderDevice) -> RenderPipeline {
        if let aa {
            return aa
        }
        let pipeline = make("Shaders/fxaa_3d.glsl", label: "FXAA 3D", device: device)
        aa = pipeline
        return pipeline
    }

    private func make(_ path: String, label: String, device: RenderDevice) -> RenderPipeline {
        let shader = CorePipelineShaders.loadRequiredBundled(at: path)
        var descriptor = RenderPipelineDescriptor(
            vertex: shader.asset.requiredShader(for: .vertex),
            fragment: shader.asset.getShader(for: .fragment),
            debugName: label,
            backfaceCulling: false,
            depthPixelFormat: .none
        )
        descriptor.colorAttachments = [.init(format: .bgra8)]
        return device.createRenderPipeline(from: descriptor)
    }
}

struct SSAO3DUniform: Sendable {
    var projection: Transform3D
    var parameters: Vector4
    var pass: Vector4
}

struct ScreenQuality3DScratch: Resource {
    var ao = FrameUniformCache3D<SSAO3DUniform>()
    var aa = FrameUniformCache3D<Vector4>()
}
