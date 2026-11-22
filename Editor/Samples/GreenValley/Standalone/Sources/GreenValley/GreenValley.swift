import AdaEngine

import Foundation

import Math

import Observation

// Window presentation runs asynchronously on SAGA. Keep at most two submitted frames
// in flight so a fast update loop cannot accumulate terrain draws behind the display.

@main
struct GreenValley: App {
    var body: some AppScene {
        DefaultAppWindow()
            .addPlugins(ValleyScene())
            .windowTitle("Green Valley")
            .minimumSize(width: 1920, height: 1080)
            .windowMode(.windowed)
    }
}
private enum Valley {
    static let startZ: Float = -300
    static func trail(_ z: Float) -> Float { 36 * Math.sin(z / 180) }
}
private struct ValleyVoxelCanopy: Decodable {
    struct Tile: Decodable {
        let file: String
        let treeDistance: Float
        let bounds: AABB
    }

    let tiles: [Tile]

    @MainActor
    static func spawn(in app: AppWorlds, assets: URL) -> [(Entity, Tile)] {
        let file = assets.appendingPathComponent("VoxelForest.json")
        guard let data = try? Data(contentsOf: file), let forest = try? JSONDecoder().decode(Self.self, from: data) else {
            return []
        }
        let canopy = app.spawn("Distant voxel canopy") {
            Transform()
            PathTracingGeometry3D.rasterOnly
        }
        return forest.tiles.map { tile in
            let entity = app.spawn(tile.file) {
                Transform()
                Model3DSource(source: assets.appendingPathComponent(tile.file).path)
                Visibility.hidden
            }
            canopy.addChild(entity)
            return (entity, tile)
        }
    }
}
private struct ValleyScene: Plugin {
    func setup(in app: AppWorlds) {
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        let bundled = executable.deletingLastPathComponent().appendingPathComponent("Assets/Terrain").path
        let directory =
            ProcessInfo.processInfo.environment["GREEN_VALLEY_TERRAIN"]
            ?? (FileManager.default.fileExists(atPath: bundled) ? bundled : "Editor/Samples/GreenValley/Assets/Terrain")
        let assets = URL(fileURLWithPath: directory, isDirectory: true).standardizedFileURL
        let manifest = assets.appendingPathComponent("Valley.aterrain").path
        guard FileManager.default.fileExists(atPath: manifest) else {
            print("Green Valley could not find its terrain at \(manifest)")
            return
        }
        app.addSystem(ValleyFramePacing.self, on: .preUpdate)
        app.addPlugin(Physics3DPlugin())
        let valley = app.spawn("Valley terrain and vegetation") {
            Transform()
            Terrain3DSource(
                source: manifest,
                color: [1, 1, 1, 1],
                maximumMeshBytes: 384 * 1024 * 1024,
                lodDistance: 85,
                streamingRadius: nil,
                cameraRefreshDistance: 12
            )
        }
        let forest = app.spawn("Coastal forest") {
            Transform()
            Terrain3DSource(source: assets.appendingPathComponent("Forest.aterrain").path, generatesCollision: false, streamingRadius: 1020, cameraRefreshDistance: 40)
        }
        let grass = app.spawn("Valley grass") {
            Transform()
            Terrain3DSource(
                source: assets.appendingPathComponent("Grass.aterrain").path,
                generatesCollision: false,
                maximumLOD: 0,
                streamingRadius: 200,
                cameraRefreshDistance: 16
            )
        }
        app.spawn("Distant ridges") {
            Transform()
            Model3DSource(source: assets.appendingPathComponent("horizon.glb").path)
        }
        var environment = Environment3D()
        environment.screenSpaceReflection.isEnabled = false
        environment.screenSpaceGI.isEnabled = false
        environment.ambientOcclusion.isEnabled = false
        environment.shadowCascadeCount = 1
        environment.postProcess.bloom.isEnabled = false
        environment.skyHorizonColor = Color(red: 0.78, green: 0.83, blue: 0.84)
        environment.skyZenithColor = Color(red: 0.16, green: 0.35, blue: 0.62)
        environment.fog = Fog3D(
            isEnabled: true,
            color: Color(red: 0.73, green: 0.80, blue: 0.84),
            density: 0.0017,
            heightFalloff: 0.0045,
            baseHeight: 35,
            startDistance: 70,
            maximumOpacity: 0.96,
            skyInfluence: 0.25,
            sunInscattering: 0.12,
            sunExponent: 12
        )
        environment.pathTracing = .init(isEnabled: false, samplesPerPixel: 1, maximumBounces: 2, resolutionScale: 0.5)
        environment.pathTracing.maximumDistance = 6500
        environment.pathTracing.rasterFirstHit = false
        let cameraEntity = app.spawn(
            "Camera",
            bundle: Camera3D(
                camera: Camera(),
                perspectiveProjection: .init(near: 0.15, far: 5200),
                transform: Transform(position: [Valley.trail(Valley.startZ), 45, Valley.startZ]),
                environment: environment
            )
        )
        app.spawn("Afternoon sun") {
            Transform(rotation: Quat(axis: [1, 0, 0], angle: 0.92))
            DirectionalLightComponent(radiance: [1, 0.94, 0.80], intensity: 2.4, castShadows: true, shadowDistance: 65)
        }
        app.spawn("Open sky fill") {
            Transform(rotation: Quat(axis: [1, 0, 0], angle: 2.35))
            DirectionalLightComponent(radiance: [0.85, 0.94, 1.0], intensity: 1.15, castShadows: false)
        }
        let controls = ValleyRenderControl(
            camera: cameraEntity,
            terrain: [valley, forest, grass],
            canopy: ValleyVoxelCanopy.spawn(in: app, assets: assets),
            statistics: app.getSubworldBuilder(by: .renderWorld)?.getResource(Render3DPathTracingStatistics.self)
        )
        app.insertResource(controls)
        app.addSystem(ValleyRenderKeys.self, on: .update)
        app.addSystem(ValleyCamera.self, on: .update)
        app.addSystem(ValleyGrassWind.self, on: .update)
    }

