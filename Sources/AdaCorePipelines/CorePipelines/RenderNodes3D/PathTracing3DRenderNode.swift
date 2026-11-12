import AdaAssets
import AdaECS
import AdaRender
import AdaUtils
import Foundation
import Math
import Synchronization

public struct PathTracing3DStatus: Codable, Sendable {
    public var encodedFrames = 0
    public var historyResets = 0
    public var accumulatedFrames = 0
    public var triangles = 0
    public var lights = 0
    public var width = 0
    public var height = 0
    public var failure: String?
    public var implementation = "portable-shader-bvh"
    /// Whether the first hit came from the raster G-buffer (full model detail) rather than a traced primary ray.
    public var hybridFirstHit = false
    /// The denoiser that ran: `rayReconstruction`, `portable` or `off` (see ``PathTracingDenoiser``).
    public var denoiser = PathTracingDenoiser.portable.rawValue
    /// Why the requested denoiser was not used, if it was not.
    public var denoiserFallback: String?
}

/// Actual per-view encode/failure counters; enabling a setting alone is not proof of ray tracing.
public final class Render3DPathTracingStatistics: Resource, Sendable {
    private let state = Mutex<[String: PathTracing3DStatus]>([:])
    public init() {}
    public var snapshots: [String: PathTracing3DStatus] { state.withLock { $0 } }
    func record(_ value: PathTracing3DStatus, view: Entity.ID) { state.withLock { $0[String(view)] = value } }
    func discard(_ view: Entity.ID) { _ = state.withLock { $0.removeValue(forKey:String(view)) } }
}

struct PathTracing3DUniform: Sendable {
    var inverseProjection: Transform3D
    var inverseView: Transform3D
    var counts: Vector4
    var trace: Vector4
    var frame: Vector4
    var zenith: Vector4
    var horizon: Vector4
    var ground: Vector4
    var sky: Vector4
    /// x: the first hit comes from the raster G-buffer (path-tracing surface outputs present).
    var hybrid: Vector4
    /// Unjittered view-projection and view of this view's previous traced frame, for reprojection.
    var previousViewProjection: Transform3D
    var previousView: Transform3D
    /// x: wavelet step, y: minimum history weight, z: trace writes demodulated light, w: final pass remodulates.
    var denoise: Vector4
}

struct PathTracing3DViews: Resource {
    struct Entry: Sendable {
        /// Accumulated light of the previous and the current frame.
        var targets: [RenderTexture]
        /// This frame's raw samples (portable denoiser only).
        var trace: RenderTexture
        /// World normal and camera distance of the previous and the current frame, validating reprojection.
        var guides: [RenderTexture]
        /// Ping-pong targets of the wavelet iterations.
        var filters: [RenderTexture]
        var index = 0
        var previousViewProjection: Transform3D?
        var previousView: Transform3D?
        var denoiser: PathTracingDenoiser?
        /// Ray Reconstruction guide targets, and the guides of this frame when Ray Reconstruction denoises it.
        var guideTargets: [RenderTexture] = []
        var rayReconstructionGuides: RayReconstructionGuides?
        var digest: UInt64?
        var status = PathTracing3DStatus()
        var active = false
        /// Light table reused while the lights are unchanged. A changed table gets a new texture, because
        /// frames still in flight may read the previous one.
        var lightTable: Texture2D?
        var lightTableDigest: UInt64?
        var lightTableBuilds = 0
    }
    var scene = PathTracing3DScene()
    var entries: [Entity.ID: Entry] = [:]
    var uniforms = FrameUniformCache3D<PathTracing3DUniform>()
    var pipeline: (any RenderPipeline)?
    var nearest: (any Sampler)?
    var linear: (any Sampler)?
    var lastFailure: String?

    mutating func getPipeline(_ device: RenderDevice) -> any RenderPipeline {
        if let pipeline { return pipeline }
        let shader = CorePipelineShaders.loadRequiredBuiltin("path_tracing_3d")
        var descriptor = RenderPipelineDescriptor(vertex:shader.asset.requiredShader(for:.vertex),fragment:shader.asset.getShader(for:.fragment),
            debugName:"World-space path tracing",backfaceCulling:false,depthPixelFormat:.none)
        descriptor.colorAttachments = [.init(format:.rgba_16f)]
        let result = device.createRenderPipeline(from:descriptor)
        pipeline = result
        nearest = device.createSampler(from:.init(minFilter:.nearest,magFilter:.nearest,mipFilter:.notMipmapped))
        linear = device.createSampler(from:.init(minFilter:.linear,magFilter:.linear,mipFilter:.notMipmapped))
        return result
    }
}

