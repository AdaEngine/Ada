#if os(Windows) || os(Linux)
import AdaAssets
@testable import AdaCorePipelines
import AdaECS
@_spi(Internal) import AdaRender
import AdaScene
import AdaTransform
import AdaUtils
import Foundation
import Math
import Testing

extension Render3DGPUTests {
    /// Compares hardware ray-query traversal with the software BVH on a real Vulkan device with ray-query support.
    /// Runs with `ADAENGINE_GOLDEN_SAGA=1`; devices without ray queries skip the comparison.
    @Suite("Hardware path tracing")
    @MainActor
    struct HardwarePathTracing {
        nonisolated private static var enabled: Bool { GoldenFrame.activeBackend != nil }

        private static func scene(denoiser: PathTracingDenoiser = .portable) async throws -> DebugViews.Scene {
            let scene = try await DebugViews.makeScene(pathTracingPresentation: true)
            try scene.configure {
                $0.imageBasedLighting = nil
                $0.fog.isEnabled = false
                $0.localShadows.isEnabled = false
                $0.pathTracing = .init(isEnabled: true, samplesPerPixel: 2, maximumBounces: 2, resolutionScale: 1, historyLimit: 16)
                $0.pathTracing.denoiser = denoiser
            }
            return scene
        }

        private static func difference(_ a: Image, _ b: Image) -> Float {
            var total: Float = 0
            var count: Float = 0
            for y in stride(from: 0, to: 480, by: 4) {
                for x in stride(from: 0, to: 640, by: 4) {
                    let p = a.getPixel(x: x, y: y), q = b.getPixel(x: x, y: y)
                    total += abs(p.red - q.red) + abs(p.green - q.green) + abs(p.blue - q.blue)
                    count += 3
                }
            }
            return total / count
        }

        private static func status(_ scene: DebugViews.Scene) throws -> PathTracing3DStatus {
            let statistics = try #require(scene.app.getSubworldBuilder(by: .renderWorld)?.getResource(Render3DPathTracingStatistics.self))
            return try #require(statistics.snapshots[String(scene.camera.id)])
        }

        @Test(.enabled(if: HardwarePathTracing.enabled))
        func hardwareTraversalMatchesTheSoftwareBVH() async throws {
            let scene = try await Self.scene()
            guard scene.device.supportsRayQueries else { return }

            try scene.configure { $0.pathTracing.intersection = .software }
            let software = try await scene.render(.none, frames: 24)
            let softwareStatus = try Self.status(scene)
            #expect(softwareStatus.implementation == PathTracingTraversalSelection.Traversal.softwareBVH.rawValue)
            #expect(softwareStatus.intersectionFallback == nil && softwareStatus.failure == nil)

            try scene.configure { $0.pathTracing.intersection = .automatic }
            let hardware = try await scene.render(.none, frames: 24)
            let hardwareStatus = try Self.status(scene)
            #expect(
                hardwareStatus.implementation == PathTracingTraversalSelection.Traversal.hardwareRayQuery.rawValue,
                "implementation \(hardwareStatus.implementation), fallback \(String(describing: hardwareStatus.intersectionFallback)), failure \(String(describing: hardwareStatus.failure))"
            )
            #expect(hardwareStatus.intersectionFallback == nil && hardwareStatus.failure == nil)

            try FileManager.default.createDirectory(at: GoldenFrame.outputDirectory, withIntermediateDirectories: true)
            try software.writePNG(to: GoldenFrame.outputDirectory.appendingPathComponent("hardware-pt-software.png"))
            try hardware.writePNG(to: GoldenFrame.outputDirectory.appendingPathComponent("hardware-pt-hardware.png"))
            let error = Self.difference(software, hardware)
            print("hardware vs software path tracing error \(error)")
            #expect(error < 0.005, "Hardware differs from the software tracer by \(error)")
        }

