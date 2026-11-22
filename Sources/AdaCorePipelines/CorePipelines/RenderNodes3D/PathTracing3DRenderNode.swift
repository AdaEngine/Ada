import AdaAssets
import AdaECS
@_spi(Internal) import AdaRender
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
    /// `"vulkan-ray-query"` or `"portable-shader-bvh"` (see ``PathTracingTraversalSelection``).
    public var implementation = "portable-shader-bvh"
    /// Why GPU ray queries were not used, if they were not.
    public var intersectionFallback: String?
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
    func discard(_ view: Entity.ID) { _ = state.withLock { $0.removeValue(forKey: String(view)) } }
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
    var fogColor: Vector4
    var fogShape: Vector4
    var fogSun: Vector4
    var fogRadiance: Vector4
    var fogSky: Vector4
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
        /// The scene generation of the previous frame, to tell moving objects from an unchanged scene.
        var sceneGeneration: UInt64?
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
    var activeCameras: Set<Entity.ID> = []
    var uniforms = FrameUniformCache3D<PathTracing3DUniform>()
    var pipeline: (any RenderPipeline)?
    /// The ray-query variant of the trace pipeline, and the structures it traces.
    var hardwarePipeline: (any RenderPipeline)?
    var structures = PathTracing3DAccelerationStructures()
    /// The scene generation the top-level structure was built for.
    var structuresGeneration: UInt64?
    /// A failed structure build is scoped to its scene. The compiled shader is scoped to the device.
    var hardwareFailure: String?
    var failedSceneDigest: UInt64?
    var hardwareShaderFailure: String?
    var nearest: (any Sampler)?
    var linear: (any Sampler)?
    var lastFailure: String?

    /// Releases the acceleration structures, for example when no view traces any more.
    mutating func resetStructures(clearSceneFailure: Bool = true) {
        structures.removeAll()
        structuresGeneration = nil
        if clearSceneFailure {
            hardwareFailure = nil
            failedSceneDigest = nil
        }
    }

    static func buildInputDigest(_ sources: [Mesh3DRenderSource]) -> UInt64 {
        var hash = FrameDigest3D()
        for source in sources {
            hash.combine(UInt64(source.entity))
            hash.combine(source.transform)
            if source.instances != nil { hash.combine(UInt64(bitPattern: Int64(source.instanceRevision.id))) }
            for model in source.mesh.models {
                for part in model.parts {
                    hash.combine(UInt64(bitPattern: Int64(ObjectIdentifier(part.vertexBuffer).hashValue)))
                    hash.combine(UInt64(bitPattern: Int64(ObjectIdentifier(part.indexBuffer).hashValue)))
                    hash.combine(UInt64(part.indexCount))
                }
            }
        }
        return hash.value
    }

    /// The pipeline whose intersection step is a ray query, or nil when its shader variant cannot be created.
    mutating func getHardwarePipeline(_ device: RenderDevice) -> (any RenderPipeline)? {
        if let hardwarePipeline {
            return hardwarePipeline
        }
        guard hardwareShaderFailure == nil else {
            return nil
        }
        do {
            let module = try ShaderModule.createBuiltinVariant(
                at: "Shaders/path_tracing_3d.wesl",
                from: .adaModule,
                defines: ["ADA_PATH_TRACING_RAY_QUERY"]
            )
            var descriptor = RenderPipelineDescriptor(
                vertex: module.requiredShader(for: .vertex),
                fragment: module.getShader(for: .fragment),
                debugName: "World-space path tracing (ray query)",
                backfaceCulling: false,
                depthPixelFormat: .none
            )
            descriptor.colorAttachments = [.init(format: .rgba_16f)]
            let result = device.createRenderPipeline(from: descriptor)
            hardwarePipeline = result
            return result
        } catch {
            let reason = "The ray-query shader variant could not be created: \(error)"
            hardwareShaderFailure = reason
            FileHandle.standardError.write(Data("AdaEngine hardware path tracing unavailable: \(reason)\n".utf8))
            return nil
        }
    }

    mutating func getPipeline(_ device: RenderDevice) -> any RenderPipeline {
        if let pipeline {
            return pipeline
        }
        let shader = CorePipelineShaders.loadRequiredBuiltin("path_tracing_3d")
        var descriptor = RenderPipelineDescriptor(
            vertex: shader.asset.requiredShader(for: .vertex),
            fragment: shader.asset.getShader(for: .fragment),
            debugName: "World-space path tracing",
            backfaceCulling: false,
            depthPixelFormat: .none
        )
        descriptor.colorAttachments = [.init(format: .rgba_16f)]
        let result = device.createRenderPipeline(from: descriptor)
        pipeline = result
        nearest = device.createSampler(from: .init(minFilter: .nearest, magFilter: .nearest, mipFilter: .notMipmapped))
        linear = device.createSampler(from: .init(minFilter: .linear, magFilter: .linear, mipFilter: .notMipmapped))
        return result
    }
}