/// Replaces opaque surface HDR with actual scene-triangle path transport, before exposure/bloom/temporal reconstruction.
public struct PathTracing3DRenderNode: RenderNode {
    public static let name: RenderNodeLabel = "Main3D.PathTracing"
    @Query<Entity, RenderViewTarget, GlobalViewUniform, ExtractedCameraSource> private var views
    @Res<ExtractedCameraRenderViewTargets> private var cameraTargets
    @Res<ExtractedEnvironment3D> private var environments
    @Res<ExtractedLighting3D> private var lighting
    @ResMut<PathTracing3DViews> private var resources
    @Res<Render3DPathTracingStatistics> private var statistics
    @Res<RenderDeviceHandler> private var device
    @Res<Render3DPerformanceMetrics?> private var metrics
    public init() {}

    public func update(from world: World) {
        views.update(from:world); _cameraTargets.update(from:world); _environments.update(from:world); _lighting.update(from:world)
        _resources.update(from:world); _statistics.update(from:world); _device.update(from:world); _metrics.update(from:world)
        // Extracted proxies themselves can still be deferred during graph update. Use the
        // camera identities collected from the source world, not those transient entities.
        let active = Array(cameraTargets.activeCameraIDs)
        for id in resources.entries.keys where !active.contains(id) { resources.entries.removeValue(forKey:id); statistics.discard(id) }
        resources.uniforms.retainViews(active)
    }

