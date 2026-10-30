import AdaECS
import AdaRender
import Math

public struct ActiveContactDepth3DPass: Resource {
    public var isEnabled = false
    public init() {}
}

/// Reuses the exact skin/morph/alpha-tested shadow shader and vertex layout.
public struct ContactDepth3DPipeline: RenderPipelineConfigurator {
    private let base = DirectionalShadow3DPipeline()
    public init() {}
    public func configurate(with configuration: Shadow3DConfiguration) -> RenderPipelineDescriptor {
        var descriptor = base.configurate(with: configuration)
        descriptor.colorAttachments = [.init(format: .r32f)]
        descriptor.debugName = "Contact shadow scene depth"
        return descriptor
    }
}

struct SurfaceLighting3DUniform: Sendable {
    var projection: Transform3D
    var inverseProjection: Transform3D
    var contact: Vector4
    var quality: Vector4
    var shadowFilter: Vector4
}

struct SurfaceLighting3DViews: Resource {
    struct Depth { var color: RenderTexture; var depth: RenderTexture }
    var textures: [Entity.ID: Depth] = [:]
    var uniforms = FrameUniformCache3D<SurfaceLighting3DUniform>()
    var distanceFields = FrameUniformCache3D<DistanceField3DUniform>()
    var depthUniforms = FrameUniformCache3D<DirectionalShadowViewUniform>()
    private var retired: [Depth] = []

    mutating func target(view: Entity.ID, size: SizeInt, scale: Float) -> Depth {
        if let existing = textures[view], existing.color.size == size { return existing }
        if let old = textures[view] { retired.append(old) }
        if retired.count > 4 { retired.removeFirst(retired.count-4) }
        let pair = Depth(color: RenderTexture(size:size,scaleFactor:scale,format:.r32f,debugLabel:"Contact scene depth"),
            depth:RenderTexture(size:size,scaleFactor:scale,format:.depth_32f_stencil8,debugLabel:"Contact depth attachment"))
        textures[view] = pair
        return pair
    }
    mutating func retain(_ active: [Entity.ID]) {
        for key in textures.keys where !active.contains(key) { textures.removeValue(forKey:key) }
        uniforms.retainViews(active); depthUniforms.retainViews(active); distanceFields.retainViews(active)
    }
}
