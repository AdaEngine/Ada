import AdaEngine
import Foundation
import Math
import Observation
import SponzaCamera

struct CameraRoutes: Decodable {
    struct Pose: Decodable {
        var position: [Float]
        var rotation: [Float]

        var transform: Transform {
            Transform(rotation: Quat(x: rotation[0], y: rotation[1], z: rotation[2], w: rotation[3]), position: [position[0], position[1], position[2]])
        }
    }
    struct Route: Decodable { var id: String; var start: Pose }
    var routes: [Route]
}

@MainActor
@Observable
final class SponzaSession: Resource {
    var status = "Загружаем Sponza + Ivy…"
    var hiZ = false
    var requestedView: Int?
    var camera: Entity?
    var poses: [CameraRoutes.Pose] = []
    var preset = SponzaRenderPreset.fullRaster
    var lightCount = 12
    var requestedPreset: SponzaRenderPreset?
    var requestedLightCount: Int?
    var pathHighQuality = true
    var requestedQuality: Bool?
    var dlssAvailable = false
    var dlssEnabled = true
    var requestedDLSS: Bool?
    var dlssStatus = "Проверяем DLSS…"
    var flyingLightEnabled = true
    var meshletMode = MeshletVisibilityMode3D.gpu
    var meshletMapEnabled = false
    var requestedMeshletMode: MeshletVisibilityMode3D?
    var requestedMeshletMap: Bool?
    var meshletLODError: Float = 2
    var requestedMeshletLODError: Float?
    var highResolutionShadows = true
    var requestedShadowQuality: Bool?
    var meshletStatus = "Загружаем подготовленные мешлеты…"
    @ObservationIgnored var meshletStatistics: Render3DMeshletStatistics?
    @ObservationIgnored var flightSeconds = 0.0
    @ObservationIgnored var temporalStatistics: Render3DTemporalStatistics?
    var rendererStatus = "Готовим освещение…"
    @ObservationIgnored var fullGeometry: Entity?
    @ObservationIgnored var lodGeometry: Entity?
    @ObservationIgnored var sun: Entity?
    @ObservationIgnored var lighting = SponzaLighting()
    @ObservationIgnored var pathStatistics: Render3DPathTracingStatistics?
    @ObservationIgnored var nextStatusUpdate = ContinuousClock.now
    var isLoaded = false
    @ObservationIgnored let warmupFrames = SponzaWarmupFrames()
    @ObservationIgnored var flight = SponzaFlyCamera()
    @ObservationIgnored var cancelledLook = false
    @ObservationIgnored var profiler: SponzaDemoProfiler?
    var loadTask: Task<Void, Never>?
    @ObservationIgnored weak var runtime: AppWorlds?

    func move(to index: Int) {
        guard poses.indices.contains(index), let camera else { return }
        let transform = poses[index].transform
        camera.components[Transform.self] = transform
        camera.components[GlobalTransform.self] = GlobalTransform(matrix: transform.matrix)
        flight.setPose(transform)
    }
}

@main
struct SponzaDemo: App {
    var body: some AppScene {
        WindowGroup { SponzaView() }
            .window(with: UIWindow.Configuration(title: "Sponza + Ivy · AdaEngine", frame: Rect(x: 0, y: 0,
                width: ProcessInfo.processInfo.environment["ADAENGINE_SPONZA_PROFILE_STUTTER"] == "1" ? 2560 : 1280,
                height: ProcessInfo.processInfo.environment["ADAENGINE_SPONZA_PROFILE_STUTTER"] == "1" ? 1400 : 800)))
    }
}