        /// Renders the scene with both traversals and checks that hardware ran and matches software.
        private static func expectHardwareMatchesSoftware(_ scene: DebugViews.Scene, _ step: String, tolerance: Float = 0.005) async throws {
            try scene.configure { $0.pathTracing.intersection = .software }
            let software = try await scene.render(.none, frames: 24)
            let softwareStatus = try status(scene)
            #expect(softwareStatus.implementation == PathTracingTraversalSelection.Traversal.softwareBVH.rawValue, "\(step)")
            try scene.configure { $0.pathTracing.intersection = .automatic }
            let hardware = try await scene.render(.none, frames: 24)
            let hardwareStatus = try status(scene)
            #expect(
                hardwareStatus.implementation == PathTracingTraversalSelection.Traversal.hardwareRayQuery.rawValue
                    && hardwareStatus.intersectionFallback == nil && hardwareStatus.failure == nil,
                "\(step): \(hardwareStatus.implementation), fallback \(String(describing: hardwareStatus.intersectionFallback)), failure \(String(describing: hardwareStatus.failure))"
            )
            let error = difference(software, hardware)
            print("hardware path tracing \(step): error \(error)")
            #expect(error < tolerance, "\(step): hardware differs from software by \(error)")
            try FileManager.default.createDirectory(at: GoldenFrame.outputDirectory, withIntermediateDirectories: true)
            let name = step.replacingOccurrences(of: " ", with: "-")
            try hardware.writePNG(to: GoldenFrame.outputDirectory.appendingPathComponent("hardware-pt-\(name).png"))
        }

        @Test(.enabled(if: HardwarePathTracing.enabled))
        func movingAddingAndRemovingMeshesKeepsHardwareInStepWithSoftware() async throws {
            let scene = try await Self.scene()
            guard scene.device.supportsRayQueries else { return }
            try await Self.expectHardwareMatchesSoftware(scene, "initial scene")

            let sphere = try #require(scene.sphereEntities.first)
            sphere.components[Transform.self] = Transform(position: [0.4, 0.3, 0.2])
            try await Self.expectHardwareMatchesSoftware(scene, "moved sphere")

            let material = PBRMaterial()
            material.baseColorFactor = [0.2, 0.6, 0.9, 1]
            let cube = scene.app.main.spawn("Added cube") {
                Mesh3DComponent(mesh: Mesh.generateCube(size: [0.6, 0.6, 0.6], renderDevice: scene.device), materials: [material])
                Transform(position: [-1.5, 0.4, -0.5])
            }
            try await Self.expectHardwareMatchesSoftware(scene, "added cube")

            scene.app.main.removeEntity(cube.id, recursively: true)
            try await Self.expectHardwareMatchesSoftware(scene, "removed cube")
        }

        @Test(.enabled(if: HardwarePathTracing.enabled))
        func alphaMaskedAndSingleSidedSurfacesFollowTheSameRulesAsTheSoftwareTracer() async throws {
            let scene = try await Self.scene()
            guard scene.device.supportsRayQueries else { return }
            var pixels = [UInt8]()
            for y in 0..<8 {
                for x in 0..<8 { pixels += [255, 80, 40, (x + y) % 2 == 0 ? 255 : 0] }
            }
            let checker = Texture2D(image: Image(width: 8, height: 8, data: Data(pixels)))
            let masked = PBRMaterial()
            masked.baseColorTexture = checker
            masked.alphaMode = .mask
            masked.alphaCutoff = 0.5
            masked.doubleSided = true
            _ = scene.app.main.spawn("Alpha masked panel") {
                Mesh3DComponent(mesh: Mesh.generateCube(size: [1.6, 1.0, 0.02], renderDevice: scene.device), materials: [masked])
                Transform(position: [0, 0.5, -1.4])
            }
            try await Self.expectHardwareMatchesSoftware(scene, "alpha masked panel")

            let oneSided = PBRMaterial()
            oneSided.baseColorFactor = [0.9, 0.9, 0.2, 1]
            oneSided.doubleSided = false
            _ = scene.app.main.spawn("Single sided plane facing away") {
                Mesh3DComponent(mesh: Mesh.generatePlane(size: [1.2, 1.2], renderDevice: scene.device), materials: [oneSided])
                Transform(rotation: Quat.euler([Float.pi / 2, 0, 0]), position: [1.2, 0.8, -0.8])
            }
            try await Self.expectHardwareMatchesSoftware(scene, "single sided plane")
        }

        @Test(.enabled(if: HardwarePathTracing.enabled))
        func aHardwareFailureFallsBackToSoftwareWithItsReasonAndAnUnchangedImage() async throws {
            let scene = try await Self.scene()
            guard scene.device.supportsRayQueries else { return }
            try scene.configure { $0.pathTracing.intersection = .software }
            let software = try await scene.render(.none, frames: 24)

            try scene.configure { $0.pathTracing.intersection = .automatic }
            _ = try await scene.render(.none, frames: 2)
            let world = try #require(scene.app.getSubworldBuilder(by: .renderWorld))
            var views = try #require(world.getResource(PathTracing3DViews.self))
            views.hardwareFailure = "injected acceleration structure failure"
            world.insertResource(views)
            let fallback = try await scene.render(.none, frames: 24)
            let status = try Self.status(scene)
            #expect(status.implementation == PathTracingTraversalSelection.Traversal.softwareBVH.rawValue)
            #expect(status.intersectionFallback == "injected acceleration structure failure")
            #expect(Self.difference(software, fallback) < 0.005)
        }

        @Test(.enabled(if: HardwarePathTracing.enabled && ProcessInfo.processInfo.environment["ADAENGINE_DLSS"] == "1"))
        func rayReconstructionDenoisesAHardwareTracedFrame() async throws {
            let scene = try await DebugViews.makeScene(temporalRenderScale: 1, pathTracingPresentation: true)
            guard scene.device.supportsRayQueries else { return }
            for _ in 0..<200 where !scene.device.dlssStatus.isAvailable && (scene.device.dlssStatus.unavailableReason ?? "").contains("initializing") {
                try await Task.sleep(for: .milliseconds(50))
            }
            try #require(scene.device.dlssStatus.isAvailable, "DLSS status: \(scene.device.dlssStatus)")
            try scene.configure {
                $0.imageBasedLighting = nil
                $0.fog.isEnabled = false
                $0.localShadows.isEnabled = false
                $0.pathTracing = .init(isEnabled: true, samplesPerPixel: 4, maximumBounces: 2, resolutionScale: 0.5, historyLimit: 16)
                $0.pathTracing.denoiser = .rayReconstruction
            }
            var camera = try #require(scene.camera.components[Camera.self])
            camera.temporalUpscaling = .init(renderScale: 1, method: .dlss)
            scene.camera.components[Camera.self] = camera
            let image = try await scene.render(.none, frames: 24)
            let status = try Self.status(scene)
            #expect(status.implementation == PathTracingTraversalSelection.Traversal.hardwareRayQuery.rawValue, "\(status.implementation) \(String(describing: status.intersectionFallback))")
            #expect(status.denoiser == PathTracingDenoiser.rayReconstruction.rawValue, "\(status.denoiser) \(String(describing: status.denoiserFallback))")
            #expect(status.failure == nil)
            try FileManager.default.createDirectory(at: GoldenFrame.outputDirectory, withIntermediateDirectories: true)
            try image.writePNG(to: GoldenFrame.outputDirectory.appendingPathComponent("hardware-pt-rr.png"))
        }

        /// Frame time of both traversals on a synthetic scene of many shared spheres, static and with one sphere moving every
        /// frame. SAGA reports no per-pass GPU timings, so this measures wall-clock time per frame (CPU preparation plus GPU
        /// work, with a read-back at the end to wait for the GPU). Prints the numbers and does not assert on them.
        /// `ADAENGINE_PERF=1` enables it; `ADAENGINE_PERF_GRID` sets the spheres per side (8 by default).
        @Test(.enabled(if: HardwarePathTracing.enabled && ProcessInfo.processInfo.environment["ADAENGINE_PERF"] == "1"))
        func frameTimeOfHardwareVersusSoftware() async throws {
            let scene = try await Self.scene()
            guard scene.device.supportsRayQueries else { return }
            let grid = Int(ProcessInfo.processInfo.environment["ADAENGINE_PERF_GRID"] ?? "") ?? 8
            let mesh = Mesh.generateSphere(radius: 0.18, renderDevice: scene.device)
            let material = PBRMaterial()
            material.baseColorFactor = [0.8, 0.5, 0.3, 1]
            material.roughnessFactor = 0.5
            var mover: Entity?
            for x in 0..<grid {
                for z in 0..<grid {
                    let entity = scene.app.main.spawn("Benchmark sphere \(x)-\(z)") {
                        Mesh3DComponent(mesh: mesh, materials: [material])
                        Transform(position: [Float(x) * 0.45 - Float(grid) * 0.225, 0.25, Float(z) * 0.45 - 0.5])
                    }
                    if mover == nil { mover = entity }
                }
            }
            let samples = Int(ProcessInfo.processInfo.environment["ADAENGINE_PERF_SPP"] ?? "") ?? 2
            try scene.configure { $0.pathTracing.samplesPerPixel = samples }
            let frames = 40
            var summary: [String] = ["samples per pixel \(samples), 2 bounces, 640x480"]
            func milliseconds(_ duration: Duration) -> Double {
                (Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18) * 1000 / Double(frames)
            }
            for doubleSided in [false, true] {
                material.doubleSided = doubleSided
                for (name, intersection) in [("software BVH", PathTracingIntersection.software), ("hardware ray query", .automatic)] {
                    try scene.configure { $0.pathTracing.intersection = intersection }
                    _ = try await scene.render(.none, frames: 12)
                    let status = try Self.status(scene)
                    // Best of three runs, so a busy machine does not decide the result.
                    var bestStatic = Double.infinity, bestMoving = Double.infinity
                    for _ in 0..<3 {
                        let staticStart = ContinuousClock.now
                        _ = try await scene.render(.none, frames: frames)
                        bestStatic = min(bestStatic, milliseconds(staticStart.duration(to: .now)))
                        let movingStart = ContinuousClock.now
                        for frame in 0..<frames {
                            mover?.components[Transform.self] = Transform(position: [-1.8, 0.25 + Float(frame % 8) * 0.02, -0.5])
                            try await scene.app.update()
                        }
                        _ = try await scene.render(.none, frames: 0)
                        bestMoving = min(bestMoving, milliseconds(movingStart.duration(to: .now)))
                    }
                    let line = "\(doubleSided ? "double-sided" : "single-sided") materials, \(name): \(status.implementation), \(status.triangles) triangles, static \(String(format: "%.2f", bestStatic)) ms/frame, one sphere moving \(String(format: "%.2f", bestMoving)) ms/frame"
                    print("hardware path tracing benchmark: \(line)")
                    summary.append(line)
                }
            }
            try FileManager.default.createDirectory(at: GoldenFrame.outputDirectory, withIntermediateDirectories: true)
            let report = summary.joined(separator: "\n")
            try report.write(to: GoldenFrame.outputDirectory.appendingPathComponent("hardware-pt-benchmark.txt"), atomically: true, encoding: .utf8)
        }

        /// A closed room lit by one lamp: mostly indirect light, so a still image is noisy until it is denoised.
        private static func roomScene() async throws -> (scene: DebugViews.Scene, mover: Entity) {
            let scene = try await scene()
            try scene.setSunIntensity(0)
            for entity in scene.app.main.getEntities() where entity.id != scene.camera.id && entity.id != scene.sun.id {
                scene.app.main.removeEntity(entity)
            }
            func box(_ size: Vector3, at position: Vector3, _ color: Vector4) {
                let material = PBRMaterial()
                material.baseColorFactor = color
                _ = scene.app.main.spawn("Room") {
                    Mesh3DComponent(mesh: Mesh.generateCube(size: size, renderDevice: scene.device), materials: [material])
                    Transform(position: position)
                }
            }
            box([8, 0.2, 8], at: [0, -0.1, 0], [0.8, 0.8, 0.8, 1])
            box([8, 4, 0.2], at: [0, 2, 4], [0.8, 0.8, 0.8, 1])
            box([8, 0.2, 8], at: [0, 4.1, 0], [0.8, 0.8, 0.8, 1])
            box([0.2, 4, 8], at: [-4, 2, 0], [0.75, 0.12, 0.1, 1])
            box([0.2, 4, 8], at: [4, 2, 0], [0.12, 0.6, 0.15, 1])
            _ = scene.app.main.spawn("Lamp") { PointLightComponent(intensity: 22, range: 14); Transform(position: [0, 3.6, 0.4]) }
            let material = PBRMaterial()
            material.baseColorFactor = [0.25, 0.45, 0.9, 1]
            let mover = scene.app.main.spawn("Mover") {
                Mesh3DComponent(mesh: Mesh.generateSphere(radius: 0.7, renderDevice: scene.device), materials: [material])
                Transform(position: [0, 0.7, -0.4])
            }
            try scene.configure { $0.pathTracing.intersection = .software; $0.pathTracing.samplesPerPixel = 2; $0.pathTracing.maximumBounces = 3 }
            return (scene, mover)
        }

        /// Moves a sphere for `frames` frames and returns the last frame, the converged reference of the scene at the final
        /// pose (plain accumulation), and how many times the history restarted and grew during the motion.
        private static func moving(
            _ room: (scene: DebugViews.Scene, mover: Entity), frames: Int, minimumHistoryWeight: Float, strength: Float = 1
        ) async throws -> (moving: Image, flicker: Float, resets: Int, accumulated: Int) {
            let scene = room.scene
            try scene.configure {
                $0.pathTracing.denoiser = .portable
                $0.pathTracing.minimumHistoryWeight = minimumHistoryWeight
                $0.pathTracing.denoiserStrength = strength
            }
            room.mover.components[Transform.self] = Transform(position: [-0.5, 0.7, -0.4])
            _ = try await scene.render(.none, frames: 12)
            let start = try status(scene)
            var last = try await scene.render(.none, frames: 1)
            var flicker: Float = 0
            var samples: Float = 0
            for frame in 0..<frames {
                room.mover.components[Transform.self] = Transform(position: [-0.5 + Float(frame) * 0.04, 0.7, -0.4])
                let next = try await scene.render(.none, frames: 1)
                // Flicker: frame-to-frame change of the right wall, which the moving sphere never covers.
                if frame >= frames / 2 {
                    var total: Float = 0
                    var count: Float = 0
                    // Both walls and the floor in front: regions the moving sphere never covers.
                    for (xs, ys) in [(500..<620, 120..<360), (20..<140, 120..<360), (200..<440, 410..<470)] {
                        for y in stride(from: ys.lowerBound, to: ys.upperBound, by: 3) {
                            for x in stride(from: xs.lowerBound, to: xs.upperBound, by: 3) {
                                let p = next.getPixel(x: x, y: y), q = last.getPixel(x: x, y: y)
                                total += abs(p.red - q.red) + abs(p.green - q.green) + abs(p.blue - q.blue)
                                count += 3
                            }
                        }
                    }
                    flicker += total / count
                    samples += 1
                }
                last = next
            }
            let end = try status(scene)
            return (last, flicker / max(samples, 1), end.historyResets - start.historyResets, end.accumulatedFrames)
        }

        @Test(.enabled(if: HardwarePathTracing.enabled))
        func movingObjectsKeepTheDenoiserHistoryAndLookCleanerThanPerFrameRestarts() async throws {
            let room = try await Self.roomScene()
            // A history weight of 1 uses only the current frame: what restarting the history on every move used to do.
            let restarted = try await Self.moving(room, frames: 20, minimumHistoryWeight: 1)
            let kept = try await Self.moving(room, frames: 20, minimumHistoryWeight: 1.0 / 32)
            #expect(kept.resets == 0, "Moving an object must not restart the denoiser history: \(kept.resets) restarts")
            #expect(kept.accumulated >= 12, "Accumulation keeps counting while an object moves: \(kept.accumulated)")
            print("moving object denoising: flicker per-frame \(restarted.flicker), history kept \(kept.flicker), restarts \(kept.resets), accumulated \(kept.accumulated)")
            try FileManager.default.createDirectory(at: GoldenFrame.outputDirectory, withIntermediateDirectories: true)
            try kept.moving.writePNG(to: GoldenFrame.outputDirectory.appendingPathComponent("moving-denoised-kept.png"))
            try restarted.moving.writePNG(to: GoldenFrame.outputDirectory.appendingPathComponent("moving-denoised-per-frame.png"))
            #expect(kept.flicker < restarted.flicker * 0.7, "Keeping history must calm the noise of moving scenes: \(kept.flicker) vs \(restarted.flicker)")
        }

        @Test(.enabled(if: HardwarePathTracing.enabled))
        func aHigherDenoiserStrengthSmoothsMovingScenesFurtherWithoutWashingOutTheImage() async throws {
            let room = try await Self.roomScene()
            let plain = try await Self.moving(room, frames: 20, minimumHistoryWeight: 1.0 / 32, strength: 1)
            let strong = try await Self.moving(room, frames: 20, minimumHistoryWeight: 1.0 / 32, strength: 4)
            print("denoiser strength: flicker 1 -> \(plain.flicker), 4 -> \(strong.flicker)")
            try FileManager.default.createDirectory(at: GoldenFrame.outputDirectory, withIntermediateDirectories: true)
            try plain.moving.writePNG(to: GoldenFrame.outputDirectory.appendingPathComponent("denoiser-strength-1.png"))
            try strong.moving.writePNG(to: GoldenFrame.outputDirectory.appendingPathComponent("denoiser-strength-4.png"))
            #expect(strong.flicker < plain.flicker * 0.7, "Strength 4 must be calmer than strength 1: \(strong.flicker) vs \(plain.flicker)")
            // Smoothing must not change the overall brightness: compare the mean of both images.
            func mean(_ image: Image) -> Float {
                var total: Float = 0
                for y in stride(from: 0, to: 480, by: 4) { for x in stride(from: 0, to: 640, by: 4) {
                    let pixel = image.getPixel(x: x, y: y)
                    total += pixel.red + pixel.green + pixel.blue
                } }
                return total / Float(120 * 160 * 3)
            }
            #expect(abs(mean(strong.moving) - mean(plain.moving)) < 0.02, "The strong filter must keep the energy: \(mean(strong.moving)) vs \(mean(plain.moving))")
        }

        @Test(.enabled(if: HardwarePathTracing.enabled))
        func changingASceneStillRestartsTheDenoiserHistory() async throws {
            let scene = try await Self.scene()
            try scene.configure { $0.pathTracing.intersection = .software; $0.pathTracing.denoiser = .portable }
            _ = try await scene.render(.none, frames: 16)
            let before = try Self.status(scene)
            let material = PBRMaterial()
            _ = scene.app.main.spawn("Added cube") {
                Mesh3DComponent(mesh: Mesh.generateCube(size: [0.5, 0.5, 0.5], renderDevice: scene.device), materials: [material])
                Transform(position: [-1.5, 0.3, -0.3])
            }
            _ = try await scene.render(.none, frames: 3)
            let after = try Self.status(scene)
            #expect(after.historyResets > before.historyResets, "adding a mesh must restart the history")
        }

        @Test(.enabled(if: HardwarePathTracing.enabled))
        func aDeviceWithoutRayQueriesOrASoftwareRequestReportsTheSoftwareTracer() async throws {
            let scene = try await Self.scene()
            try scene.configure { $0.pathTracing.intersection = .software }
            _ = try await scene.render(.none, frames: 3)
            let status = try Self.status(scene)
            #expect(status.implementation == PathTracingTraversalSelection.Traversal.softwareBVH.rawValue)
            #expect(status.intersectionFallback == nil)
        }
    }
}
#endif