    func finish(for app: borrowing AppWorlds) {
        guard let control = app.getResource(ValleyRenderControl.self) else {
            return
        }
        UIPlugin.addWindowOverlay(UIContainerView(rootView: ValleyRenderButton(control: control)), in: app)
    }
}
@PlainSystem
struct ValleyGrassWind {
    @Query<Transform, Environment3D> private var cameras
    @Query<Entity, Ref<Mesh3DInstancesComponent>, Ref<MeshLOD3DComponent>> private var batches
    @Res<DeltaTime> private var delta
    @Local private var phase: Float = 0
    @Local private var sinceTick: Float = 0
    @Local private var previous: Set<Entity.ID> = []

    init(world _: World) {}

    func update(context _: UpdateContext) {
        guard let (camera, environment) = cameras.first, !environment.pathTracing.isEnabled else {
            return
        }
        sinceTick += min(delta.deltaTime, 0.1)
        guard sinceTick >= 1.0 / 15.0 else {
            return
        }
        phase = (phase + sinceTick * 2.8).truncatingRemainder(dividingBy: .pi * 2)
        sinceTick = 0
        let radius: Float = 36
        let cameraXZ = Vector2(camera.position.x, camera.position.z)
        var current: Set<Entity.ID> = []
        batches.forEach { entity, batch, lod in
            // This ID bit is reserved for grass clumps in the sample generator.
            guard let first = batch.instances.first, first.id & (1 << 30) != 0 else {
                return
            }
            if let cutoff = lod.maximumDistance {
                let transition = min(32, cutoff * 0.3)
                if lod.fadeDistance != transition { lod.fadeDistance = transition }
            }
            let anchor = first.transform.origin
            let cell: Float = 125
            let lower = Vector2((anchor.x / cell).rounded(.down), (anchor.z / cell).rounded(.down)) * cell
            let relative = cameraXZ - lower
            let dx = max(0, max(-relative.x, relative.x - cell))
            let dz = max(0, max(-relative.y, relative.y - cell))
            let near = dx * dx + dz * dz < radius * radius
            guard near || previous.contains(entity.id) else {
                return
            }
            var placements = batch.instances
            var changed = false
            for index in placements.indices {
                var transform = placements[index].transform
                let point = transform.origin
                let offset = Vector2(point.x, point.z) - cameraXZ
                let fade = near ? max(0, 1 - offset.squaredLength / (radius * radius)) : 0
                let gust = (0.09 + 0.22 * Math.sin(phase + point.x * 0.16 + point.z * 0.09)) * fade
                let bendX = gust * transform.y.y
                let bendZ = gust * transform.y.y * 0.42
                if transform.y.x == bendX && transform.y.z == bendZ { continue }
                transform.y.x = bendX
                transform.y.z = bendZ
                placements[index].transform = transform
                changed = true
            }
            if changed { batch.instances = placements }
            if near { current.insert(entity.id) }
        }
        previous = current
    }
}
@PlainSystem
struct ValleyCamera {
    private enum Mode: Int {
        case walk, guidedWalk, guidedFlight, freeFlight
    }