private struct SponzaView: View {
    @State private var session = SponzaSession()

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 16) {
                Button("Атриум") { session.requestedView = 0 }
                Button("Коридор") { session.requestedView = 1 }
                Button("Галерея") { session.requestedView = 2 }
                Button("Снаружи") { session.requestedView = 3 }
                Button(session.hiZ ? "Hi-Z: вкл." : "Hi-Z: выкл.") { session.hiZ.toggle() }
            }
            .disabled(!session.isLoaded)
            Text(session.status)
            HStack(spacing: 16) {
                Button("Полная сцена · растр") { session.requestedPreset = .fullRaster }
                Button("PT LOD · растр") { session.requestedPreset = .lodRaster }
                Button("PT LOD · path tracing") { session.requestedPreset = .pathTracing }
                Button("Локальный свет: \(session.lightCount)") { session.requestedLightCount = session.lightCount == 0 ? 4 : session.lightCount == 4 ? 12 : 0 }
                Button(session.meshletMapEnabled ? "Карта: 1:1" : session.dlssEnabled && session.dlssAvailable
                    ? (session.pathHighQuality ? "DLSS: Quality" : "DLSS: Performance")
                    : (session.pathHighQuality ? "PT: качество ½" : "PT: предпросмотр ¼")) { session.requestedQuality = !session.pathHighQuality }
            }
            .disabled(!session.isLoaded)
            HStack(spacing: 16) {
                Button(session.dlssEnabled && session.dlssAvailable && !session.meshletMapEnabled ? "DLSS: вкл." : "DLSS: выкл.") { session.requestedDLSS = !session.dlssEnabled }
                Button(session.flyingLightEnabled ? "Летающий свет: вкл." : "Летающий свет: выкл.") { session.flyingLightEnabled.toggle() }
                Button(session.highResolutionShadows ? "Тени: высокие · 80 м" : "Тени: базовые · 30 м") { session.requestedShadowQuality = !session.highResolutionShadows }
                SponzaDLSSStatus(session: session)
            }
            .disabled(!session.isLoaded)
            SponzaRendererStatus(session: session)
            HStack(spacing: 16) {
                Button("Мешлеты: \(session.meshletMode.rawValue)") {
                    session.requestedMeshletMode = session.meshletMode == .disabled ? .cpuReference : session.meshletMode == .cpuReference ? .gpu : .disabled
                }
                Button(session.meshletMapEnabled ? "Карта мешлетов: вкл." : "Карта мешлетов: выкл.") { session.requestedMeshletMap = !session.meshletMapEnabled }
                Button(session.meshletLODError > 0 ? "LOD: \(Int(session.meshletLODError)) px" : "LOD: выкл.") {
                    session.requestedMeshletLODError = session.meshletLODError == 0 ? 1 : session.meshletLODError >= 8 ? 0 : session.meshletLODError * 2
                }
            }
            .disabled(!session.isLoaded)
            SponzaMeshletStatus(session: session)
            if session.meshletMapEnabled && session.meshletLODError > 0 {
                Text("L0 — исходные кластеры · L1 — голубой · L2 — оранжевый · L3 — розовый · L4 — фиолетовый")
            }
            Text("WASD — движение · Q/E — вниз/вверх · правая кнопка мыши — осмотр · Shift — быстрее")
            SceneView(useSceneCameras: true, make: { app in
                app.addPlugin(TransformPlugin()).addPlugin(InputPlugin()).addPlugin(RenderWorldPlugin())
                    .addPlugin(CameraPlugin()).addPlugin(AssetsPlugin()).addPlugin(VisibilityPlugin())
                    .addPlugin(ScenePlugin()).addPlugin(Core3DPlugin(pathTracingPresentation: true)).addPlugin(UpscalePlugin()).addPlugin(SponzaPlugin())
                app.insertResource(session)
                session.runtime = app
            }, updateContent: { _, _ in }, onFrameRendered: { texture in
                session.warmupFrames.didPublish()
                session.profiler?.didPresent(width: texture.width, height: texture.height)
            })
            .frameCaptureLabel("SponzaDemo")
            // Keep measured GPU work independent of native-window resizing/maximization.
            .frame(width: session.profiler?.isRunning == true && session.profiler?.usesFixedViewport == true ? 1120 : nil,
                   height: session.profiler?.isRunning == true && session.profiler?.usesFixedViewport == true ? 400 : nil)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(10)
        .background(Color(0.06, 0.07, 0.09, 1))
        .foregroundColor(.white)
    }
}

