import AdaEngine
import Foundation
import Testing

extension Render3DGPUTests {
    @Suite("Movie Maker GPU capture")
    @MainActor
    struct MovieMakerGPU {
        @Test(.enabled(if: GoldenFrame.isEnabled))
        func recordsCameraPixelsAndCameraCut() async throws {
            let previousBackend = unsafe RenderEngine.configurations.preferredBackend
            defer { unsafe RenderEngine.configurations.preferredBackend = previousBackend }
            unsafe RenderEngine.configurations.preferredBackend = GoldenFrame.activeBackend == .webgpu ? .webgpu : .metal
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("AdaMovieGPU-\(UUID())")
            defer { try? FileManager.default.removeItem(at: root) }
            var first: Entity?
            var second: Entity?
            let maker = MovieMaker()
            let config = MovieRecordingConfiguration(outputURL: root.appendingPathComponent("gpu.png"), width: 37, height: 19, frameCount: 2, includesAudio: false)
            try await maker.record(configuration: config, make: { app in
                app.addPlugin(TransformPlugin()).addPlugin(RenderWorldPlugin()).addPlugin(CameraPlugin()).addPlugin(Core2DPlugin())
                var red = Camera()
                red.backgroundColor = .red
                first = app.spawn("Red", bundle: Camera2D(camera: red))
                var blue = Camera()
                blue.backgroundColor = .blue
                blue.isActive = false
                second = app.spawn("Blue", bundle: Camera2D(camera: blue))
            }, update: { _, frame in
                if frame.index == 1 {
                    first?.components[Camera.self]?.isActive = false
                    second?.components[Camera.self]?.isActive = true
                }
            })
            let red = try Image(contentsOf: root.appendingPathComponent("gpu00000000.png"))
            let blue = try Image(contentsOf: root.appendingPathComponent("gpu00000001.png"))
            #expect(red.width == 37 && red.height == 19)
            #expect(red.getPixel(x: 18, y: 9).red > 0.98)
            #expect(red.getPixel(x: 18, y: 9).blue < 0.02)
            #expect(blue.getPixel(x: 18, y: 9).blue > 0.98)
            #expect(blue.getPixel(x: 18, y: 9).red < 0.02)
            #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("gpu.wav").path))
        }
    }
}