    @FilterQuery<Ref<Transform>, With<Camera>> private var cameras
    @Query<Terrain3DSourceStatus> private var terrainStatus
    @Local private var lastTerrainError: String?
    @Query<Terrain3DSourceSurface> private var terrain
    @Res<Input> private var input
    @Res<DeltaTime> private var time
    @Res<ValleyRenderControl> private var controls
    @Local private var yaw: Float = -0.56
    @Local private var pitch: Float = 0.05
    @Local private var progress: Float = 0
    @Local private var mode = Mode.walk
    @Local private var initialized = false
    @Local private var nextLog: Float = 0
    @Local private var freeFlightHeld = false
    @Local private var flyoverHeld = false
    @Local private var guidedWalkHeld = false

    init(world _: World) {}

    @MainActor func update(context _: UpdateContext) {
        let error = terrainStatus.first(where: { $0.error != nil })?.error
        if error != lastTerrainError {
            if let error { print("Green Valley terrain: \(error)") }
            lastTerrainError = error
        }
        guard let surface = terrain.first(where: { $0.manifest?.materials != nil }) else {
            return
        }
        let dt = min(time.deltaTime, 0.1)
        if !initialized {
            initialized = true
            let route = ProcessInfo.processInfo.environment["GREEN_VALLEY_ROUTE"]
            mode = route == "fly" ? .guidedFlight : (route == "walk" ? .guidedWalk : .walk)
        }
        let freeFlight = input.isKeyPressed(.f)
        let flyover = input.isKeyPressed(.g)
        let guidedWalk = input.isKeyPressed(.r)
        let nextMode: Mode?
        if freeFlight && !freeFlightHeld {
            nextMode = mode == .freeFlight ? .walk : .freeFlight
        } else if flyover && !flyoverHeld {
            nextMode = .guidedFlight
        } else if guidedWalk && !guidedWalkHeld {
            nextMode = .guidedWalk
        } else {
            nextMode = nil
        }
        freeFlightHeld = freeFlight
        flyoverHeld = flyover
        guidedWalkHeld = guidedWalk
        if let nextMode {
            mode = nextMode
            progress = 0
            nextLog = 0
        }
        let forward = Float((input.isKeyPressed(.w) ? 1 : 0) - (input.isKeyPressed(.s) ? 1 : 0))
        let side = Float((input.isKeyPressed(.d) ? 1 : 0) - (input.isKeyPressed(.a) ? 1 : 0))
        if mode != .freeFlight, forward != 0 || side != 0 {
            mode = .walk
        }
        controls.setFreeFlight(mode == .freeFlight)
        cameras.forEach { transform in
            var position = transform.position
            let guided = mode == .guidedWalk || mode == .guidedFlight
            if guided {
                let flight = mode == .guidedFlight
                position.z = min(1650, Valley.startZ + progress * (flight ? 45 : 7))
                position.x = Valley.trail(position.z) + (flight ? 105 * Math.sin(progress / 12) : 0)
                yaw = Math.atan2(0.2 * Math.cos(position.z / 180), 1)
                pitch = flight ? 0.25 : 0.025
                if let h = surface.storage.height(at: [position.x, position.z]) {
                    position.y = h + (flight ? 100 : 2.1)
                    progress += dt
                } else {
                    // Move the streaming camera to the requested region before waiting for its surface.
                    transform.position = [position.x, position.y, position.z]
                    return
                }
            } else {
                if input.isMouseButtonPressed(.right) {
                    yaw += input.getMouseDelta().x * 0.003
                    pitch = max(-1.4, min(1.4, pitch + input.getMouseDelta().y * 0.003))
                }
                let sprint = input.isKeyPressed(.shift)
                let speed: Float = mode == .freeFlight ? (sprint ? 90 : 32) : (sprint ? 24 : 6)
                let rise = mode == .freeFlight ? Float((input.isKeyPressed(.space) ? 1 : 0) - (input.isKeyPressed(.ctrl) ? 1 : 0)) : 0
                let direction = Vector3(
                    Math.sin(yaw) * forward + Math.cos(yaw) * side,
                    rise,
                    Math.cos(yaw) * forward - Math.sin(yaw) * side
                )
                let displacement = direction * (speed * dt / max(1, direction.length))
                let x = max(-1998, min(1998, position.x + displacement.x))
                let z = max(-1998, min(1998, position.z + displacement.z))
                guard let h = surface.storage.height(at: [x, z]) else {
                    return
                }
                let eyeLevel = h + 2.1
                let y = mode == .freeFlight ? max(eyeLevel, min(1200, position.y + displacement.y)) : eyeLevel
                position = [x, y, z]
            }
            if guided, progress >= nextLog {
                print("Valley route \(mode.rawValue) at \(Int(progress)) s: x=\(Int(position.x)) z=\(Int(position.z))")
                nextLog = progress + 10
            }
            transform.position = position
            transform.rotation = Quat(
                x: Math.cos(yaw / 2) * Math.sin(pitch / 2),
                y: Math.sin(yaw / 2) * Math.cos(pitch / 2),
                z: -Math.sin(yaw / 2) * Math.sin(pitch / 2),
                w: Math.cos(yaw / 2) * Math.cos(pitch / 2)
            )
            controls.updateCanopy(at: position)
        }
    }
}
@PlainSystem
struct ValleyFramePacing {
    @Res<RenderDeviceHandler> private var renderer
    @Local private var previous: AsyncStream<Void>?