private struct SponzaPlugin: Plugin {
    func setup(in app: AppWorlds) {
        app.addSystem(SponzaStartupSystem.self, on: .startup)
        app.addSystem(SponzaControlsSystem.self, on: .preUpdate)
    }
}

@System
@MainActor
func SponzaStartup(_ context: WorldUpdateContext, _ resource: Res<SponzaSession>) {
    let session = resource.wrappedValue
    guard let app = session.runtime else { return }
    // Keep the window rendering and accepting input while the asset actor decodes the 4K textures.
    // The session owns this task for the lifetime of this single-window demo; it is not detached.
    session.loadTask = Task { @MainActor in
        do {
            let repository = ProcessInfo.processInfo.environment["ADAENGINE_SHADER_SOURCE_ROOT"].map { URL(fileURLWithPath: $0) }
                ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let root = ProcessInfo.processInfo.environment["ADAENGINE_SPONZA_ASSETS"].map { URL(fileURLWithPath: $0, isDirectory: true) }
                ?? repository.appendingPathComponent(".build-codex/benchmark-assets/intel-sponza/assets")
            let routes = try JSONDecoder().decode(CameraRoutes.self, from: Data(contentsOf: repository.appendingPathComponent("Tools/3DAssets/BenchmarkScenes/intel-sponza-routes.json")))
            guard routes.routes.count == 3, routes.routes.allSatisfy({ $0.start.position.count == 3 && $0.start.rotation.count == 4 }) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            session.poses = routes.routes.map(\.start)
            let outside = SponzaFlyCamera.looking(from: [-32, 25, -35], at: [0, 4, 0])
            session.poses.append(CameraRoutes.Pose(position: [outside.position.x, outside.position.y, outside.position.z],
                rotation: [outside.rotation.x, outside.rotation.y, outside.rotation.z, outside.rotation.w]))
            var environment = Environment3D(antiAliasing: .none)
            environment.skybox.isEnabled = false
            environment.shadows.isEnabled = true
            environment.shadowCascadeCount = 3
            environment.shadows.resolution = 2048
            environment.ambientOcclusion.isEnabled = false
            environment.screenSpaceReflection.isEnabled = false
            environment.exposureEV = 3
            environment.gpuOcclusionEnabled = session.hiZ
            let environmentRoot = try await app.withWorldAccess {
                session.camera = app.main.spawn("Camera", bundle: Camera3D(
                    camera: Camera(), perspectiveProjection: PerspectiveProjection(near: 0.05, far: 200, fieldOfView: .degrees(60)),
                    transform: routes.routes[0].start.transform, environment: environment
                ))
                session.move(to: 0)
                session.camera?.components[MouseCaptureComponent.self] = MouseCaptureComponent()
                let lighting = app.main.spawn("Lighting") { Transform() }
                let sun = app.main.spawn("Sun") {
                    DirectionalLightComponent(intensity: 3, castShadows: true)
                    Transform(rotation: Quat.euler([-0.4, 0.5, 0]))
                }
                lighting.addChild(sun)
                session.sun = sun
                session.lighting.spawn(in: app.main, parent: lighting)
                let root = app.main.spawn("Environment") { Transform() }
                session.fullGeometry = app.main.spawn("Full Sponza + Ivy") { Transform(); Visibility.hidden }
                session.lodGeometry = app.main.spawn("PT lighting LOD") { Transform(); Visibility.hidden }
                if let full = session.fullGeometry { root.addChild(full) }
                if let lod = session.lodGeometry { root.addChild(lod) }
                return root
            }
            _ = environmentRoot
            for (filename, isLOD) in [("benchmark-pbr.gltf", false), ("lighting-pt.gltf", true)] {
              for (folder, label) in [("main_sponza", "Sponza"), ("pkg_b_ivy", "Ivy")] {
                try Task.checkCancellation()
                session.status = "Загружаем \(label)\(isLOD ? " · PT LOD" : "")…"
                let file = root.appendingPathComponent(folder).appendingPathComponent(filename)
                guard let model = try await AssetsManager.load(ModelAsset3D.self, at: file.path).asset else { throw CocoaError(.fileReadCorruptFile) }
                try await app.withWorldAccess {
                    let parent = isLOD ? session.lodGeometry : session.fullGeometry
                    parent?.addChild(model.instantiate(in: app.main))
                }
              }
            }
            try await app.withWorldAccess {
                session.pathStatistics = app.getSubworldBuilder(by: .renderWorld)?.getResource(Render3DPathTracingStatistics.self)
                session.temporalStatistics = app.getSubworldBuilder(by: .renderWorld)?.getResource(Render3DTemporalStatistics.self)
                session.meshletStatistics = app.getSubworldBuilder(by: .renderWorld)?.getResource(Render3DMeshletStatistics.self)
                session.meshletMode = ProcessInfo.processInfo.environment["ADAENGINE_SPONZA_MESHLETS"].flatMap(MeshletVisibilityMode3D.init(rawValue:)) ?? .gpu
                session.meshletMapEnabled = ProcessInfo.processInfo.environment["ADAENGINE_SPONZA_MESHLET_MAP"] == "1"
                if let value = ProcessInfo.processInfo.environment["ADAENGINE_SPONZA_MESHLET_LOD"].flatMap(Float.init), value.isFinite {
                    session.meshletLODError = min(max(value, 0), 8)
                }
                session.highResolutionShadows = ProcessInfo.processInfo.environment["ADAENGINE_SPONZA_SHADOW_QUALITY"] != "baseline"
                session.dlssAvailable = app.getSubworldBuilder(by: .renderWorld)?.getResource(RenderDeviceHandler.self)?.renderDevice.supportsTemporalUpscaling ?? false
                let requested = ProcessInfo.processInfo.environment["ADAENGINE_SPONZA_RENDER_PRESET"].flatMap(SponzaRenderPreset.init(rawValue:)) ?? .fullRaster
                session.apply(preset: requested, lights: 12)
                session.move(to: 2)
            }
            try await session.warmupRaster(app: app)
            session.isLoaded = true
            session.status = "Sponza + Ivy · полная сцена / отдельный PT LOD"
            FileHandle.standardOutput.write(Data("SPONZA_DEMO_READY\n".utf8))
            if let output = ProcessInfo.processInfo.environment["ADAENGINE_SPONZA_PROFILE_OUTPUT"] {
                let profiler = SponzaDemoProfiler(output: URL(fileURLWithPath: output))
                session.profiler = profiler
                try await profiler.run(session: session, app: app)
            }
        } catch {
            session.status = session.isLoaded ? "Замер остановлен; подробности в журнале" : "Не удалось завершить загрузку: \(error)"
            FileHandle.standardError.write(Data("SPONZA_DEMO_ERROR \(error)\n".utf8))
        }
    }
}

