import AdaECS
import AdaRender
import Math

/// CPU history decisions are separated from GPU reconstruction for deterministic validation.
public struct Temporal3DHistory: Sendable {
    public private(set) var frame = 0
    public private(set) var lastFrame: Int?
    private var view = Transform3D.identity
    private var projection = Transform3D.identity
    private var settings: TemporalUpscalingSettings?
    private var inputSize = SizeInt.zero
    private var outputSize = SizeInt.zero

    public init() {}

    public mutating func prepare(
        frame: Int,
        view: Transform3D,
        projection: Transform3D,
        inputSize: SizeInt,
        outputSize: SizeInt,
        settings: TemporalUpscalingSettings
    ) -> (jitter: Vector2, previousView: Transform3D, previousViewProjection: Transform3D, reset: Bool) {
        let camera = view.inverse
        let oldCamera = self.view.inverse
        let cut = (camera.origin - oldCamera.origin).length > 2 || camera.z.xyz.normalized.dot(oldCamera.z.xyz.normalized) < 0.5
        let reset =
            lastFrame != frame - 1 || cut || self.projection != projection || self.inputSize != inputSize
            || self.outputSize != outputSize || self.settings != settings
        if reset { self.frame = 0 }
        let jitter = Self.jitter(index: self.frame)
        let previousView = reset ? view : self.view
        let previousProjection = reset ? projection : self.projection
        self.frame = (self.frame + 1) % 8
        lastFrame = frame
        self.view = view
        self.projection = projection
        self.inputSize = inputSize
        self.outputSize = outputSize
        self.settings = settings
        return (jitter, previousView, previousProjection * previousView, reset)
    }

    public static func jitter(index: Int) -> Vector2 {
        func halton(_ value: Int, base: Int) -> Float {
            var index = value
            var factor: Float = 1
            var result: Float = 0
            while index > 0 {
                factor /= Float(base)
                result += factor * Float(index % base)
                index /= base
            }
            return result - 0.5
        }
        return [halton(index % 8 + 1, base: 2), halton(index % 8 + 1, base: 3)]
    }

    /// Positive X/Y jitter shifts geometry right/down in Metal pixel coordinates.
    public static func jittered(_ projection: Transform3D, offset: Vector2, size: SizeInt) -> Transform3D {
        var translation = Transform3D.identity
        translation.w.x = 2 * offset.x / Float(max(1, size.width))
        translation.w.y = -2 * offset.y / Float(max(1, size.height))
        return translation * projection
    }

    public static func motion(current: Vector4, previous: Vector4) -> Vector2 {
        guard current.w > 0.00001, previous.w > 0.00001 else {
            return .zero
        }
        return (Vector2(previous.x, previous.y) / previous.w - Vector2(current.x, current.y) / current.w) * Vector2(0.5, -0.5)
    }
}

struct Temporal3DViews: Resource {
    struct Entry {
        var history = Temporal3DHistory()
        var scaler: (any TemporalUpscaler)?
        var inputSize = SizeInt.zero
        var outputSize = SizeInt.zero
        var encoded = false
    }
    var entries: [Entity.ID: Entry] = [:]
    var frame = 0
}

@PlainSystem(dependencies: [.after("AdaCorePipelines.PrepareEnvironment3DTexturesSystem")])
struct PrepareTemporal3DSystem {
    @Query<Camera, CameraRenderGraph, Ref<RenderViewTarget>, GlobalViewUniform, ExtractedCameraSource> private var cameras
    @ResMut<Temporal3DViews> private var views
    @Res<RenderDeviceHandler> private var device

    init(world _: World) {}

    func update(context _: UpdateContext) {
        views.frame &+= 1
        var active: [Entity.ID] = []
        cameras.forEach { camera, graph, target, uniform, source in
            guard camera.isActive, graph.subgraphLabel == .main3D,
                let settings = camera.temporalUpscaling,
                device.renderDevice.supportsTemporalUpscaling,
                let input = target.mainTexture, let output = target.outputTexture
            else { return }
            active.append(source.entityId)
            var entry = views.entries.removeValue(forKey: source.entityId) ?? Temporal3DViews.Entry()
            if entry.inputSize != input.size || entry.outputSize != output.size {
                entry.scaler = device.renderDevice.createTemporalUpscaler(inputSize: input.size, outputSize: output.size)
                entry.inputSize = input.size
                entry.outputSize = output.size
                entry.encoded = false
            }
            guard entry.scaler != nil else {
                views.entries[source.entityId] = entry
                return
            }
            let decision = entry.history.prepare(
                frame: views.frame,
                view: uniform.viewMatrix,
                projection: uniform.projectionMatrix,
                inputSize: input.size,
                outputSize: output.size,
                settings: settings
            )
            target.temporalJitter = decision.jitter
            target.temporalPreviousView = decision.previousView
            target.temporalPreviousViewProjection = decision.previousViewProjection
            target.temporalReset = decision.reset || !entry.encoded
            entry.encoded = false
            target.temporalUpscalingActive = true
            if target.temporalInputTexture?.size != input.size || target.temporalInputTexture?.pixelFormat != .rgba_16f {
                target.temporalInputTexture = RenderTexture(
                    size: input.size,
                    scaleFactor: input.scaleFactor,
                    format: .rgba_16f,
                    debugLabel: "Temporal 3D HDR Input",
                    usage: [.renderTarget, .read, .write],
                    usesPrivateStorage: true
                )
            }
            if target.temporalResolvedTexture?.size != output.size {
                target.temporalResolvedTexture = RenderTexture(
                    size: output.size,
                    scaleFactor: output.scaleFactor,
                    format: .rgba_16f,
                    debugLabel: "Temporal 3D Resolve",
                    usage: [.renderTarget, .read, .write],
                    usesPrivateStorage: true
                )
                target.temporalPresentationTexture = RenderTexture(size: output.size, scaleFactor: output.scaleFactor, format: .bgra8, debugLabel: "Temporal 3D Presentation")
                target.temporalOutputDepthTexture = RenderTexture(size: output.size, scaleFactor: output.scaleFactor, format: .depth_32f_stencil8, debugLabel: "Temporal 3D Output Depth")
            }
            if target.depthTexture?.pixelFormat != .depth_32f {
                target.depthTexture = RenderTexture(size: input.size, scaleFactor: input.scaleFactor, format: .depth_32f, debugLabel: "Temporal 3D Depth")
            }
            if target.temporalMotionTexture?.size != input.size {
                target.temporalMotionTexture = RenderTexture(size: input.size, scaleFactor: input.scaleFactor, format: .rgba_16f, debugLabel: "Temporal 3D Motion", usesPrivateStorage: true)
                target.temporalReactiveTexture = RenderTexture(size: input.size, scaleFactor: input.scaleFactor, format: .bgra8, debugLabel: "Temporal 3D Reactive", usesPrivateStorage: true)
            }
            target.mainTexture = target.temporalPresentationTexture
            views.entries[source.entityId] = entry
        }
        for id in views.entries.keys where !active.contains(id) { views.entries.removeValue(forKey: id) }
    }
}

func temporalViewUniform(_ uniform: GlobalViewUniform, target: RenderViewTarget) -> GlobalViewUniform {
    guard target.temporalUpscalingActive, let input = target.temporalInputTexture else {
        return uniform
    }
    let projection = Temporal3DHistory.jittered(uniform.projectionMatrix, offset: target.temporalJitter, size: input.size)
    return GlobalViewUniform(projectionMatrix: projection, viewProjectionMatrix: projection * uniform.viewMatrix, viewMatrix: uniform.viewMatrix)
}