    init(world _: World) {}

    func update(context _: UpdateContext) async {
        if let previous {
            var completion = previous.makeAsyncIterator()
            _ = await completion.next()
        }
        let (signal, continuation) = AsyncStream<Void>.makeStream()
        let frame = renderer.renderDevice.createCommandQueue().makeCommandBuffer()
        frame.addCompletedHandler { continuation.finish() }
        frame.commit()
        previous = signal
    }
}
@MainActor @Observable
private final class ValleyRenderControl: Resource {
    private let camera: Entity
    private let terrain: [(entity: Entity, settings: Terrain3DSource)]
    private let statistics: Render3DPathTracingStatistics?
    private let canopy: [(entity: Entity, tile: ValleyVoxelCanopy.Tile)]
    private var visibleCanopy = Set<Entity.ID>()
    private var lastCanopyPosition: Vector3?
    private(set) var requested = false
    private(set) var status = "Raster"
    private(set) var freeFlight = false

    init(camera: Entity, terrain: [Entity], canopy: [(Entity, ValleyVoxelCanopy.Tile)], statistics: Render3DPathTracingStatistics?) {
        self.camera = camera
        self.canopy = canopy
        self.terrain = terrain.compactMap { entity in
            entity.components[Terrain3DSource.self].map { (entity, $0) }
        }
        self.statistics = statistics
    }

    func toggle() {
        requested.toggle()
        setTracing(false)
        updateResidency()
        report(requested ? "Loading full map..." : "Raster")
    }

    func setFreeFlight(_ active: Bool) {
        if freeFlight != active { freeFlight = active }
    }

