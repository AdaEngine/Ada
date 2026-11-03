#if os(macOS) || os(Windows) || os(Linux)
@_spi(Internal) @testable import AdaApp
import AdaECS
@_spi(Internal) @testable import AdaRender
import AdaScene
import AdaTransform
import AdaUtils
import Foundation
import Math
import Testing

@testable import AdaCorePipelines

extension Render3DGPUTests {
    @MainActor
    @Suite("Sponza renderer benchmark")
    struct SponzaBenchmark {
        typealias Baseline = Render3DGPUTests.MeshletBaseline
        nonisolated private static var enabled: Bool {
            GoldenFrame.isEnabled && ProcessInfo.processInfo.environment["ADAENGINE_SPONZA_BASELINE"] == "1"
        }

        struct Sample: Codable {
            var preset: String
            var quality: String
            var route: String
            var round: Int
            var hiZ: Bool
            var importMilliseconds: Double
            var updateMilliseconds: [Double]
            var windowMillisecondsPerFrame: [Double]
            var drainInclusiveMillisecondsPerFrame: Double
            var census: Baseline.Census
            var extractionMilliseconds: [Double]
            var listPreparationMilliseconds: [Double]
            var mainNodeMilliseconds: [Double]
            var gpuPasses: [Render3DPerformanceMetrics.Sample]
        }

        struct Report: Codable {
            var schema = 1
            var complete = false
            var cameraPoseProtocol = "same-frame-root-world-pose-v1"
            var backend: String
            var width: Int
            var height: Int
            var frames: Int
            var warmup: Int
            var rounds: Int
            var completionProtocol = "native-queue-throughput-window-v1"
            var submissionWindowFrames: Int
            var sourceReceipt: SponzaBenchmarkData.Receipt
            var routes: SponzaBenchmarkData.Routes
            var measurements: [Sample]
        }

        private static func integer(_ name: String, fallback: Int, range: ClosedRange<Int>) throws -> Int {
            guard let raw = ProcessInfo.processInfo.environment["ADAENGINE_SPONZA_" + name] else { return fallback }
            let value = try #require(Int(raw))
            try #require(range.contains(value), "Invalid benchmark setting \(name)")
            return value
        }

        private static func filtered(_ values: [String], key: String) throws -> [String] {
            guard let value = ProcessInfo.processInfo.environment["ADAENGINE_SPONZA_" + key], value != "all" else { return values }
            try #require(values.contains(value), "Unknown \(key): \(value)")
            return [value]
        }

        @discardableResult
        private static func setPose(
            _ scene: MeshletBaselineFixtures.Scene, route: SponzaBenchmarkData.Route, sample: Int, count: Int
        ) -> Transform {
            let transform = route.transform(sample: sample, count: count)
            scene.camera.components[Transform.self] = transform
            // This benchmark controls an unparented camera outside the scheduler. CameraSystem runs
            // in preUpdate, before postUpdate transform propagation: publish this frame's world pose.
            scene.camera.components[GlobalTransform.self] = GlobalTransform(matrix: transform.matrix)
            return transform
        }

        private static func capture(
            _ scene: MeshletBaselineFixtures.Scene, route: SponzaBenchmarkData.Route, samples: Int, frame: Int
        ) async throws -> Image {
            let pose = setPose(scene, route: route, sample: frame, count: samples)
            try await scene.app.update()
            await Baseline.drain(scene.device)
            let camera = try #require(scene.camera.components[Camera.self])
            try #require(camera.viewMatrix == pose.matrix.inverse, "Capture must use the requested pose without a frame of camera lag")
            let image = try #require(try await scene.device.readImage(from: scene.target))
            var minimum: Float = .greatestFiniteMagnitude, maximum: Float = 0
            for y in stride(from: 0, to: image.height, by: max(1, image.height / 32)) {
                for x in stride(from: 0, to: image.width, by: max(1, image.width / 32)) {
                    let pixel = image.getPixel(x: x, y: y)
                    let value = pixel.red + pixel.green + pixel.blue
                    minimum = min(minimum, value)
                    maximum = max(maximum, value)
                }
            }
            try #require(maximum - minimum > 0.02, "Camera must render meaningful geometry, rather than only clear/dither")
            return image
        }

