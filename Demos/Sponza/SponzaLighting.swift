import AdaEngine
import Foundation
import Math
import SponzaCamera

enum SponzaRenderPreset: String, CaseIterable {
    case fullRaster
    case lodRaster
    case pathTracing

    var usesLOD: Bool { self != .fullRaster }
}

@MainActor
struct SponzaLighting {
    private var lamps: [Entity] = []
    private var flyingLamp: Entity?

    mutating func spawn(in world: World, parent: Entity) {
        let spots = world.spawn("Gallery spotlights") { Transform() }
        let points = world.spawn("Gallery fill lights") { Transform() }
        let moving = world.spawn("Flying test light") { Transform() }
        parent.addChild(spots)
        parent.addChild(points)
        parent.addChild(moving)
        let lamp = world.spawn("Moving point light") {
            PointLightComponent(radiance: [0.85, 0.93, 1], intensity: 25, castShadows: true, range: 10)
            Transform(position: SponzaLightMotion.position(seconds: 0))
        }
        moving.addChild(lamp)
        flyingLamp = lamp
        for (index, x) in [Float(-9), -3, 3, 9].enumerated() {
            let position = Vector3(x, 8.4, 5.35)
            let lamp = world.spawn("Spot \(index + 1)") {
                SpotLightComponent(radiance: [1, 0.92, 0.82], intensity: 8, castShadows: true,
                    range: 9, innerConeAngle: 25, outerConeAngle: 42)
                SponzaFlyCamera.looking(from: position, at: [x, 6.4, 5.35])
            }
            spots.addChild(lamp)
            lamps.append(lamp)
        }
        for z in [Float(-5.35), 5.35] {
            for (index, x) in [Float(-9), -3, 3, 9].enumerated() {
                let lamp = world.spawn("Fill \(lamps.count - 3)") {
                    PointLightComponent(radiance: index.isMultiple(of: 2) ? [1, 0.9, 0.8] : [0.8, 0.9, 1],
                        intensity: 2, castShadows: false, range: 8)
                    Transform(position: [x, 7.6, z])
                }
                points.addChild(lamp)
                lamps.append(lamp)
            }
        }
    }

    func setCount(_ count: Int) {
        for (index, lamp) in lamps.enumerated() {
            lamp.components[Visibility.self] = index < count ? .visible : .hidden
        }
    }

    func updateFlight(enabled: Bool, seconds: Double) {
        guard let flyingLamp else { return }
        let visibility: Visibility = enabled ? .visible : .hidden
        if flyingLamp.components[Visibility.self] != visibility { flyingLamp.components[Visibility.self] = visibility }
        guard enabled else { return }
        let pose = Transform(position: SponzaLightMotion.position(seconds: seconds))
        flyingLamp.components[Transform.self] = pose
        flyingLamp.components[GlobalTransform.self] = GlobalTransform(matrix: pose.matrix)
    }
}

extension SponzaSession {
    func apply(preset: SponzaRenderPreset, lights: Int) {
        fullGeometry?.components[Visibility.self] = preset.usesLOD ? .hidden : .visible
        lodGeometry?.components[Visibility.self] = preset.usesLOD ? .visible : .hidden
        lighting.setCount(lights)
        lighting.updateFlight(enabled: flyingLightEnabled, seconds: flightSeconds)
        if let sun, var light = sun.components[DirectionalLightComponent.self] {
            light.shadowDistance = highResolutionShadows ? 80 : 30
            sun.components[DirectionalLightComponent.self] = light
        }
        if let camera, var component = camera.components[Camera.self] {
            component.temporalUpscaling = dlssEnabled && dlssAvailable && !meshletMapEnabled
                ? .init(renderScale: pathHighQuality ? 2.0 / 3.0 : 0.5, method: .automatic) : nil
            camera.components[Camera.self] = component
        }
        if let camera, var environment = camera.components[Environment3D.self] {
            environment.pathTracing = PathTracing3D(isEnabled: preset == .pathTracing,
                samplesPerPixel: 1, maximumBounces: 2,
                resolutionScale: dlssEnabled && dlssAvailable ? 1 : (pathHighQuality ? 0.5 : 0.25), historyLimit: 128)
            environment.pathTracing.textureTileSize = 512
            environment.debugView = meshletMapEnabled ? .meshlets : .none
            environment.meshVisibility.meshlets = preset == .pathTracing ? .disabled : meshletMode
            environment.meshVisibility.meshletLODPixelError = meshletLODError
            environment.shadows.isEnabled = true
            environment.shadows.resolution = highResolutionShadows ? 2048 : 1024
            environment.shadows.splitLambda = highResolutionShadows ? 0.85 : 0.65
            environment.localShadows = LocalShadowSettings3D(isEnabled: true, maximumLights: 4, resolution: highResolutionShadows ? 1024 : 512)
            camera.components[Environment3D.self] = environment
        }
        self.preset = preset
        self.lightCount = lights
        rendererStatus = preset == .pathTracing ? "Path tracing · 1 spp · 2 отскока · подготовка BVH…"
            : "\(preset.usesLOD ? "PT LOD" : "Полная геометрия") · растр · \(lights) локальных источников"
    }

    func refreshPathStatus() {
        guard ContinuousClock.now >= nextStatusUpdate else { return }
        nextStatusUpdate = .now + .seconds(1)
        if preset == .pathTracing && !meshletMapEnabled {
            meshletStatus = "Мешлеты — растровый путь; PT использует свой BVH"
        } else if let status = meshletStatistics?.snapshots.values.first {
            let levels = status.selectedLODLevels.keys.sorted().map { "L\($0): \(status.selectedLODLevels[$0] ?? 0)" }.joined(separator: " / ")
            let lod = meshletLODError > 0
                ? (meshletMapEnabled ? "\n\(levels.isEmpty ? "LOD: нет данных" : levels) · \(status.lodSelectedTriangles) треуг."
                    : " · GPU LOD: \(status.lodGPUItems)") : ""
            meshletStatus = meshletMapEnabled
                ? "Кластеры \(status.candidateMeshlets) · серый = без карты (\(status.fallbackItems))\(lod)"
                : "Кластеры \(status.candidateMeshlets) · GPU \(status.gpuDraws) · целиком \(status.fullyVisibleItems) · fallback \(status.fallbackItems)\(lod)"
        }
        if meshletMapEnabled { dlssStatus = "DLSS: отключён для карты мешлетов" }
        else if dlssEnabled && dlssAvailable, let status = temporalStatistics?.snapshots.values.first {
            dlssStatus = "DLSS · \(status.inputWidth)×\(status.inputHeight) → \(status.outputWidth)×\(status.outputHeight)"
                + " · кадры \(status.encodedFrames) · fallback \(status.fallbackFrames)"
        } else { dlssStatus = dlssAvailable ? "DLSS: выкл." : "DLSS недоступен на текущем устройстве/сборке" }
        guard preset == .pathTracing, let status = pathStatistics?.snapshots.values.first else { return }
        if let failure = status.failure {
            rendererStatus = "Path tracing недоступен: \(failure)"
        } else {
            rendererStatus = "Path tracing · \(status.triangles) треуг. · \(status.lights) источников · \(status.width)×\(status.height)"
                + " · кадр \(status.encodedFrames) · накопление \(status.accumulatedFrames)"
        }
    }
}
