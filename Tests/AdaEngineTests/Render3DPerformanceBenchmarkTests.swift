#if os(macOS) || os(Windows) || os(Linux)
@_spi(Internal) @testable import AdaApp
import AdaAssets
import AdaECS
@_spi(Internal) @testable import AdaRender
import AdaScene
import AdaTransform
import AdaUtils
import Foundation
import Math
#if canImport(Metal)
import Metal
#endif
import Testing

@testable import AdaCorePipelines

/// Measures what each 3D effect costs on a heavy scene. It records timings and asserts nothing about speed, so it
/// never fails on a slow machine; it fails only when a configuration renders nothing.
///
/// Run: `ADAENGINE_PERF=1 swift test -c release --filter Render3DGPUTests/Benchmarks`, optionally with
/// `ADAENGINE_PERF_OUTPUT=<file>` to also write the report as Markdown and `ADAENGINE_PERF_SIZE=1920x1080`
/// to change the target size, `ADAENGINE_PERF_FILTER=bare,ssr` to run only matching configurations, and
/// `ADAENGINE_PERF_ROUNDS` / `ADAENGINE_PERF_FRAMES` to trade time for stability. Passes are serialized so each pass duration is isolated from other GPU work; the
/// summed pass time is therefore a lower bound on the frame time, not the frame time itself.
extension Render3DGPUTests {
    @Suite("3D performance benchmarks")
    @MainActor
    struct Benchmarks {
        nonisolated static let enabled = ProcessInfo.processInfo.environment["ADAENGINE_PERF"] == "1" && GoldenFrame.activeBackend != nil

        struct Configuration {
            var name: String
            var detail: String
            var apply: (inout Environment3D) -> Void
            var temporalScale: Float?
            var extraLights = true
            /// Additional unshadowed point lights spread over the grid, on top of the default lights.
            var manyLights = 0
        }

        /// Spheres per side of the grid (400 spheres by default). `ADAENGINE_PERF_GRID=70` stresses the CPU with 4,900.
        private static var grid: Int { Int(ProcessInfo.processInfo.environment["ADAENGINE_PERF_GRID"] ?? "") ?? 20 }

        private static var size: SizeInt {
            let parts = (ProcessInfo.processInfo.environment["ADAENGINE_PERF_SIZE"] ?? "1920x1080").split(separator: "x").compactMap { Int($0) }
            return parts.count == 2 ? SizeInt(width: parts[0], height: parts[1]) : SizeInt(width: 1920, height: 1080)
        }