        private static func measure(
            _ scene: MeshletBaselineFixtures.Scene, preset: String, quality: String, route: SponzaBenchmarkData.Route,
            samples: Int, frames: Int, warmup: Int, round: Int, hiZ: Bool, importMilliseconds: Double
        ) async throws -> (Sample, [Image]) {
            let world = try #require(scene.app.getSubworldBuilder(by: .renderWorld)?.main)
            var environment = try #require(scene.camera.components[Environment3D.self])
            environment.gpuOcclusionEnabled = hiZ
            scene.camera.components[Environment3D.self] = environment
            setPose(scene, route: route, sample: 0, count: samples)
            let window = GoldenFrame.activeBackend == .webgpu ? min(frames, 90) : max(1, unsafe RenderEngine.configurations.maxFramesInFlight)
            for frame in 0..<warmup {
                try await scene.app.update()
                if (frame + 1) % window == 0 { await Baseline.drain(scene.device) }
            }
            await Baseline.drain(scene.device)
            let metrics = Render3DPerformanceMetrics(warmupSamples: 0, synchronizesPasses: false)
            world.insertResource(metrics)
            var updates: [Double] = [], windows: [Double] = []
            var frame = 0, elapsed: Double = 0
            while frame < frames {
                let count = min(window, frames - frame), start = ContinuousClock.now
                for offset in 0..<count {
                    let tick = ContinuousClock.now
                    let index = (frame + offset) * (samples - 1) / (frames - 1)
                    setPose(scene, route: route, sample: index, count: samples)
                    try await scene.app.update()
                    updates.append(Baseline.milliseconds(since: tick))
                }
                await Baseline.drain(scene.device)
                let duration = Baseline.milliseconds(since: start)
                elapsed += duration
                windows.append(duration / Double(count))
                frame += count
            }
            let finalCamera = try #require(scene.camera.components[Camera.self])
            try #require(finalCamera.viewMatrix == route.transform(sample: samples - 1, count: samples).matrix.inverse)
            let census = try Baseline.census(scene, world: world)
            try #require(census.batches > 0 && census.triangles > 0)
            if hiZ { try #require(world.getResource(GPUVisibility3DState.self)?.output(for: scene.camera.id) != nil) }
            let gpuPasses = metrics.samples
            var captures: [Image] = []
            for index in [0, (samples - 1) / 2, samples - 1] {
                captures.append(try await capture(scene, route: route, samples: samples, frame: index))
            }
            let diagnostics = try await Baseline.cpuDiagnostics(scene, world: world)
            return (Sample(preset: preset, quality: quality, route: route.id, round: round, hiZ: hiZ,
                importMilliseconds: importMilliseconds, updateMilliseconds: updates, windowMillisecondsPerFrame: windows,
                drainInclusiveMillisecondsPerFrame: elapsed / Double(frames), census: census,
                extractionMilliseconds: diagnostics.0, listPreparationMilliseconds: diagnostics.1,
                mainNodeMilliseconds: diagnostics.2, gpuPasses: gpuPasses), captures)
        }

        @Test(.enabled(if: Self.enabled))
        func runsFixedCameraPathsThroughProductionRenderer() async throws {
            let environment = ProcessInfo.processInfo.environment
            let assets = URL(fileURLWithPath: try #require(environment["ADAENGINE_SPONZA_ASSETS"]), isDirectory: true)
            let routes = try SponzaBenchmarkData.Routes.load(try #require(environment["ADAENGINE_SPONZA_ROUTES"]))
            let receiptURL = assets.deletingLastPathComponent().appendingPathComponent("receipt.json")
            let receipt = try JSONDecoder().decode(SponzaBenchmarkData.Receipt.self, from: Data(contentsOf: receiptURL))
            try #require(receipt.schema == 1 && receipt.status == "complete" && receipt.dataset == "intel-sponza-2022" && receipt.profileGenerator == 2)
            let output = URL(fileURLWithPath: try #require(environment["ADAENGINE_SPONZA_OUTPUT"]), isDirectory: true)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            let width = try Self.integer("WIDTH", fallback: 1280, range: 64...4096)
            let height = try Self.integer("HEIGHT", fallback: 720, range: 64...4096)
            let frames = try Self.integer("FRAMES", fallback: 600, range: 3...600)
            let warmup = try Self.integer("WARMUP", fallback: 60, range: 3...600)
            let rounds = try Self.integer("ROUNDS", fallback: 3, range: 1...20)
            let presets = try Self.filtered(["sponza-base", "sponza-ivy"], key: "PRESET")
            let qualities = try Self.filtered(["geometry", "pbr"], key: "QUALITY")
            let needed: Set<String> = presets.contains("sponza-ivy") ? ["base", "ivy"] : ["base"]
            try #require(needed.isSubset(of: Set(receipt.archives.map(\.id))))
            try #require(Set(qualities).isSubset(of: Set(receipt.profiles)), "Requested quality is not prepared in this cache")
            let routeIDs = try Self.filtered(routes.routes.map(\.id), key: "ROUTE")
            var report = Report(backend: GoldenFrame.activeBackend?.rawValue ?? "unknown", width: width, height: height,
                frames: frames, warmup: warmup, rounds: rounds,
                submissionWindowFrames: GoldenFrame.activeBackend == .webgpu ? min(frames, 90) : max(1, unsafe RenderEngine.configurations.maxFramesInFlight),
                sourceReceipt: receipt, routes: routes, measurements: [])
            for preset in presets {
                for quality in qualities {
                    let started = ContinuousClock.now
                    let scene = try await SponzaBenchmarkData.scene(preset: preset, quality: quality, root: assets, size: [width, height], routes: routes)
                    let importMilliseconds = Baseline.milliseconds(since: started)
                    for route in routes.routes where routeIDs.contains(route.id) {
                        for round in 0..<rounds {
                            var images: [[Image]] = []
                            for hiZ in round.isMultiple(of: 2) ? [false, true] : [true, false] {
                                let (sample, captures) = try await Self.measure(scene, preset: preset, quality: quality, route: route,
                                    samples: routes.samples, frames: frames, warmup: warmup, round: round, hiZ: hiZ, importMilliseconds: importMilliseconds)
                                report.measurements.append(sample)
                                images.append(captures)
                                print("SPONZA \(preset) \(quality) \(route.id) round=\(round) hiz=\(hiZ) ms=\(sample.drainInclusiveMillisecondsPerFrame)")
                                if round == 0 {
                                    for (index, image) in captures.enumerated() {
                                        try image.writePNG(to: output.appendingPathComponent("\(preset)-\(quality)-\(route.id)-\(index)-hiz-\(hiZ).png"))
                                    }
                                }
                            }
                            for index in 0..<3 { try #require(images[0][index].data == images[1][index].data, "Hi-Z changed camera pose \(index)") }
                            let encoder = JSONEncoder()
                            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                            try encoder.encode(report).write(to: output.appendingPathComponent("sponza-baseline.json"), options: .atomic)
                        }
                    }
                }
            }
            report.complete = true
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(report).write(to: output.appendingPathComponent("sponza-baseline.json"), options: .atomic)
        }
    }
}
#endif
