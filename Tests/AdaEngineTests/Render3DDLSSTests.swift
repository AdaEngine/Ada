#if os(Windows)
import AdaCorePipelines
import AdaECS
@_spi(Internal) import AdaRender
import AdaTransform
import AdaUtils
import Foundation
import Math
import Testing

extension Render3DGPUTests {
    @MainActor
    @Suite("DLSS Super Resolution through Dawn", .enabled(if: ProcessInfo.processInfo.environment["ADAENGINE_DLSS_TESTS"] == "1"))
    struct DLSS {
        @Test
        func reconstructsMovingSceneResizesResetsAndReturnsToNative() async throws {
            let scene = try await DebugViews.makeScene(temporalRenderScale: 2.0 / 3.0)
            try #require(scene.device.supportsTemporalUpscaling, "The selected Dawn adapter must actually support NGX DLSS.")
            let first = try await scene.render(.none, frames: 12)
            let renderWorld = try #require(scene.app.getSubworldBuilder(by: .renderWorld))
            let statistics = try #require(renderWorld.getResource(Render3DTemporalStatistics.self))
            let key = "\(scene.camera.id)"
            let initial = try #require(statistics.snapshots[key])
            #expect(initial.encodedFrames >= 12 && initial.fallbackFrames == 0)
            #expect(initial.inputWidth < initial.outputWidth)
            #expect(first.width == 640 && first.height == 480)

            scene.camera.components[Transform.self] = Transform(position: [0.15, 0.5, -3.4])
            let moved = try await scene.render(.none, frames: 6)
            var camera = try #require(scene.camera.components[Camera.self])
            camera.temporalUpscaling = nil
            scene.camera.components[Camera.self] = camera
            let native = try await scene.render(.none, frames: 4)
            // A reconstruction must preserve scene radiance, orientation and framing.
            var difference: Float = 0
            var brightness: Float = 0
            for y in stride(from: 0, to: native.height, by: 4) {
                for x in stride(from: 0, to: native.width, by: 4) {
                    let a = moved.getPixel(x: x, y: y), b = native.getPixel(x: x, y: y)
                    difference += abs(a.red-b.red) + abs(a.green-b.green) + abs(a.blue-b.blue)
                    brightness += a.red + a.green + a.blue
                }
            }
            let samples = Float((native.width/4) * (native.height/4) * 3)
            #expect(brightness/samples > 0.05)
            #expect(difference/samples < 0.08, "DLSS and native must show the same scene after camera motion.")

            for scale: Float in [0.5, 1.0] {
                camera.temporalUpscaling = .init(renderScale: scale, resetGeneration: 2)
                scene.camera.components[Camera.self] = camera
                _ = try await scene.render(.none, frames: 6)
                let snapshot = try #require(statistics.snapshots[key])
                #expect(snapshot.fallbackFrames == 0)
                #expect(snapshot.inputWidth == Int(ceil(Float(snapshot.outputWidth) * scale)))
            }
            let beforeCut = try #require(statistics.snapshots[key]).historyResets
            scene.camera.components[Transform.self] = Transform(position: [8, 0.5, -3.4])
            _ = try await scene.render(.none, frames: 2)
            #expect(try #require(statistics.snapshots[key]).historyResets > beforeCut)
            #expect(scene.device.createTemporalUpscaler(inputSize: [0, 0], outputSize: [640, 480]) == nil)
            try FileManager.default.createDirectory(at: GoldenFrame.outputDirectory, withIntermediateDirectories: true)
            try moved.writePNG(to: GoldenFrame.outputDirectory.appendingPathComponent("dlss-moving-scene.png"))
            try native.writePNG(to: GoldenFrame.outputDirectory.appendingPathComponent("dlss-native-control.png"))
        }
    }
}
#endif
