import AdaECS
import AdaRender

public struct PBR3DConfiguration: Hashable, Sendable {
    public let vertex: VertexDescriptor
    public let blended: Bool
    public let temporalDepth: Bool
    /// The shading layers the draw's material uses. The default is none, which is the plain shader.
    public let features: PBRMaterial.ShaderFeatures

    public init(vertex: VertexDescriptor, blended: Bool, temporalDepth: Bool = false, features: PBRMaterial.ShaderFeatures = []) {
        self.features = features
        self.temporalDepth = temporalDepth
        self.vertex = vertex
        self.blended = blended
    }
}

/// Fragment-stage facing handling keeps single/double-sided behavior consistent across backends.
public struct PBR3DPipeline: RenderPipelineConfigurator {
    private let base = Flat3DPipeline()
    public init() {}

    public func configurate(with configuration: PBR3DConfiguration) -> RenderPipelineDescriptor {
        var descriptor = base.configurate(with: configuration.vertex, features: configuration.features)
        descriptor.backfaceCulling = false
        if configuration.temporalDepth { descriptor.depthPixelFormat = .depth_32f }
        descriptor.depthStencilDescriptor?.isDepthWriteEnabled = !configuration.blended
        if configuration.features.contains(.hybridReflection) {
            descriptor.colorAttachments.append(.init(format: .rgba_16f))
            if configuration.blended {
                descriptor.colorAttachments[4].isBlendingEnabled = true
                descriptor.colorAttachments[4].sourceRGBBlendFactor = .zero
            }
        }
        if configuration.features.contains(.diffuseSurface) {
            var attachment = RenderPipelineColorAttachmentDescriptor(format: .rgba8)
            if configuration.blended {
                attachment.isBlendingEnabled = true
                attachment.sourceRGBBlendFactor = .zero
                attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
            }
            descriptor.colorAttachments.append(attachment)
        }
        if configuration.blended {
            for index in 1...2 {
                descriptor.colorAttachments[index] = RenderPipelineColorAttachmentDescriptor(
                    format: .rgba_16f,
                    isBlendingEnabled: true,
                    sourceRGBBlendFactor: .zero,
                    sourceAlphaBlendFactor: .zero,
                    destinationAlphaBlendFactor: .one,
                    destinationRGBBlendFactor: .one
                )
            }
            descriptor.colorAttachments[3].isBlendingEnabled = true
            descriptor.colorAttachments[3].sourceRGBBlendFactor = .zero
        }
        return descriptor
    }
}