    public func execute(context: inout Context, renderContext: RenderContext) async throws -> [RenderSlotValue] {
        guard let view = context.viewEntity else { return [] }
        var selected: (RenderViewTarget,GlobalViewUniform,Entity.ID)?
        views.forEach { entity,target,uniform,source in if entity == view { selected = (target,uniform,source.entityId) } }
        guard let (target,uniform,id) = selected else { return [] }
        let environment = environments.environments[id] ?? .init()
        let settings = environment.pathTracing.sanitized
        guard settings.isEnabled, environment.debugView != .meshlets, !environment.debugView.showsWireframe, let color = target.sceneColor3DTexture,
            let normal = target.normalRoughness3DTexture, let position = target.viewPositionMetallic3DTexture else {
            resources.entries.removeValue(forKey:id); statistics.discard(id)
            if resources.entries.isEmpty { resources.scene = PathTracing3DScene() }
            return []
        }
        // Raster-only detail is seen through the G-buffer first hit; the tracer intersects its proxies instead.
        let sources = context.world.getResource(ExtractedMesh3DSources.self)?.pathTracedMeshes ?? []
        var scene = resources.scene
        do { try await scene.prepare(sources,skinning:context.world.getResource(Skinning3DUniforms.self),device:device.renderDevice,
                                    textureTileSize:settings.textureTileSize) }
        catch {
            let reason = String(describing:error)
            var status = PathTracing3DStatus(); status.failure = reason
            statistics.record(status,view:id); resources.entries.removeValue(forKey:id)
            if resources.entries.isEmpty { resources.scene = PathTracing3DScene() }
            if resources.lastFailure != reason {
                FileHandle.standardError.write(Data("AdaEngine path tracing unavailable: \(reason)\n".utf8)); resources.lastFailure = reason
            }
            return []
        }
        resources.scene = scene
        // Ray Reconstruction needs DLSS temporal upscaling of this view and G-buffer guides; it then traces at input size,
        // because it reconstructs from input-resolution samples (resolutionScale applies to the other denoisers).
        let hybridAvailable = target.pathTracingSurfaceActive && target.diffuseSurface3DTexture != nil && target.reflectionResponse3DTexture != nil
        let reconstructionUnavailable: String? = !target.temporalUpscalingActive || !target.rayReconstructionAvailable
            ? "DLSS Ray Reconstruction is unavailable for this view"
            : !hybridAvailable ? "Ray Reconstruction needs the G-buffer first hit" : nil
        let usesReconstruction = reconstructionUnavailable == nil && (settings.denoiser == .automatic || settings.denoiser == .rayReconstruction)
        let size = usesReconstruction ? color.size
            : SizeInt(width:max(1,Int(Float(color.size.width)*settings.resolutionScale)),height:max(1,Int(Float(color.size.height)*settings.resolutionScale)))
        var entry = resources.entries.removeValue(forKey:id)
        if entry?.targets.first?.size != size {
            func texture(_ label: String) -> RenderTexture { RenderTexture(size:size,scaleFactor:1,format:.rgba_16f,debugLabel:label) }
            entry = .init(targets:(0..<2).map { _ in texture("Path tracing accumulation") }, trace:texture("Path tracing samples"),
                guides:(0..<2).map { _ in texture("Path tracing reprojection guide") }, filters:(0..<2).map { _ in texture("Path tracing wavelet filter") })
        }
        guard var entry, let nodes = scene.nodes, let triangles = scene.triangles, let materials = scene.materials, let atlas = scene.atlas else { return [] }
        let denoiser: PathTracingDenoiser
        switch settings.denoiser {
        case .off: denoiser = .off
        case .portable: denoiser = .portable
        case .automatic, .rayReconstruction: denoiser = usesReconstruction ? .rayReconstruction : .portable
        }
        let denoises = denoiser != .off
        var hash = FrameDigest3D()
        hash.combine(scene.generation)
        if !denoises { hash.combine(uniform.viewMatrix); hash.combine(uniform.projectionMatrix) }
        hash.combine(UInt64(denoiser == .off ? 0 : (denoiser == .portable ? 1 : 2)))
        hash.combine(UInt64(settings.samplesPerPixel)); hash.combine(UInt64(settings.maximumBounces)); hash.combine(UInt64(settings.historyLimit))
        hash.combine(settings.maximumDistance); hash.combine(settings.rayBias); hash.combine(settings.maximumRadiance)
        var lights: [Vector4] = []
        let suns = lighting.directionalLights.isEmpty ? lighting.directionalLight.map { [$0] } ?? [] : lighting.directionalLights
        for sun in suns where sun.intensity.isFinite && sun.intensity > 0 && LocalLighting3DMath.isFinite(sun.directionToLight)
            && sun.directionToLight.squaredLength > 0.000001 && LocalLighting3DMath.isFinite(sun.radiance) {
            let angle = finiteRenderValue(environment.shadows.lightAngularRadius,fallback:0.27,range:0...10)*Float.pi/180
            lights += [Vector4(sun.directionToLight.normalized,0),Vector4(sun.radiance*sun.intensity,0),Vector4(0,0,0,sun.castsShadows ? 1 : 0),Vector4(0,0,Math.tanf(angle),0)]
        }
        for lamp in lighting.localLights where lamp.intensity.isFinite && lamp.intensity > 0 && lamp.range.isFinite && lamp.range > 0
            && LocalLighting3DMath.isFinite(lamp.position) && LocalLighting3DMath.isFinite(lamp.radiance) {
            guard lamp.kind == .point || (LocalLighting3DMath.isFinite(lamp.direction) && lamp.direction.squaredLength > 0.000001) else { continue }
            let cone = LocalLighting3DMath.coneCosines(inner:lamp.innerConeAngle,outer:lamp.outerConeAngle)
            lights += [Vector4(lamp.position,lamp.kind == .point ? 1 : 2),Vector4(lamp.radiance*lamp.intensity,lamp.range),
                Vector4(lamp.direction,lamp.castsShadows ? 1 : 0),Vector4(cone.x,cone.y,0,0)]
        }
        if denoises {
            // Moving lights keep history (reprojection and the history weight fade it); adding, removing, switching
            // or retuning a light restarts it. Records: position|direction + kind, radiance + range, axis + shadows, cone.
            hash.combine(UInt64(lights.count))
            for index in stride(from:0,to:lights.count,by:4) {
                hash.combine(lights[index].w); hash.combine(lights[index+1]); hash.combine(lights[index+2].w); hash.combine(lights[index+3])
            }
        } else {
            for value in lights { hash.combine(value) }
        }
        let sky = environment.skybox
        let linearEnvironment = environment.skyboxUsesImageBasedLighting && environment.imageBasedLighting?.asset.asset?.radiance != nil
        let environmentTexture = environment.skyboxUsesImageBasedLighting ? environment.imageBasedLighting?.asset.asset?.radiance ?? sky.texture?.asset : sky.texture?.asset
        let intensity = environment.skyboxUsesImageBasedLighting && environment.imageBasedLighting?.asset.asset?.radiance != nil ? environment.imageBasedLighting?.intensity ?? 1 : sky.intensity
        let skyParameters = Vector4(environmentTexture == nil ? 0 : 1,max(0,intensity),environment.imageBasedLighting?.rotation ?? 0,sky.isEnabled ? 1 : 0)
        hash.combine(sky.zenithColor.asVector); hash.combine(sky.horizonColor.asVector); hash.combine(sky.groundColor.asVector); hash.combine(skyParameters)
        hash.combine(linearEnvironment ? UInt64(1) : 0)
        if let environmentTexture { hash.combine(UInt64(bitPattern:Int64(ObjectIdentifier(environmentTexture).hashValue))) }
        let historyRestarted = entry.digest != hash.value || entry.denoiser != denoiser
        if entry.digest != hash.value { entry.status.accumulatedFrames = 0; entry.status.historyResets += 1; entry.digest = hash.value }
        let previous = entry.index
        entry.index = 1-entry.index
        let current = entry.index
        let pipeline = resources.getPipeline(device.renderDevice)
        guard let nearest = resources.nearest, let linear = resources.linear else { return [] }
        var lightDigest = FrameDigest3D()
        for value in lights { lightDigest.combine(value) }
        lightDigest.combine(UInt64(lights.count))
        let lightTexture: Texture2D
        if let table = entry.lightTable, entry.lightTableDigest == lightDigest.value {
            lightTexture = table
        } else {
            lightTexture = PathTracing3DScene.dataTexture(lights,label:"Path tracing all lights")
            entry.lightTable = lightTexture; entry.lightTableDigest = lightDigest.value; entry.lightTableBuilds += 1
        }
        // Full-detail first hit: base colour and emission written by the main pass for path-traced views.
        let hybridSurface = target.pathTracingSurfaceActive
            ? target.diffuseSurface3DTexture.flatMap { albedo in target.reflectionResponse3DTexture.map { (albedo,$0) } } : nil
        let jittered = temporalViewUniform(uniform,target:target)
        let viewProjection = uniform.projectionMatrix * uniform.viewMatrix
        var constants = PathTracing3DUniform(inverseProjection:jittered.projectionMatrix.inverse,inverseView:uniform.viewMatrix.inverse,
            counts:Vector4(Float(scene.nodeCount),Float(lights.count/4),Float(settings.samplesPerPixel),Float(settings.maximumBounces)),
            trace:Vector4(settings.maximumDistance,settings.rayBias,settings.maximumRadiance,Float(min(entry.status.accumulatedFrames,settings.historyLimit-1))),
            frame:Vector4(Float(entry.status.encodedFrames%1000000),0,Float(atlas.height/scene.tileSize),linearEnvironment ? 1 : 0),
            zenith:sky.zenithColor.asVector,horizon:sky.horizonColor.asVector,ground:sky.groundColor.asVector,sky:skyParameters,
            hybrid:Vector4(hybridSurface == nil ? 0 : 1,0,0,0),
            previousViewProjection:entry.previousViewProjection ?? viewProjection,previousView:entry.previousView ?? uniform.viewMatrix,
            denoise:Vector4(1,settings.minimumHistoryWeight,denoises ? 1 : 0,denoises ? 1 : 0))
        // Shader passes: 0 trace, 1 temporal, 2 guide, 3 wavelet, 4 final. Inputs never alias the pass's destination.
        struct Step { var shader: Int; var destination: RenderTexture; var a: Texture; var b: Texture?; var c: Texture?; var spacing: Float; var label: String }
        var steps: [Step] = []
        entry.rayReconstructionGuides = nil
        if denoiser == .rayReconstruction {
            // One fresh sample per frame: Ray Reconstruction keeps its own history and denoises at upscale.
            constants.trace.w = 0
            constants.denoise.z = 0
            constants.denoise.w = 0
            if entry.guideTargets.first?.size != size {
                entry.guideTargets = ["Path tracing RR diffuse albedo","Path tracing RR specular albedo","Path tracing RR normal roughness"]
                    .map { RenderTexture(size:size,scaleFactor:1,format:.rgba_16f,debugLabel:$0) }
            }
            steps.append(Step(shader:0,destination:entry.trace,a:entry.targets[previous],b:nil,c:nil,spacing:1,label:"Path tracing rays"))
            for (selector, guide) in entry.guideTargets.enumerated() {
                steps.append(Step(shader:5,destination:guide,a:entry.trace,b:nil,c:nil,spacing:Float(selector),label:"Path tracing RR guide"))
            }
            steps.append(Step(shader:4,destination:color,a:entry.trace,b:nil,c:nil,spacing:1,label:"Path tracing reconstruction"))
            entry.rayReconstructionGuides = RayReconstructionGuides(diffuseAlbedo:entry.guideTargets[0],specularAlbedo:entry.guideTargets[1],
                normalRoughness:entry.guideTargets[2],worldToView:uniform.viewMatrix,viewToClip:uniform.projectionMatrix,reset:historyRestarted)
        } else if denoises {
            steps.append(Step(shader:0,destination:entry.trace,a:entry.targets[previous],b:nil,c:nil,spacing:1,label:"Path tracing rays"))
            steps.append(Step(shader:1,destination:entry.targets[current],a:entry.trace,b:entry.targets[previous],c:entry.guides[previous],
                spacing:1,label:"Path tracing temporal reprojection"))
            steps.append(Step(shader:2,destination:entry.guides[current],a:entry.trace,b:nil,c:nil,spacing:1,label:"Path tracing reprojection guide"))
            var input: Texture = entry.targets[current]
            for (iteration, spacing) in [Float(1),2,4,8].enumerated() {
                let output = entry.filters[iteration % 2]
                steps.append(Step(shader:3,destination:output,a:input,b:nil,c:nil,spacing:spacing,label:"Path tracing wavelet filter"))
                input = output
            }
            steps.append(Step(shader:4,destination:color,a:input,b:nil,c:nil,spacing:1,label:"Path tracing reconstruction"))
        } else {
            steps.append(Step(shader:0,destination:entry.targets[current],a:entry.targets[previous],b:nil,c:nil,spacing:1,label:"Path tracing rays"))
            steps.append(Step(shader:4,destination:color,a:entry.targets[current],b:nil,c:nil,spacing:1,label:"Path tracing reconstruction"))
        }
        let command = renderContext.commandQueue.makeCommandBuffer(); command.label = "World-space path tracing"
        for (passIndex, step) in steps.enumerated() {
            let destination = step.destination
            constants.frame.y = Float(step.shader)
            constants.denoise.x = step.spacing
            let buffer = resources.uniforms.write(constants,view:id,pass:passIndex,device:device.renderDevice)
            let label = step.label
            let pass = command.beginRenderPass(.init(label:label,
                colorAttachments:[.init(texture:destination,operation:.init(loadAction:.clear,storeAction:.store))]))
            pass.setViewport(Rect(x:0,y:0,width:Float(destination.size.width),height:Float(destination.size.height)))
            pass.setRenderPipelineState(pipeline); pass.setFragmentBuffer(buffer,offset:0,slot:4)
            pass.setResourceSet(.init(bindings:[
                .init(binding:0,shaderStages:.fragment,resource:.texture(nodes)), .init(binding:1,shaderStages:.fragment,resource:.texture(triangles)),
                .init(binding:2,shaderStages:.fragment,resource:.texture(materials)), .init(binding:3,shaderStages:.fragment,resource:.texture(atlas)),
                .init(binding:5,shaderStages:.fragment,resource:.texture(lightTexture)),
                .init(binding:6,shaderStages:.fragment,resource:.texture(step.a)),
                .init(binding:7,shaderStages:.fragment,resource:.texture(environmentTexture ?? Texture2D.whiteTexture)),
                .init(binding:8,shaderStages:.fragment,resource:.sampler(nearest)), .init(binding:9,shaderStages:.fragment,resource:.sampler(linear)),
                .init(binding:10,shaderStages:.fragment,resource:.texture(normal)), .init(binding:11,shaderStages:.fragment,resource:.texture(position)),
                .init(binding:12,shaderStages:.fragment,resource:.texture(hybridSurface?.0 ?? Texture2D.whiteTexture)),
                .init(binding:13,shaderStages:.fragment,resource:.texture(hybridSurface?.1 ?? Texture2D.whiteTexture)),
                .init(binding:14,shaderStages:.fragment,resource:.texture(step.b ?? Texture2D.whiteTexture)),
                .init(binding:15,shaderStages:.fragment,resource:.texture(step.c ?? Texture2D.whiteTexture))]),index:0)
            pass.draw(type:.triangle,vertexStart:0,vertexCount:3,instanceCount:1); pass.endRenderPass()
        }
        entry.status.encodedFrames += 1; entry.status.accumulatedFrames = min(entry.status.accumulatedFrames+1,settings.historyLimit)
        entry.status.hybridFirstHit = hybridSurface != nil
        entry.status.denoiser = denoiser.rawValue
        entry.status.denoiserFallback = settings.denoiser == .rayReconstruction && denoiser != .rayReconstruction ? reconstructionUnavailable : nil
        entry.previousViewProjection = viewProjection
        entry.previousView = uniform.viewMatrix
        entry.denoiser = denoiser
        entry.status.triangles = scene.triangleCount; entry.status.lights = lights.count/4; entry.status.width = size.width; entry.status.height = size.height
        entry.active = true; resources.entries[id] = entry; resources.lastFailure = nil; statistics.record(entry.status,view:id)
        if let metrics { command.addCompletedTimingHandler { metrics.record(pass:"pathTracing",seconds:$0) }; await metrics.commit(command) }
        else { command.commit() }
        return []
    }
}
