import AdaAssets
import AdaECS
import AdaRender
import Math

/// Switches the existing model draw path to motion encoding without changing batching/material binding.
public struct ActiveMotion3DPass: Resource {
    public var isEnabled = false
    public init() {}
}

/// Motion and reactive mask share the main pass's instance data, UVs and alpha tests.
public struct Motion3DPipeline: RenderPipelineConfigurator {
    private let base = Flat3DPipeline()
    private let variants = PBR3DShaderVariants()
    public init() {}

    public func configurate(with configuration: PBR3DConfiguration) -> RenderPipelineDescriptor {
        let plain = CorePipelineShaders.loadRequiredBundled(at: "Shaders/motion_3d.glsl")
        // Only the morph feature matters to the motion shader; the shading layers do not.
        let morph = configuration.features.intersection(.morph)
        let shader = morph.isEmpty ? plain : variants.shader(at: "Shaders/motion_3d.glsl", for: morph, fallback: plain)
        var descriptor = base.configurate(with: configuration.vertex)
        descriptor.vertex = shader.asset.requiredShader(for: .vertex)
        descriptor.fragment = shader.asset.getShader(for: .fragment)
        descriptor.debugName = "Motion 3D"
        descriptor.backfaceCulling = false
        descriptor.depthPixelFormat = configuration.temporalDepth ? .depth_32f : .depth_32f_stencil8
        descriptor.depthStencilDescriptor = .init(isDepthTestEnabled: true, isDepthWriteEnabled: false, depthCompareOperator: .lessOrEqual)
        for (column, location) in [1, 4, 10, 11].enumerated() {
            descriptor.vertexDescriptor.attributes[location] = .attribute(.vector4, name: "previousModel\(column)", bufferIndex: 3, offset: 128 + column * 16)
        }
        descriptor.colorAttachments = [.init(format: .rgba_16f), .init(format: .bgra8)]
        if configuration.blended {
            descriptor.colorAttachments[0] = .init(
                format: .rgba_16f,
                isBlendingEnabled: true,
                sourceRGBBlendFactor: .zero,
                sourceAlphaBlendFactor: .zero,
                destinationAlphaBlendFactor: .one,
                destinationRGBBlendFactor: .one
            )
            // WebGPU requires both factors to be one for min/max operations.
            descriptor.colorAttachments[1] = .init(
                format: .bgra8,
                isBlendingEnabled: true,
                sourceRGBBlendFactor: .one,
                sourceAlphaBlendFactor: .one,
                rgbBlendOperation: .max,
                alphaBlendOperation: .max,
                destinationAlphaBlendFactor: .one,
                destinationRGBBlendFactor: .one
            )
        }
        return descriptor
    }
}

struct Temporal3DUniform: Sendable {
    var currentViewProjection: Transform3D
    var previousViewProjection: Transform3D
    var inverseJitteredProjection: Transform3D
    var currentToPreviousView: Transform3D
    var parameters: Vector4
    /// `x` tone mapper selector. Only the temporal tone-map shader declares this member.
    var toneMapping: Vector4 = .zero
}

struct Temporal3DPipelines: Resource {
    var uniform = FrameUniformCache3D<Temporal3DUniform>()
    var sky: (any RenderPipeline)?
    var depth: (any RenderPipeline)?
    var toneMap: (any RenderPipeline)?
    let sampler: any Sampler
    /// Filtering for the color-grading LUT.
    let linear: any Sampler

    init(device: RenderDevice) {
        sampler = device.createSampler(from: .init(minFilter: .nearest, magFilter: .nearest, mipFilter: .notMipmapped))
        linear = device.createSampler(from: .init(minFilter: .linear, magFilter: .linear, mipFilter: .notMipmapped))
    }

    mutating func skyPipeline(device: RenderDevice) -> any RenderPipeline {
        if let sky {
            return sky
        }
        let shader = CorePipelineShaders.loadRequiredBundled(at: "Shaders/sky_motion_3d.glsl")
        var descriptor = RenderPipelineDescriptor(
            vertex: shader.asset.requiredShader(for: .vertex),
            fragment: shader.asset.getShader(for: .fragment),
            debugName: "Sky Motion 3D",
            backfaceCulling: false,
            depthPixelFormat: .none
        )
        descriptor.colorAttachments = [.init(format: .rgba_16f), .init(format: .bgra8)]
        let result = device.createRenderPipeline(from: descriptor)
        sky = result
        return result
    }

    mutating func toneMapPipeline(device: RenderDevice) -> any RenderPipeline {
        if let toneMap {
            return toneMap
        }
        let shader = CorePipelineShaders.loadRequiredBundled(at: "Shaders/temporal_tonemap_3d.glsl")
        var descriptor = RenderPipelineDescriptor(
            vertex: shader.asset.requiredShader(for: .vertex),
            fragment: shader.asset.getShader(for: .fragment),
            debugName: "Temporal HDR Tone Map",
            backfaceCulling: false,
            depthPixelFormat: .none
        )
        descriptor.colorAttachments = [.init(format: .bgra8)]
        let result = device.createRenderPipeline(from: descriptor)
        toneMap = result
        return result
    }

    mutating func depthPipeline(device: RenderDevice) -> any RenderPipeline {
        if let depth {
            return depth
        }
        let shader = CorePipelineShaders.loadRequiredBundled(at: "Shaders/temporal_depth_3d.glsl")
        var descriptor = RenderPipelineDescriptor(
            vertex: shader.asset.requiredShader(for: .vertex),
            fragment: shader.asset.getShader(for: .fragment),
            debugName: "Temporal Output Depth 3D",
            backfaceCulling: false
        )
        descriptor.colorAttachments = []
        descriptor.depthStencilDescriptor = .init(isDepthTestEnabled: true, isDepthWriteEnabled: true, depthCompareOperator: .always)
        let result = device.createRenderPipeline(from: descriptor)
        depth = result
        return result
    }
}