extension PathTracing3DViews {
    /// Builds the structures the ray-query variant traces: each new part's bottom-level structure, then the top-level
    /// structure when the scene or the set of structures changed. Encoded into `commands` ahead of the trace passes.
    mutating func buildStructures(
        scene: PathTracing3DScene,
        device: RenderDevice,
        commands: CommandBuffer
    ) -> (any AccelerationStructure)? {
        func fail(_ reason: String) -> (any AccelerationStructure)? {
            hardwareFailure = reason
            FileHandle.standardError.write(Data("AdaEngine hardware path tracing unavailable: \(reason)\n".utf8))
            return nil
        }
        if structuresGeneration == scene.generation, let top = structures.top {
            return top.structure
        }
        guard !scene.placements.isEmpty else {
            return fail("The scene has no traceable triangles for ray queries")
        }
        var rebuild = structuresGeneration != scene.generation
        var bottoms: [PathTracing3DPartKey: any AccelerationStructure] = [:]
        var newTriangles = 0
        var newParts = 0
        var moreParts = false
        for (key, part) in scene.parts {
            let count = key.indexCount / 3
            if structures.bottoms[key] == nil, newParts > 0, newParts >= 32 || newTriangles + count > 65_536 {
                moreParts = true
                continue
            }
            guard
                let resolved = structures.resolveBottom(
                    key,
                    triangleCount: count,
                    retaining: [part.vertexBuffer as AnyObject, part.indexBuffer as AnyObject],
                    create: {
                        device.createAccelerationStructure(.bottomLevel(triangleCapacity: $0))
                    }
                )
            else { return fail("A bottom-level acceleration structure could not be created") }
            bottoms[key] = resolved.structure
            guard resolved.isNew else { continue }
            rebuild = true
            newParts += 1
            newTriangles += count
            let positions = part.meshDescriptor.positions.elements
            var floats: [Float] = []
            floats.reserveCapacity(positions.count * 3)
            for position in positions { floats += [position.x, position.y, position.z] }
            var indices = Array(part.meshDescriptor.indicies.prefix(key.indexCount))
            guard !floats.isEmpty, !indices.isEmpty else {
                return fail("A part has no triangles for its acceleration structure")
            }
            let vertices = unsafe floats.withUnsafeMutableBytes { bytes -> Buffer? in
                guard let base = bytes.baseAddress else {
                    return nil
                }
                return unsafe device.createBuffer(label: "Path tracing BLAS vertices", bytes: base, length: bytes.count, options: .storageShared)
            }
            let elements = unsafe indices.withUnsafeMutableBytes { bytes -> IndexBuffer? in
                guard let base = bytes.baseAddress else {
                    return nil
                }
                return unsafe device.createIndexBuffer(format: .uInt32, bytes: UnsafeRawPointer(base), length: bytes.count)
            }
            guard let vertexBuffer = vertices, let indexBuffer = elements else {
                return fail("A part has no triangles for its acceleration structure")
            }
            let geometry = AccelerationStructureGeometry(
                vertexBuffer: vertexBuffer,
                vertexStride: 12,
                vertexCount: positions.count,
                indexBuffer: indexBuffer,
                indexCount: indices.count
            )
            do { try geometry.validate() } catch { return fail("Invalid acceleration structure geometry: \(error)") }
            guard commands.encodeBuild(of: resolved.structure, geometry: geometry) else {
                return fail("The device could not build a bottom-level acceleration structure")
            }
        }
        structures.retain(Set(scene.parts.keys))
        if moreParts {
            return nil
        }
        let plan = PathTracing3DInstancePlan.make(scene.placements)
        guard
            let top = structures.resolveTop(
                instanceCount: plan.instances.count,
                create: {
                    device.createAccelerationStructure(.topLevel(instanceCapacity: $0))
                }
            )
        else { return fail("The top-level acceleration structure could not be created") }
        if top.isNew { rebuild = true }
        if rebuild {
            let instances = plan.instances.compactMap { instance in
                bottoms[instance.key].map {
                    AccelerationStructureInstance(structure: $0, transform: instance.transform, mask: instance.mask, instanceID: instance.metadataIndex)
                }
            }
            guard instances.count == plan.instances.count, commands.encodeBuild(of: top.structure, instances: instances) else {
                return fail("The device could not build the top-level acceleration structure")
            }
            structuresGeneration = scene.generation
        }
        return top.structure
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
        views.update(from: world)
        _cameraTargets.update(from: world)
        _environments.update(from: world)
        _lighting.update(from: world)
        _resources.update(from: world)
        _statistics.update(from: world)
        _device.update(from: world)
        _metrics.update(from: world)
        // Extracted proxies themselves can still be deferred during graph update. Use the
        // camera identities collected from the source world, not those transient entities.
        let active = cameraTargets.activeCameraIDs
        if active != resources.activeCameras {
            let removed = resources.activeCameras.subtracting(active)
            for id in removed {
                resources.entries.removeValue(forKey: id)
                statistics.discard(id)
            }
            if !removed.isEmpty && resources.entries.isEmpty {
                resources.scene = PathTracing3DScene()
                resources.resetStructures()
            }
            resources.activeCameras = active
        }
        resources.uniforms.retainViews(Array(active))
    }