    func updateCanopy(at position: Vector3) {
        if let lastCanopyPosition, (position - lastCanopyPosition).length < 12 {
            return
        }
        lastCanopyPosition = position
        for (entity, tile) in canopy {
            let bounds = tile.bounds
            let delta = position - bounds.center
            let farthest = Vector3(abs(delta.x), abs(delta.y), abs(delta.z)) + bounds.halfExtents
            let wasVisible = visibleCanopy.contains(entity.id)
            // Each tree model has its own cutoff. Start the tile before its far corner
            // loses trees, and leave a small band when flying back.
            let threshold = tile.treeDistance - (wasVisible ? 55 : 25)
            let visible = farthest.length >= threshold
            guard visible != wasVisible else { continue }
            entity.components[Visibility.self] = visible ? .visible : .hidden
            if visible { visibleCanopy.insert(entity.id) } else { visibleCanopy.remove(entity.id) }
        }
    }

    private func updateResidency() {
        for (entity, original) in terrain {
            var settings = original
            if requested {
                settings.streamingRadius = nil
                settings.maximumMeshBytes = 384 * 1024 * 1024
            }
            entity.components[Terrain3DSource.self] = settings
        }
    }

    private func fallback(_ reason: String) {
        requested = false
        setTracing(false)
        updateResidency()
        report("Raster fallback: " + reason)
    }

    private func setTracing(_ enabled: Bool) {
        guard var environment = camera.components[Environment3D.self], environment.pathTracing.isEnabled != enabled else {
            return
        }
        environment.pathTracing.isEnabled = enabled
        camera.components[Environment3D.self] = environment
    }

    private func report(_ message: String) {
        guard status != message else {
            return
        }
        status = message
        FileHandle.standardError.write(Data("Green Valley rendering: \(message)\n".utf8))
    }

    func refresh() {
        guard requested else {
            return
        }
        for (entity, _) in terrain {
            if let failure = entity.components[Terrain3DSourceStatus.self]?.error {
                fallback(failure)
                return
            }
            guard let surface = entity.components[Terrain3DSourceSurface.self], let manifest = surface.manifest,
                surface.residentRegionCount == manifest.heightRegions.count
            else { return }
        }
        if camera.components[Environment3D.self]?.pathTracing.isEnabled != true {
            setTracing(true)
            report("Preparing Path Tracing...")
            return
        }
        guard let result = statistics?.snapshots[String(camera.id)] else {
            report("Preparing Path Tracing...")
            return
        }
        if let failure = result.failure {
            fallback(failure)
        } else if result.encodedFrames > 0 {
            let hardware = result.implementation == "vulkan-ray-query"
            let message = hardware ? "Path Tracing (Vulkan)" : "Path Tracing (software)"
            if message != status {
                FileHandle.standardError.write(
                    Data(
                        "Green Valley traced frames: \(result.encodedFrames), triangles: \(result.triangles), "
                            + "size: \(result.width)x\(result.height), raster first hit: \(result.hybridFirstHit)\n"
                            .utf8
                    )
                )
                report(message)
            }
        }
    }
}
private struct ValleyRenderButton: View {
    let control: ValleyRenderControl

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(action: { control.toggle() }) {
                Text(control.requested ? "Switch to Raster  [P]" : "Switch to Path Tracing  [P]")
                    .font(.system(size: 16)).foregroundColor(.white)
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(Color.fromHex(0x26372E)).border(Color.white.opacity(0.65), lineWidth: 1)
            }
            if !control.status.isEmpty {
                Text(control.status).font(.system(size: 13)).foregroundColor(.white)
                    .padding(6).background(Color.fromHex(0x26372E))
            }
            Text(control.freeFlight ? "Space ↑  Ctrl ↓  [F] Land" : "[F] Free flight")
                .font(.system(size: 13)).foregroundColor(.white)
                .padding(6).background(Color.fromHex(0x26372E))
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
@PlainSystem
struct ValleyRenderKeys {
    @Res<ValleyRenderControl> private var control
    @Res<Input> private var input
    @Res<DeltaTime> private var time
    @Local private var previous = false
    @Local private var elapsed: Float = 0

    init(world _: World) {}

    @MainActor func update(context _: UpdateContext) {
        let pressed = input.isKeyPressed(.p)
        if pressed && !previous { control.toggle() }
        previous = pressed
        elapsed += time.deltaTime
        if elapsed >= 0.25 {
            elapsed = 0
            control.refresh()
        }
    }
}