        /// A grid of spheres with eight materials, a ground, a sun with cascaded shadows and a ring of local lights.
        private static func makeScene(size: SizeInt, temporalScale: Float?, localLights: Bool, manyLights: Int = 0) async throws -> Render3DGPUTests.DebugViews.Scene {
            let backend: RenderBackendType = GoldenFrame.activeBackend == .saga ? .saga : .metal
            unsafe RenderEngine.configurations.preferredBackend = backend
            try RenderEngine.setupRenderEngine()
            try #require(unsafe RenderEngine.shared.type == backend)
            let device = unsafe RenderEngine.shared.renderDevice
            #if canImport(Metal)
            let queue = backend == .metal ? try #require(MetalInterop.commandQueue(for: device)) : nil
            #endif
            let app = AppWorlds(main: World())
            app.insertResource(OffscreenRenderWorld())
                .insertResource(PrimaryWindowId(windowId: RID()))
                .addPlugin(MainSchedulerPlugin())
                .addPlugin(TransformPlugin())
                .addPlugin(RenderWorldPlugin())
                .addPlugin(CameraPlugin())
                .addPlugin(AssetsPlugin(filePath: #filePath))
                .addPlugin(VisibilityPlugin())
                .addPlugin(ScenePlugin())
                .addPlugin(Core3DPlugin())
            if temporalScale != nil {
                app.addPlugin(UpscalePlugin())
            }
            try await app.build()

            let target = RenderTexture(size: size, scaleFactor: 1, format: .bgra8)
            var environment = Environment3D()
            environment.shadowCascadeCount = 3
            var camera = Camera(renderTarget: target)
            camera.backgroundColor = Color(red: 0.55, green: 0.7, blue: 0.9)
            if let temporalScale {
                camera.temporalUpscaling = TemporalUpscalingSettings(renderScale: temporalScale)
            }
            let cameraEntity = app.main.spawn(
                "Camera",
                bundle: Camera3D(camera: camera, transform: Transform(rotation: Quat(axis: .right, angle: 0.32), position: [0, 7 * Float(grid) / 20, -15 * Float(grid) / 20]), environment: environment)
            )
            let sunEntity = app.main.spawn("Sun") {
                DirectionalLightComponent(radiance: [1, 0.95, 0.85], intensity: 3, castShadows: true)
                Transform(rotation: Quat.euler([-0.9, 0.6, 0]))
            }
            let sphere = Mesh.generateSphere(radius: 0.5, renderDevice: device)
            let materials: [PBRMaterial] = (0..<8).map { index in
                let material = PBRMaterial()
                material.baseColorFactor = [0.35 + 0.08 * Float(index), 0.45, 0.8 - 0.07 * Float(index), 1]
                material.roughnessFactor = 0.15 + 0.1 * Float(index)
                material.metallicFactor = index % 2 == 0 ? 0 : 0.9
                return material
            }
            for row in 0..<grid {
                for column in 0..<grid {
                    app.main.spawn("Sphere \(row)-\(column)") {
                        Mesh3DComponent(mesh: sphere, materials: [materials[(row + column) % materials.count]])
                        Transform(position: [Float(column) * 1.25 - Float(grid) * 0.6, 0.5, Float(row) * 1.25 - 5])
                    }
                }
            }
            let ground = PBRMaterial()
            ground.baseColorFactor = [0.35, 0.4, 0.35, 1]
            ground.roughnessFactor = 0.9
            ground.metallicFactor = 0
            app.main.spawn("Ground") {
                Mesh3DComponent(mesh: Mesh.generateCube(size: [2 * Float(grid), 0.1, 2 * Float(grid)], renderDevice: device), materials: [ground])
                Transform(position: [0, -0.05, Float(grid) * 0.4])
            }
            for index in 0..<manyLights {
                let column = Float(index % 6), row = Float(index / 6)
                app.main.spawn("Fill \(index)") {
                    PointLightComponent(radiance: [0.6, 0.8, 1], intensity: 3, castShadows: false, range: 5)
                    Transform(position: [column * 4 - 10, 1.5, row * 4 - 2])
                }
            }
            if localLights {
                for index in 0..<6 {
                    let angle = Float(index) / 6 * 2 * .pi
                    app.main.spawn("Point \(index)") {
                        PointLightComponent(radiance: [1, 0.7, 0.5], intensity: 4, castShadows: index < 2, range: 9)
                        Transform(position: [Math.cos(angle) * 6, 2, 6 + Math.sin(angle) * 5])
                    }
                }
                for index in 0..<2 {
                    app.main.spawn("Spot \(index)") {
                        SpotLightComponent(intensity: 18, castShadows: index == 0, range: 16)
                        Transform(rotation: Quat(axis: .right, angle: .pi / 2.4), position: [Float(index) * 8 - 4, 6, 4])
                    }
                }
            }
            #if canImport(Metal)
            return Render3DGPUTests.DebugViews.Scene(app: app, device: device, target: target, queue: queue, camera: cameraEntity, sun: sunEntity)
            #else
            return Render3DGPUTests.DebugViews.Scene(app: app, device: device, target: target, camera: cameraEntity, sun: sunEntity)
            #endif
        }

        /// Created on first use, after the renderer exists.
        private static let lut = AssetHandle(Texture2D(image: Image(width: 256, height: 16, color: .white)))

        private static func configurations() -> [Configuration] {
            func bare(_ environment: inout Environment3D) {
                environment.ambientOcclusion.isEnabled = false
                environment.screenSpaceReflection.isEnabled = false
                environment.antiAliasing = .none
            }
            return [
                Configuration(name: "bare", detail: "geometry, shadows and composite only", apply: bare),
                Configuration(name: "shadow cache off", detail: "bare, local shadow faces redrawn every frame") {
                    bare(&$0)
                    $0.localShadows.reusesStaticFaces = false
                },
                Configuration(name: "lights off", detail: "bare, no local lights", apply: bare, extraLights: false),
                Configuration(name: "+ ssao", detail: "bare + SSAO") { bare(&$0); $0.ambientOcclusion.isEnabled = true },
                Configuration(name: "+ ssr", detail: "bare + SSR") { bare(&$0); $0.screenSpaceReflection.isEnabled = true },
                Configuration(name: "+ ssr 16 steps", detail: "bare + SSR limited to 16 ray steps") {
                    bare(&$0)
                    $0.screenSpaceReflection.isEnabled = true
                    $0.screenSpaceReflection.maxSteps = 16
                },
                Configuration(name: "+ ssr 1 step", detail: "bare + SSR with a single ray step (cost without tracing)") {
                    bare(&$0)
                    $0.screenSpaceReflection.isEnabled = true
                    $0.screenSpaceReflection.maxSteps = 1
                },
                Configuration(name: "+ fxaa", detail: "bare + FXAA") { bare(&$0); $0.antiAliasing = .fxaa },
                Configuration(name: "+ bloom", detail: "bare + bloom") { bare(&$0); $0.postProcess.bloom.isEnabled = true },
                Configuration(name: "+ auto exposure", detail: "bare + auto exposure") { bare(&$0); $0.postProcess.autoExposure.isEnabled = true },
                Configuration(name: "+ depth of field", detail: "bare + DoF (radius 10)") {
                    bare(&$0)
                    $0.postProcess.depthOfField = DepthOfField3D(isEnabled: true, focusDistance: 14, aperture: 1.5, maximumBlurRadius: 10)
                },
                Configuration(name: "32 lights", detail: "bare + 24 unshadowed point lights (32 local lights in all)", apply: bare, manyLights: 24),
                Configuration(name: "+ fog", detail: "bare + distance and height fog") {
                    bare(&$0)
                    $0.fog = Fog3D(isEnabled: true, density: 0.02, heightFalloff: 0.1)
                },
                Configuration(name: "+ light shafts 16", detail: "fog + sun light shafts, 16 steps") {
                    bare(&$0)
                    $0.fog = Fog3D(isEnabled: true, density: 0.02, volumetric: VolumetricFog3D(isEnabled: true, steps: 16, maxDistance: 40))
                },
                Configuration(name: "+ light shafts 48", detail: "fog + sun light shafts, 48 steps") {
                    bare(&$0)
                    $0.fog = Fog3D(isEnabled: true, density: 0.02, volumetric: VolumetricFog3D(isEnabled: true, steps: 48, maxDistance: 40))
                },
                Configuration(name: "+ grading", detail: "bare + vignette, saturation, contrast") {
                    bare(&$0)
                    $0.postProcess.vignette.intensity = 0.4
                    $0.postProcess.colorGrading.saturation = 1.1
                    $0.postProcess.colorGrading.contrast = 1.1
                },
                Configuration(name: "+ lut", detail: "bare + LUT") { bare(&$0); $0.postProcess.colorGrading.lut = Self.lut },
                Configuration(name: "everything", detail: "all effects on") {
                    $0.ambientOcclusion.isEnabled = true
                    $0.screenSpaceReflection.isEnabled = true
                    $0.antiAliasing = .fxaa
                    $0.postProcess.bloom.isEnabled = true
                    $0.postProcess.autoExposure.isEnabled = true
                    $0.postProcess.depthOfField = DepthOfField3D(isEnabled: true, focusDistance: 14, aperture: 1.5, maximumBlurRadius: 10)
                    $0.postProcess.vignette.intensity = 0.4
                    $0.postProcess.colorGrading.lut = Self.lut
                },
                Configuration(name: "temporal 0.75", detail: "bare with MetalFX at 75% render scale", apply: bare, temporalScale: 0.75),
            ]
        }

        struct Result {
            var configuration: Configuration
            var samples: [Render3DPerformanceMetrics.Sample]
            var frameMilliseconds: Double
            var totalAverage: Double
            /// Milliseconds per frame with nothing serialized: the rate the engine really sustains.
            var freeRunningMilliseconds: Double
        }

        private static func measure(_ configuration: Configuration, size: SizeInt, warmup: Int, frames: Int) async throws -> Result {
            let scene = try await makeScene(size: size, temporalScale: configuration.temporalScale, localLights: configuration.extraLights, manyLights: configuration.manyLights)
            try scene.configure(configuration.apply)
            let metrics = Render3DPerformanceMetrics(warmupSamples: 0, synchronizesPasses: true)
            let renderWorld = try #require(scene.app.getSubworldBuilder(by: .renderWorld)?.main)
            renderWorld.insertResource(metrics)
            for _ in 0..<warmup {
                try await scene.app.update()
            }
            // Warmup frames may have recorded timings; measure from a fresh recorder.
            let measured = Render3DPerformanceMetrics(warmupSamples: 0, synchronizesPasses: true)
            renderWorld.insertResource(measured)
            let start = ContinuousClock.now
            for _ in 0..<frames {
                try await scene.app.update()
            }
            let elapsed = start.duration(to: .now)
            let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            // Free running: no per-pass waits, so CPU work and GPU work overlap as they do in a real frame loop.
            renderWorld.insertResource(Render3DPerformanceMetrics(warmupSamples: 0, synchronizesPasses: false))
            let freeStart = ContinuousClock.now
            for _ in 0..<frames {
                try await scene.app.update()
            }
            let image = try await scene.render(.none, frames: 0)
            let freeElapsed = freeStart.duration(to: .now)
            let freeSeconds = Double(freeElapsed.components.seconds) + Double(freeElapsed.components.attoseconds) / 1e18
            try #require(image.width == size.width, "The benchmark scene must render.")
            return Result(
                configuration: configuration,
                samples: measured.samples,
                frameMilliseconds: seconds / Double(frames) * 1000,
                totalAverage: measured.totalAverageMilliseconds,
                freeRunningMilliseconds: freeSeconds / Double(frames) * 1000
            )
        }

        private static func markdown(_ results: [Result], size: SizeInt, frames: Int, rounds: Int) -> String {
            let grid = Self.grid
            var passes = Set<String>()
            for result in results { for sample in result.samples { passes.insert(sample.pass) } }
            let columns = passes.sorted()
            func cell(_ value: Double?) -> String { value.map { String(format: "%.2f", $0) } ?? "-" }
            var lines = [
                "Scene: \(grid * grid) PBR spheres (8 materials), ground, sun with 3 cascades, 6 point and 2 spot lights, \(size.width)x\(size.height), \(frames) measured frames, best of \(rounds) rounds.",
                (GoldenFrame.activeBackend == .metal ? "Pass times are GPU milliseconds with passes serialized; `sum` adds the pass averages and `wall` is time per frame including those waits, and `free` is time per frame with nothing serialized (the sustained rate)." : "WebGPU has no per-pass GPU timestamps here. `wall` and `free` are CPU + GPU frame wall time; `free` includes a final readback. The GPU pass/sum columns are unavailable."),
                "",
                "| configuration | " + columns.joined(separator: " | ") + " | sum | wall | free |",
                "| --- | " + columns.map { _ in "---:" }.joined(separator: " | ") + " | ---: | ---: | ---: |",
            ]
            for result in results {
                let byName = Dictionary(uniqueKeysWithValues: result.samples.map { ($0.pass, $0.averageMilliseconds) })
                lines.append("| \(result.configuration.name) | " + columns.map { cell(byName[$0]) }.joined(separator: " | ") + " | \(cell(result.samples.isEmpty ? nil : result.totalAverage)) | \(cell(result.frameMilliseconds)) | \(cell(result.freeRunningMilliseconds)) |")
            }
            return lines.joined(separator: "\n")
        }

        /// GPU clocks ramp and settle between runs, so a single pass over the configurations is noisy. Each
        /// configuration is measured in several rounds and every figure keeps its best (lowest) round.
        private static func combine(_ rounds: [Result]) -> Result {
            var best: [String: Render3DPerformanceMetrics.Sample] = [:]
            for result in rounds {
                for sample in result.samples where sample.averageMilliseconds < (best[sample.pass]?.averageMilliseconds ?? .infinity) {
                    best[sample.pass] = sample
                }
            }
            let samples = best.values.sorted { $0.pass < $1.pass }
            return Result(
                configuration: rounds[0].configuration,
                samples: samples,
                frameMilliseconds: rounds.map(\.frameMilliseconds).min() ?? 0,
                totalAverage: samples.reduce(0) { $0 + $1.averageMilliseconds },
                freeRunningMilliseconds: rounds.map(\.freeRunningMilliseconds).min() ?? 0
            )
        }

        @Test(.enabled(if: Benchmarks.enabled))
        func effectCostsOnAHeavyScene() async throws {
            let size = Self.size
            let frames = Int(ProcessInfo.processInfo.environment["ADAENGINE_PERF_FRAMES"] ?? "") ?? 90
            let rounds = Int(ProcessInfo.processInfo.environment["ADAENGINE_PERF_ROUNDS"] ?? "") ?? 3
            // ADAENGINE_PERF_FILTER="bare,ssr" keeps only configurations whose name contains one of the words.
            let words = (ProcessInfo.processInfo.environment["ADAENGINE_PERF_FILTER"] ?? "").split(separator: ",").map(String.init)
            let configurations = Self.configurations().filter { configuration in
                (words.isEmpty || words.contains { configuration.name.contains($0) })
                    && (GoldenFrame.activeBackend == .metal || configuration.temporalScale == nil)
            }
            try #require(!configurations.isEmpty, "No requested benchmark configuration is supported by this backend.")
            var collected = [[Result]](repeating: [], count: configurations.count)
            for _ in 0..<rounds {
                for (index, configuration) in configurations.enumerated() {
                    collected[index].append(try await Self.measure(configuration, size: size, warmup: 60, frames: frames))
                }
            }
            let results = collected.map(Self.combine)
            let report = Self.markdown(results, size: size, frames: frames, rounds: rounds)
            print("PERF REPORT\n" + report)
            if let path = ProcessInfo.processInfo.environment["ADAENGINE_PERF_OUTPUT"] {
                try report.write(toFile: path, atomically: true, encoding: .utf8)
            }
            if GoldenFrame.activeBackend == .metal {
                #expect(results.allSatisfy { !$0.samples.isEmpty }, "Every configuration must record GPU pass timings.")
            }
            #expect(results.allSatisfy { $0.frameMilliseconds > 0 && $0.freeRunningMilliseconds > 0 })
        }
    }
}
#endif