    public func execute(context: inout Context, renderContext: RenderContext) async throws -> [RenderSlotValue] {
        guard let view = context.viewEntity else {
            return []
        }
        var selected: (RenderViewTarget, GlobalViewUniform, Entity.ID)?
        views.forEach { entity, target, uniform, source in if entity == view { selected = (target, uniform, source.entityId) } }
        guard let (target, uniform, id) = selected else {
            return []
        }
        let environment = environments.environments[id] ?? .init()
        let settings = environment.pathTracing.sanitized
        guard settings.isEnabled, environment.debugView != .meshlets, !environment.debugView.showsWireframe, let color = target.sceneColor3DTexture,
            let normal = target.normalRoughness3DTexture, let position = target.viewPositionMetallic3DTexture
        else {
            resources.entries.removeValue(forKey: id)
            statistics.discard(id)
            if resources.entries.isEmpty {
                resources.scene = PathTracing3DScene()
                resources.resetStructures()
            }
            return []
        }
        // Raster-only detail is seen through the G-buffer first hit; the tracer intersects its proxies instead.
        let sources = context.world.getResource(ExtractedMesh3DSources.self)?.pathTracedMeshes ?? []
        var scene = resources.scene
        if let failed = resources.failedSceneDigest, failed != PathTracing3DViews.buildInputDigest(sources) { resources.resetStructures() }
        let sceneBlocker =
            sources.contains { $0.skinningBuffer != nil }
            ? "Skinned meshes are not supported by hardware ray queries" : resources.hardwareShaderFailure ?? resources.hardwareFailure
        var selection = PathTracingTraversalSelection.select(
            settings.intersection,
            deviceSupportsRayQueries: device.renderDevice.supportsRayQueries,
            sceneBlocker: sceneBlocker
        )
        if selection.traversal == .hardwareRayQuery, resources.getHardwarePipeline(device.renderDevice) == nil {
            selection = PathTracingTraversalSelection.select(
                settings.intersection,
                deviceSupportsRayQueries: true,
                sceneBlocker: resources.hardwareShaderFailure
            )
        }
        var hardware = selection.traversal == .hardwareRayQuery
        do {
            try await scene.prepare(
                sources,
                skinning: context.world.getResource(Skinning3DUniforms.self),
                device: device.renderDevice,
                textureTileSize: settings.textureTileSize,
                hardwareOrder: hardware,
                hardwareTriangleStep: 65_536
            )
            if hardware, scene.placements.isEmpty {
                // Nothing to trace is not a hardware failure: use the shader BVH for this scene, and retry hardware when it changes.
                hardware = false
                selection = PathTracingTraversalSelection(traversal: .softwareBVH, fallbackReason: "The scene has no traceable triangles for ray queries")
                try await scene.prepare(
                    sources,
                    skinning: context.world.getResource(Skinning3DUniforms.self),
                    device: device.renderDevice,
                    textureTileSize: settings.textureTileSize,
                    hardwareOrder: false
                )
            }
        } catch PathTracing3DError.preparingGeometry {
            resources.scene = scene
            resources.entries.removeValue(forKey: id)
            statistics.discard(id)
            return []
        } catch {
            let reason = [selection.fallbackReason, String(describing: error)].compactMap { $0 }.joined(separator: ". ")
            var status = PathTracing3DStatus()
            status.failure = reason
            status.intersectionFallback = selection.fallbackReason
            statistics.record(status, view: id)
            resources.entries.removeValue(forKey: id)
            if resources.entries.isEmpty {
                resources.scene = PathTracing3DScene()
                resources.resetStructures(clearSceneFailure: false)
            }
            if resources.lastFailure != reason {
                FileHandle.standardError.write(Data("AdaEngine path tracing unavailable: \(reason)\n".utf8))
                resources.lastFailure = reason
            }
            return []
        }
        resources.scene = scene
        // Ray Reconstruction needs DLSS temporal upscaling of this view and G-buffer guides; it then traces at input size,
        // because it reconstructs from input-resolution samples (resolutionScale applies to the other denoisers).
        let hybridAvailable = target.pathTracingSurfaceActive && target.diffuseSurface3DTexture != nil && target.reflectionResponse3DTexture != nil
        let reconstructionUnavailable: String? =
            !target.temporalUpscalingActive || !target.rayReconstructionAvailable
            ? "DLSS Ray Reconstruction is unavailable for this view"
            : !hybridAvailable ? "Ray Reconstruction needs the G-buffer first hit" : nil
        let usesReconstruction = reconstructionUnavailable == nil && (settings.denoiser == .automatic || settings.denoiser == .rayReconstruction)
        let size =
            usesReconstruction
            ? color.size
            : SizeInt(width: max(1, Int(Float(color.size.width) * settings.resolutionScale)), height: max(1, Int(Float(color.size.height) * settings.resolutionScale)))
        var entry = resources.entries.removeValue(forKey: id)
        if entry?.targets.first?.size != size {
            func texture(_ label: String) -> RenderTexture { RenderTexture(size: size, scaleFactor: 1, format: .rgba_16f, debugLabel: label) }
            entry = .init(
                targets: (0..<2).map { _ in texture("Path tracing accumulation") },
                trace: texture("Path tracing samples"),
                guides: (0..<2).map { _ in texture("Path tracing reprojection guide") },
                filters: (0..<2).map { _ in texture("Path tracing wavelet filter") }
            )
        }
        guard var entry, let nodes = scene.nodes, let triangles = scene.triangles, let materials = scene.materials, let atlas = scene.atlas else {
            return []
        }
        let denoiser: PathTracingDenoiser
        switch settings.denoiser {
        case .off: denoiser = .off
        case .portable: denoiser = .portable
        case .automatic, .rayReconstruction: denoiser = usesReconstruction ? .rayReconstruction : .portable
        }
        let denoises = denoiser != .off
        var hash = FrameDigest3D()
        // Denoised views keep their history while objects move (the reprojection guides reject history that no longer
        // matches); only a change of the scene's content restarts it. Plain accumulation restarts on any change.
        hash.combine(denoises ? scene.structureGeneration : scene.generation)
        if !denoises {
            hash.combine(uniform.viewMatrix)
            hash.combine(uniform.projectionMatrix)
        }
        hash.combine(UInt64(denoiser == .off ? 0 : (denoiser == .portable ? 1 : 2)))
        hash.combine(hardware ? UInt64(1) : 0)
        hash.combine(hybridAvailable ? UInt64(1) : 0)
        hash.combine(UInt64(settings.samplesPerPixel))
        hash.combine(UInt64(settings.maximumBounces))
        hash.combine(UInt64(settings.historyLimit))
        hash.combine(settings.maximumDistance)
        hash.combine(settings.rayBias)
        hash.combine(settings.maximumRadiance)
        var lights: [Vector4] = []
        let suns = lighting.directionalLights.isEmpty ? lighting.directionalLight.map { [$0] } ?? [] : lighting.directionalLights
        for sun in suns
        where sun.intensity.isFinite && sun.intensity > 0 && LocalLighting3DMath.isFinite(sun.directionToLight)
            && sun.directionToLight.squaredLength > 0.000001 && LocalLighting3DMath.isFinite(sun.radiance) {
            let angle = finiteRenderValue(environment.shadows.lightAngularRadius, fallback: 0.27, range: 0...10) * Float.pi / 180
            lights += [
                Vector4(sun.directionToLight.normalized, 0), Vector4(sun.radiance * sun.intensity, 0), Vector4(0, 0, 0, sun.castsShadows ? 1 : 0),
                Vector4(0, 0, Math.tanf(angle), 0),
            ]
        }
        for lamp in lighting.localLights
        where lamp.intensity.isFinite && lamp.intensity > 0 && lamp.range.isFinite && lamp.range > 0
            && LocalLighting3DMath.isFinite(lamp.position) && LocalLighting3DMath.isFinite(lamp.radiance) {
            guard lamp.kind == .point || (LocalLighting3DMath.isFinite(lamp.direction) && lamp.direction.squaredLength > 0.000001) else { continue }
            let cone = LocalLighting3DMath.coneCosines(inner: lamp.innerConeAngle, outer: lamp.outerConeAngle)
            lights += [
                Vector4(lamp.position, lamp.kind == .point ? 1 : 2), Vector4(lamp.radiance * lamp.intensity, lamp.range),
                Vector4(lamp.direction, lamp.castsShadows ? 1 : 0), Vector4(cone.x, cone.y, 0, 0),
            ]
        }
        if denoises {
            // Moving lights keep history (reprojection and the history weight fade it); adding, removing, switching
            // or retuning a light restarts it. Records: position|direction + kind, radiance + range, axis + shadows, cone.
            hash.combine(UInt64(lights.count))
            for index in stride(from: 0, to: lights.count, by: 4) {
                hash.combine(lights[index].w)
                hash.combine(lights[index + 1])
                hash.combine(lights[index + 2].w)
                hash.combine(lights[index + 3])
            }
        } else {
            for value in lights { hash.combine(value) }
        }
        let sky = environment.skybox
        let linearEnvironment = environment.skyboxUsesImageBasedLighting && environment.imageBasedLighting?.asset.asset?.radiance != nil
        let environmentTexture =
            environment.skyboxUsesImageBasedLighting ? environment.imageBasedLighting?.asset.asset?.radiance ?? sky.texture?.asset : sky.texture?.asset
        let intensity =
            environment.skyboxUsesImageBasedLighting && environment.imageBasedLighting?.asset.asset?.radiance != nil
            ? environment.imageBasedLighting?.intensity ?? 1 : sky.intensity
        let skyParameters = Vector4(environmentTexture == nil ? 0 : 1, max(0, intensity), environment.imageBasedLighting?.rotation ?? 0, sky.isEnabled ? 1 : 0)
        hash.combine(sky.zenithColor.asVector)
        hash.combine(sky.horizonColor.asVector)
        hash.combine(sky.groundColor.asVector)
        hash.combine(skyParameters)
        hash.combine(linearEnvironment ? UInt64(1) : 0)
        if let environmentTexture { hash.combine(UInt64(bitPattern: Int64(ObjectIdentifier(environmentTexture).hashValue))) }
        // Hybrid views already have raster primary depth for the regular fog compositor.
        let fog = environment.fog.sanitized
        let tracesHeightFog = hardware && !hybridAvailable && fog.changesImage
        let fogSun = lighting.directionalLight
        let fogColor = Vector4(fog.color.asVector.xyz, tracesHeightFog ? fog.density : 0)
        let fogShape = Vector4(fog.heightFalloff, fog.baseHeight, fog.startDistance, fog.maximumOpacity)
        let fogDirection = Vector4(fogSun?.directionToLight.normalized ?? .up, fog.volumetricActive ? 0 : fog.sunInscattering)
        let fogRadiance = Vector4(fogSun.map { $0.radiance * $0.intensity } ?? .zero, fog.sunExponent)
        let fogSky = Vector4(fog.skyInfluence, 0, 0, 0)
        if tracesHeightFog {
            hash.combine(fogColor)
            hash.combine(fogShape)
            hash.combine(fogDirection)
            hash.combine(fogRadiance)
            hash.combine(fogSky)
        }
        let historyRestarted = entry.digest != hash.value || entry.denoiser != denoiser
        // Objects moved since the last frame: follow the new lighting faster than a still scene would.
        let objectsMoved = denoises && !historyRestarted && entry.sceneGeneration != nil && entry.sceneGeneration != scene.generation
        entry.sceneGeneration = scene.generation
        if entry.digest != hash.value {
            entry.status.accumulatedFrames = 0
            entry.status.historyResets += 1
            entry.digest = hash.value
        }
        let previous = entry.index
        entry.index = 1 - entry.index
        let current = entry.index
        let softwarePipeline = resources.getPipeline(device.renderDevice)
        let pipeline = hardware ? resources.hardwarePipeline ?? softwarePipeline : softwarePipeline
        guard let nearest = resources.nearest, let linear = resources.linear else {
            return []
        }
        var lightDigest = FrameDigest3D()
        for value in lights { lightDigest.combine(value) }
        lightDigest.combine(UInt64(lights.count))
        let lightTexture: Texture2D
        if let table = entry.lightTable, entry.lightTableDigest == lightDigest.value {
            lightTexture = table
        } else {
            lightTexture = PathTracing3DScene.dataTexture(lights, label: "Path tracing all lights")
            entry.lightTable = lightTexture
            entry.lightTableDigest = lightDigest.value
            entry.lightTableBuilds += 1
        }
        // Full-detail first hit: base colour and emission written by the main pass for path-traced views.
        let hybridSurface =
            target.pathTracingSurfaceActive
            ? target.diffuseSurface3DTexture.flatMap { albedo in target.reflectionResponse3DTexture.map { (albedo, $0) } } : nil
        let jittered = temporalViewUniform(uniform, target: target)
        let viewProjection = uniform.projectionMatrix * uniform.viewMatrix
        // A stronger denoiser also averages over more frames, and follows moving objects a little slower (it smooths harder).
        let baseHistoryWeight = max(0.005, settings.minimumHistoryWeight / settings.denoiserStrength)
        let historyWeight = objectsMoved ? max(baseHistoryWeight, PathTracing3D.movingHistoryWeight / settings.denoiserStrength.squareRoot()) : baseHistoryWeight
        var constants = PathTracing3DUniform(
            inverseProjection: jittered.projectionMatrix.inverse,
            inverseView: uniform.viewMatrix.inverse,
            counts: Vector4(Float(scene.nodeCount), Float(lights.count / 4), Float(settings.samplesPerPixel), Float(settings.maximumBounces)),
            trace: Vector4(settings.maximumDistance, settings.rayBias, settings.maximumRadiance, Float(min(entry.status.accumulatedFrames, settings.historyLimit - 1))),
            frame: Vector4(Float(entry.status.encodedFrames % 1_000_000), 0, Float(atlas.height / scene.tileSize), linearEnvironment ? 1 : 0),
            zenith: sky.zenithColor.asVector,
            horizon: sky.horizonColor.asVector,
            ground: sky.groundColor.asVector,
            sky: skyParameters,
            hybrid: Vector4(hybridSurface == nil ? 0 : 1, settings.denoiserStrength, 0, 0),
            previousViewProjection: entry.previousViewProjection ?? viewProjection,
            previousView: entry.previousView ?? uniform.viewMatrix,
            denoise: Vector4(
                1,
                historyWeight,
                denoises ? 1 : 0,
                denoises ? 1 : 0
            ),
            fogColor: fogColor,
            fogShape: fogShape,
            fogSun: fogDirection,
            fogRadiance: fogRadiance,
            fogSky: fogSky
        )
        // Shader passes: 0 trace, 1 temporal, 2 guide, 3 wavelet, 4 final. Inputs never alias the pass's destination.
        struct Step {
            var shader: Int
            var destination: RenderTexture
            var a: Texture
            var b: Texture?
            var c: Texture?
            var spacing: Float
            var label: String
        }
        var steps: [Step] = []
        entry.rayReconstructionGuides = nil
        if denoiser == .rayReconstruction {
            // One fresh sample per frame: Ray Reconstruction keeps its own history and denoises at upscale.
            constants.trace.w = 0
            constants.denoise.z = 0
            constants.denoise.w = 0
            if entry.guideTargets.first?.size != size {
                entry.guideTargets = ["Path tracing RR diffuse albedo", "Path tracing RR specular albedo", "Path tracing RR normal roughness"]
                    .map { RenderTexture(size: size, scaleFactor: 1, format: .rgba_16f, debugLabel: $0) }
            }
            steps.append(Step(shader: 0, destination: entry.trace, a: entry.targets[previous], b: nil, c: nil, spacing: 1, label: "Path tracing rays"))
            for (selector, guide) in entry.guideTargets.enumerated() {
                steps.append(Step(shader: 5, destination: guide, a: entry.trace, b: nil, c: nil, spacing: Float(selector), label: "Path tracing RR guide"))
            }
            steps.append(Step(shader: 4, destination: color, a: entry.trace, b: nil, c: nil, spacing: 1, label: "Path tracing reconstruction"))
            entry.rayReconstructionGuides = RayReconstructionGuides(
                diffuseAlbedo: entry.guideTargets[0],
                specularAlbedo: entry.guideTargets[1],
                normalRoughness: entry.guideTargets[2],
                worldToView: uniform.viewMatrix,
                viewToClip: uniform.projectionMatrix,
                reset: historyRestarted
            )
        } else if denoises {
            steps.append(Step(shader: 0, destination: entry.trace, a: entry.targets[previous], b: nil, c: nil, spacing: 1, label: "Path tracing rays"))
            steps.append(
                Step(
                    shader: 1,
                    destination: entry.targets[current],
                    a: entry.trace,
                    b: entry.targets[previous],
                    c: entry.guides[previous],
                    spacing: 1,
                    label: "Path tracing temporal reprojection"
                )
            )
            steps.append(Step(shader: 2, destination: entry.guides[current], a: entry.trace, b: nil, c: nil, spacing: 1, label: "Path tracing reprojection guide"))
            var input: Texture = entry.targets[current]
            // Strong denoising adds a wider final step on top of the four plain iterations.
            let spacings: [Float] = settings.denoiserStrength >= 2 ? [1, 2, 4, 8, 16] : [1, 2, 4, 8]
            for (iteration, spacing) in spacings.enumerated() {
                let output = entry.filters[iteration % 2]
                steps.append(Step(shader: 3, destination: output, a: input, b: nil, c: nil, spacing: spacing, label: "Path tracing wavelet filter"))
                input = output
            }
            steps.append(Step(shader: 4, destination: color, a: input, b: nil, c: nil, spacing: 1, label: "Path tracing reconstruction"))
        } else {
            steps.append(Step(shader: 0, destination: entry.targets[current], a: entry.targets[previous], b: nil, c: nil, spacing: 1, label: "Path tracing rays"))
            steps.append(Step(shader: 4, destination: color, a: entry.targets[current], b: nil, c: nil, spacing: 1, label: "Path tracing reconstruction"))
        }
        let command = renderContext.commandQueue.makeCommandBuffer()
        command.label = "World-space path tracing"
        var topLevel: (any AccelerationStructure)?
        if hardware {
            topLevel = resources.buildStructures(scene: scene, device: device.renderDevice, commands: command)
            if topLevel == nil {
                if resources.hardwareFailure == nil {
                    statistics.discard(id)
                    command.commit()
                    return []
                }
                // Software tracing resumes next frame; this frame's trace pass cannot run without its structure.
                resources.failedSceneDigest = PathTracing3DViews.buildInputDigest(sources)
                resources.entries[id] = nil
                resources.resetStructures(clearSceneFailure: false)
                var status = PathTracing3DStatus()
                status.failure = resources.hardwareFailure
                status.intersectionFallback = resources.hardwareFailure
                statistics.record(status, view: id)
                command.commit()
                return []
            }
        }
        for (passIndex, step) in steps.enumerated() {
            let destination = step.destination
            constants.frame.y = Float(step.shader)
            constants.denoise.x = step.spacing
            let buffer = resources.uniforms.write(constants, view: id, pass: passIndex, device: device.renderDevice)
            let label = step.label
            let pass = command.beginRenderPass(
                .init(
                    label: label,
                    colorAttachments: [.init(texture: destination, operation: .init(loadAction: .clear, storeAction: .store))]
                )
            )
            pass.setViewport(Rect(x: 0, y: 0, width: Float(destination.size.width), height: Float(destination.size.height)))
            pass.setRenderPipelineState(pipeline)
            pass.setFragmentBuffer(buffer, offset: 0, slot: 4)
            pass.setResourceSet(
                .init(
                    bindings: [
                        .init(binding: 0, shaderStages: .fragment, resource: .texture(nodes)), .init(binding: 1, shaderStages: .fragment, resource: .texture(triangles)),
                        .init(binding: 2, shaderStages: .fragment, resource: .texture(materials)), .init(binding: 3, shaderStages: .fragment, resource: .texture(atlas)),
                        .init(binding: 5, shaderStages: .fragment, resource: .texture(lightTexture)),
                        .init(binding: 6, shaderStages: .fragment, resource: .texture(step.a)),
                        .init(binding: 7, shaderStages: .fragment, resource: .texture(environmentTexture ?? Texture2D.whiteTexture)),
                        .init(binding: 8, shaderStages: .fragment, resource: .sampler(nearest)), .init(binding: 9, shaderStages: .fragment, resource: .sampler(linear)),
                        .init(binding: 10, shaderStages: .fragment, resource: .texture(normal)),
                        .init(binding: 11, shaderStages: .fragment, resource: .texture(position)),
                        .init(binding: 12, shaderStages: .fragment, resource: .texture(hybridSurface?.0 ?? Texture2D.whiteTexture)),
                        .init(binding: 13, shaderStages: .fragment, resource: .texture(hybridSurface?.1 ?? Texture2D.whiteTexture)),
                        .init(binding: 14, shaderStages: .fragment, resource: .texture(step.b ?? Texture2D.whiteTexture)),
                        .init(binding: 15, shaderStages: .fragment, resource: .texture(step.c ?? Texture2D.whiteTexture)),
                    ]
                        + (topLevel.map {
                            [
                                .init(binding: 16, shaderStages: .fragment, resource: .accelerationStructure($0)),
                                .init(binding: 17, shaderStages: .fragment, resource: .texture(scene.terrainFields ?? Texture2D.whiteTexture)),
                            ]
                        } ?? [])
                ),
                index: 0
            )
            pass.draw(type: .triangle, vertexStart: 0, vertexCount: 3, instanceCount: 1)
            pass.endRenderPass()
        }
        entry.status.encodedFrames += 1
        entry.status.accumulatedFrames = min(entry.status.accumulatedFrames + 1, settings.historyLimit)
        entry.status.hybridFirstHit = hybridSurface != nil
        entry.status.implementation = selection.traversal.rawValue
        entry.status.intersectionFallback = selection.fallbackReason
        entry.status.denoiser = denoiser.rawValue
        entry.status.denoiserFallback = settings.denoiser == .rayReconstruction && denoiser != .rayReconstruction ? reconstructionUnavailable : nil
        entry.previousViewProjection = viewProjection
        entry.previousView = uniform.viewMatrix
        entry.denoiser = denoiser
        entry.status.triangles = scene.triangleCount
        entry.status.lights = lights.count / 4
        entry.status.width = size.width
        entry.status.height = size.height
        entry.active = true
        resources.entries[id] = entry
        resources.lastFailure = nil
        statistics.record(entry.status, view: id)
        if let metrics {
            command.addCompletedTimingHandler { metrics.record(pass: "pathTracing", seconds: $0) }
            await metrics.commit(command)
        } else {
            command.commit()
        }
        return []
    }
}