private struct SponzaRendererStatus: View {
    let session: SponzaSession

    var body: some View { Text(session.rendererStatus) }
}

private struct SponzaDLSSStatus: View {
    let session: SponzaSession
    var body: some View { Text(session.dlssStatus) }
}

private struct SponzaMeshletStatus: View {
    let session: SponzaSession
    var body: some View { Text(session.meshletStatus) }
}

@PlainSystem(dependencies: [.after(InputEventParseSystem.self), .before(CameraSystem.self)])
struct SponzaControlsSystem {
    @Res<SponzaSession> private var session
    @Res<Input> private var input
    @Res<DeltaTime> private var time
    // Declare writes performed through the session's camera ID.
    @Query<Ref<Transform>, Ref<GlobalTransform>, Ref<Environment3D>, Ref<MouseCaptureComponent>, Ref<Camera>> private var cameraAccess
    @Query<Ref<Transform>, Ref<GlobalTransform>, PointLightComponent> private var lightAccess
    @Query<Ref<Visibility>> private var visibilityAccess
    @Query<Ref<DirectionalLightComponent>> private var sunAccess

    init(world _: World) {}

    @MainActor
    func update(context _: UpdateContext) {
        _ = cameraAccess
        _ = visibilityAccess
        _ = lightAccess
        _ = sunAccess
        guard session.isLoaded, let camera = session.camera,
            let transform = camera.components[Transform.self] else { return }
        session.refreshPathStatus()
        if let profiler = session.profiler, profiler.isRunning {
            if let next = profiler.cameraPose(), next != transform {
                camera.components[Transform.self] = next
                camera.components[GlobalTransform.self] = GlobalTransform(matrix: next.matrix)
                profiler.didMoveCamera()
            }
            return
        }
        if session.isLoaded, session.requestedPreset != nil || session.requestedLightCount != nil || session.requestedQuality != nil
            || session.requestedDLSS != nil || session.requestedMeshletMode != nil || session.requestedMeshletMap != nil
            || session.requestedMeshletLODError != nil || session.requestedShadowQuality != nil {
            if let quality = session.requestedQuality { session.pathHighQuality = quality }
            if let dlss = session.requestedDLSS { session.dlssEnabled = dlss }
            if let quality = session.requestedShadowQuality { session.highResolutionShadows = quality }
            if let error = session.requestedMeshletLODError {
                session.meshletLODError = error
                session.hiZ = false
                if error > 0 && session.meshletMode == .disabled { session.meshletMode = .gpu }
                if session.preset == .pathTracing { session.requestedPreset = .fullRaster }
            }
            if session.requestedPreset == .pathTracing { session.meshletMapEnabled = false }
            if let mode = session.requestedMeshletMode {
                session.meshletMode = mode
                session.hiZ = false
                if session.preset == .pathTracing { session.requestedPreset = .fullRaster }
            }
            if let map = session.requestedMeshletMap {
                session.meshletMapEnabled = map
                if map { session.hiZ = false; session.requestedPreset = .fullRaster }
            }
            session.apply(preset: session.requestedPreset ?? session.preset, lights: session.requestedLightCount ?? session.lightCount)
            session.requestedPreset = nil
            session.requestedLightCount = nil
            session.requestedQuality = nil
            session.requestedDLSS = nil
            session.requestedMeshletMode = nil
            session.requestedMeshletMap = nil
            session.requestedMeshletLODError = nil
            session.requestedShadowQuality = nil
        }
        session.flightSeconds += max(0, Double(time.deltaTime))
        session.lighting.updateFlight(enabled: session.flyingLightEnabled, seconds: session.flightSeconds)
        if let index = session.requestedView {
            session.move(to: index)
            session.requestedView = nil
        }
        let rightDown = input.isMouseButtonPressed(.right)
        if !rightDown { session.cancelledLook = false }
        if input.isKeyPressed(.escape) { session.cancelledLook = true }
        if var capture = camera.components[MouseCaptureComponent.self] {
            let requested = rightDown && !session.cancelledLook
            if requested && capture.isCaptured { session.flight.look(delta: input.getMouseDelta()) }
            if capture.isRequested != requested {
                capture.isRequested = requested
                camera.components[MouseCaptureComponent.self] = capture
            }
        }
        var movement = Vector3.zero
        if input.isKeyPressed(.w) { movement.z += 1 }
        if input.isKeyPressed(.s) { movement.z -= 1 }
        if input.isKeyPressed(.d) { movement.x += 1 }
        if input.isKeyPressed(.a) { movement.x -= 1 }
        if input.isKeyPressed(.e) { movement.y += 1 }
        if input.isKeyPressed(.q) { movement.y -= 1 }
        session.flight.move(local: movement, seconds: Double(time.deltaTime), fast: input.isKeyPressed(.shift))
        let next = session.flight.transform
        if next != transform {
            camera.components[Transform.self] = next
            camera.components[GlobalTransform.self] = GlobalTransform(matrix: next.matrix)
        }
        if var environment = camera.components[Environment3D.self], environment.gpuOcclusionEnabled != session.hiZ {
            environment.gpuOcclusionEnabled = session.hiZ
            camera.components[Environment3D.self] = environment
        }
    }
}
