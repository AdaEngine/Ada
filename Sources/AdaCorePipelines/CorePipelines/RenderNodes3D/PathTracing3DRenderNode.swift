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
}

struct PathTracing3DViews: Resource {
    struct Entry: Sendable {
        var targets: [RenderTexture]
        var filtered: RenderTexture
        var index = 0
        var digest: UInt64?
        var status = PathTracing3DStatus()
        var active = false
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
        let shader = CorePipelineShaders.loadRequiredBundled(at:"Shaders/path_tracing_3d.glsl")
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
    @Res<ExtractedEnvironment3D> private var environments
    @Res<ExtractedLighting3D> private var lighting
    @ResMut<PathTracing3DViews> private var resources
    @Res<Render3DPathTracingStatistics> private var statistics
    @Res<RenderDeviceHandler> private var device
    @Res<Render3DPerformanceMetrics?> private var metrics
    public init() {}

    public func update(from world: World) {
        views.update(from:world); _environments.update(from:world); _lighting.update(from:world)
        _resources.update(from:world); _statistics.update(from:world); _device.update(from:world); _metrics.update(from:world)
        var active: [Entity.ID] = []
        views.forEach { _,_,_,source in active.append(source.entityId) }
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
        guard settings.isEnabled, let color = target.sceneColor3DTexture,
            let normal = target.normalRoughness3DTexture, let position = target.viewPositionMetallic3DTexture else {
            resources.entries.removeValue(forKey:id); statistics.discard(id)
            if resources.entries.isEmpty { resources.scene = PathTracing3DScene() }
            return []
        }
        let sources = context.world.getResource(ExtractedMesh3DSources.self)?.meshes ?? []
        var scene = resources.scene
        do { try await scene.prepare(sources,skinning:context.world.getResource(Skinning3DUniforms.self),device:device.renderDevice) }
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
        let size = SizeInt(width:max(1,Int(Float(color.size.width)*settings.resolutionScale)),height:max(1,Int(Float(color.size.height)*settings.resolutionScale)))
        var entry = resources.entries.removeValue(forKey:id)
        if entry?.targets.first?.size != size {
            entry = .init(targets:(0..<2).map { _ in RenderTexture(size:size,scaleFactor:1,format:.rgba_16f,debugLabel:"Path tracing accumulation") },
                filtered:RenderTexture(size:size,scaleFactor:1,format:.rgba_16f,debugLabel:"Path tracing spatial filter"))
        }
        guard var entry, let nodes = scene.nodes, let triangles = scene.triangles, let materials = scene.materials, let atlas = scene.atlas else { return [] }
        var hash = FrameDigest3D()
        hash.combine(scene.generation); hash.combine(uniform.viewMatrix); hash.combine(uniform.projectionMatrix)
        hash.combine(UInt64(settings.samplesPerPixel)); hash.combine(UInt64(settings.maximumBounces)); hash.combine(UInt64(settings.historyLimit))
        hash.combine(settings.maximumDistance); hash.combine(settings.rayBias); hash.combine(settings.maximumRadiance)
        var lights: [Vector4] = []
        let suns = lighting.directionalLights.isEmpty ? lighting.directionalLight.map { [$0] } ?? [] : lighting.directionalLights
        for sun in suns where sun.intensity.isFinite && sun.intensity > 0 && LocalLighting3DMath.isFinite(sun.directionToLight)
            && sun.directionToLight.squaredLength > 0.000001 && LocalLighting3DMath.isFinite(sun.radiance) {
            let angle = finiteRenderValue(environment.shadows.lightAngularRadius,fallback:0.27,range:0...10)*Float.pi/180
            lights += [Vector4(sun.directionToLight.normalized,0),Vector4(sun.radiance*sun.intensity,0),Vector4(0,0,0,sun.castsShadows ? 1 : 0),Vector4(0,0,tan(angle),0)]
        }
        for lamp in lighting.localLights where lamp.intensity.isFinite && lamp.intensity > 0 && lamp.range.isFinite && lamp.range > 0
            && LocalLighting3DMath.isFinite(lamp.position) && LocalLighting3DMath.isFinite(lamp.radiance) {
            guard lamp.kind == .point || (LocalLighting3DMath.isFinite(lamp.direction) && lamp.direction.squaredLength > 0.000001) else { continue }
            let cone = LocalLighting3DMath.coneCosines(inner:lamp.innerConeAngle,outer:lamp.outerConeAngle)
            lights += [Vector4(lamp.position,lamp.kind == .point ? 1 : 2),Vector4(lamp.radiance*lamp.intensity,lamp.range),
                Vector4(lamp.direction,lamp.castsShadows ? 1 : 0),Vector4(cone.x,cone.y,0,0)]
        }
        for value in lights { hash.combine(value) }
        let sky = environment.skybox
        let linearEnvironment = environment.skyboxUsesImageBasedLighting && environment.imageBasedLighting?.asset.asset?.radiance != nil
        let environmentTexture = environment.skyboxUsesImageBasedLighting ? environment.imageBasedLighting?.asset.asset?.radiance ?? sky.texture?.asset : sky.texture?.asset
        let intensity = environment.skyboxUsesImageBasedLighting && environment.imageBasedLighting?.asset.asset?.radiance != nil ? environment.imageBasedLighting?.intensity ?? 1 : sky.intensity
        let skyParameters = Vector4(environmentTexture == nil ? 0 : 1,max(0,intensity),environment.imageBasedLighting?.rotation ?? 0,sky.isEnabled ? 1 : 0)
        hash.combine(sky.zenithColor.asVector); hash.combine(sky.horizonColor.asVector); hash.combine(sky.groundColor.asVector); hash.combine(skyParameters)
        hash.combine(linearEnvironment ? UInt64(1) : 0)
        if let environmentTexture { hash.combine(UInt64(bitPattern:Int64(ObjectIdentifier(environmentTexture).hashValue))) }
        if entry.digest != hash.value { entry.status.accumulatedFrames = 0; entry.status.historyResets += 1; entry.digest = hash.value }
        let history = entry.targets[entry.index]
        entry.index = 1-entry.index
        let output = entry.targets[entry.index]
        let pipeline = resources.getPipeline(device.renderDevice)
        guard let nearest = resources.nearest, let linear = resources.linear else { return [] }
        let lightTexture = PathTracing3DScene.dataTexture(lights,label:"Path tracing all lights")
        let jittered = temporalViewUniform(uniform,target:target)
        var constants = PathTracing3DUniform(inverseProjection:jittered.projectionMatrix.inverse,inverseView:uniform.viewMatrix.inverse,
            counts:Vector4(Float(scene.nodeCount),Float(lights.count/4),Float(settings.samplesPerPixel),Float(settings.maximumBounces)),
            trace:Vector4(settings.maximumDistance,settings.rayBias,settings.maximumRadiance,Float(min(entry.status.accumulatedFrames,settings.historyLimit-1))),
            frame:Vector4(Float(entry.status.encodedFrames%1000000),0,Float(atlas.height/PathTracing3DScene.tileSize),linearEnvironment ? 1 : 0),
            zenith:sky.zenithColor.asVector,horizon:sky.horizonColor.asVector,ground:sky.groundColor.asVector,sky:skyParameters)
        let command = renderContext.commandQueue.makeCommandBuffer(); command.label = "World-space path tracing"
        for passIndex in 0..<3 {
            let destination = passIndex == 0 ? output : (passIndex == 1 ? entry.filtered : color)
            constants.frame.y = Float(passIndex)
            let buffer = resources.uniforms.write(constants,view:id,pass:passIndex,device:device.renderDevice)
            let label = passIndex == 0 ? "Path tracing rays" : (passIndex == 1 ? "Path tracing spatial filter" : "Path tracing reconstruction")
            let pass = command.beginRenderPass(.init(label:label,
                colorAttachments:[.init(texture:destination,operation:.init(loadAction:.clear,storeAction:.store))]))
            pass.setViewport(Rect(x:0,y:0,width:Float(destination.size.width),height:Float(destination.size.height)))
            pass.setRenderPipelineState(pipeline); pass.setFragmentBuffer(buffer,offset:0,slot:4)
            pass.setResourceSet(.init(bindings:[
                .init(binding:0,shaderStages:.fragment,resource:.texture(nodes)), .init(binding:1,shaderStages:.fragment,resource:.texture(triangles)),
                .init(binding:2,shaderStages:.fragment,resource:.texture(materials)), .init(binding:3,shaderStages:.fragment,resource:.texture(atlas)),
                .init(binding:5,shaderStages:.fragment,resource:.texture(lightTexture)),
                .init(binding:6,shaderStages:.fragment,resource:.texture(passIndex == 0 ? history : (passIndex == 1 ? output : entry.filtered))),
                .init(binding:7,shaderStages:.fragment,resource:.texture(environmentTexture ?? Texture2D.whiteTexture)),
                .init(binding:8,shaderStages:.fragment,resource:.sampler(nearest)), .init(binding:9,shaderStages:.fragment,resource:.sampler(linear)),
                .init(binding:10,shaderStages:.fragment,resource:.texture(normal)), .init(binding:11,shaderStages:.fragment,resource:.texture(position))]),index:0)
            pass.draw(type:.triangle,vertexStart:0,vertexCount:3,instanceCount:1); pass.endRenderPass()
        }
        entry.status.encodedFrames += 1; entry.status.accumulatedFrames = min(entry.status.accumulatedFrames+1,settings.historyLimit)
        entry.status.triangles = scene.triangleCount; entry.status.lights = lights.count/4; entry.status.width = size.width; entry.status.height = size.height
        entry.active = true; resources.entries[id] = entry; resources.lastFailure = nil; statistics.record(entry.status,view:id)
        if let metrics { command.addCompletedTimingHandler { metrics.record(pass:"pathTracing",seconds:$0) }; await metrics.commit(command) }
        else { command.commit() }
        return []
    }
}
