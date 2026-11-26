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
    /// Compares DLSS Super Resolution with the portable reconstruction and native resolution on a real NVIDIA GPU.
    /// Needs `ADAENGINE_DLSS=1`, `ADAENGINE_GOLDEN_SAGA=1` and `ADAENGINE_NGX_SDK_PATH` (see `DLSSSmokeTests`).
    @Suite("DLSS Super Resolution")
    @MainActor
    struct DLSSSuperResolution {
        nonisolated private static var enabled: Bool { ProcessInfo.processInfo.environment["ADAENGINE_DLSS"] == "1" && GoldenFrame.activeBackend != nil }

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

        @Test(.enabled(if: Self.enabled))
        func dlssMatchesNativeResolutionAtLeastAsWellAsThePortableReconstruction() async throws {
            let scene = try await DebugViews.makeScene(temporalRenderScale: 0.5)
            for _ in 0..<200 where !scene.device.dlssStatus.isAvailable && (scene.device.dlssStatus.unavailableReason ?? "").contains("initializing") {
                try await Task.sleep(for: .milliseconds(50))
            }
            try #require(scene.device.dlssStatus.isAvailable, "DLSS status: \(scene.device.dlssStatus)")
            var camera = try #require(scene.camera.components[Camera.self])

            func capture(_ method: TemporalReconstructionMethod?) async throws -> Image {
                camera.temporalUpscaling = method.map { .init(renderScale: 0.5, method: $0) }
                scene.camera.components[Camera.self] = camera
                scene.camera.components[Transform.self] = Transform(position: [0, 0.5, -3.4])
                _ = try await scene.render(.none, frames: 12)
                scene.camera.components[Transform.self] = Transform(position: [0.15, 0.5, -3.4])
                return try await scene.render(.none, frames: 8)
            }

            let dlss = try await capture(.dlss)
            let world = try #require(scene.app.getSubworldBuilder(by: .renderWorld))
            let status = try #require(world.getResource(TemporalReconstructionStatuses.self)?[scene.camera.id])
            #expect(status.active == .dlss && status.dlssPreset == .performance && status.fallbackReason == nil, "\(status)")
            let temporal = try #require(world.getResource(Render3DTemporalStatistics.self)?.snapshots["\(scene.camera.id)"])
            #expect(temporal.encodedFrames >= 12 && temporal.fallbackFrames == 0, "DLSS must encode every frame: \(temporal)")
            let portable = try await capture(.portable)
            let native = try await capture(nil)

            let dlssError = Self.difference(dlss, native)
            let portableError = Self.difference(portable, native)
            try FileManager.default.createDirectory(at: GoldenFrame.outputDirectory, withIntermediateDirectories: true)
            try dlss.writePNG(to: GoldenFrame.outputDirectory.appendingPathComponent("dlss-moving.png"))
            try portable.writePNG(to: GoldenFrame.outputDirectory.appendingPathComponent("dlss-portable-moving.png"))
            try native.writePNG(to: GoldenFrame.outputDirectory.appendingPathComponent("dlss-native-moving.png"))
            print("DLSS error \(dlssError), portable error \(portableError)")
            #expect(dlssError < 0.08, "DLSS differs from native by \(dlssError) (portable \(portableError))")
            #expect(dlssError <= portableError * 1.5 + 0.01, "DLSS \(dlssError) is much worse than portable \(portableError)")
        }

        @Test(.enabled(if: Self.enabled))
        func rayReconstructionDenoisesAPathTracedFrame() async throws {
            let scene = try await DebugViews.makeScene(temporalRenderScale: 1, pathTracingPresentation: true)
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
            let denoised = try await scene.render(.none, frames: 24)
            let world = try #require(scene.app.getSubworldBuilder(by: .renderWorld))
            let key = "\(scene.camera.id)"
            let path = try #require(world.getResource(Render3DPathTracingStatistics.self)?.snapshots[key])
            #expect(path.denoiser == PathTracingDenoiser.rayReconstruction.rawValue, "denoiser \(path.denoiser), fallback \(String(describing: path.denoiserFallback))")
            #expect(path.denoiserFallback == nil && path.failure == nil)
            let temporal = try #require(world.getResource(Render3DTemporalStatistics.self)?.snapshots[key])
            #expect(temporal.fallbackFrames == 0, "\(temporal)")
            if ProcessInfo.processInfo.environment["ADAENGINE_TEST_RR_HIT_DISTANCE"] == "1" {
                let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(path)) as? [String: Any])
                #expect(json["rayReconstructionSpecularHitDistance"] as? Bool == true)
            }

            try scene.configure { $0.pathTracing.denoiser = .portable }
            camera.temporalUpscaling = nil
            scene.camera.components[Camera.self] = camera
            let portable = try await scene.render(.none, frames: 24)
            try FileManager.default.createDirectory(at: GoldenFrame.outputDirectory, withIntermediateDirectories: true)
            try denoised.writePNG(to: GoldenFrame.outputDirectory.appendingPathComponent("dlss-rr.png"))
            try portable.writePNG(to: GoldenFrame.outputDirectory.appendingPathComponent("dlss-rr-portable.png"))
            let error = Self.difference(denoised, portable)
            print("RR vs portable denoiser error \(error)")
            #expect(error < 0.12, "Ray Reconstruction differs from the portable denoiser by \(error)")
        }
    }
}
#endif
