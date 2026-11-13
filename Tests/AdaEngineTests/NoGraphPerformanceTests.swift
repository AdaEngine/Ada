#if os(macOS) || os(Windows) || os(Linux)
@_spi(Internal) @testable import AdaApp
import AdaCorePipelines
import AdaECS
@_spi(Internal) @testable import AdaRender
import AdaScene
@testable import AdaSprite
import AdaTransform
import AdaUtils
import Foundation
import Math
import Testing

extension Render3DGPUTests {
    @MainActor @Suite("Ordinary Sprite frame performance")
    struct SpriteBenchmarks {
        @Test(.enabled(if: ProcessInfo.processInfo.environment["ADAENGINE_PERF"] == "1" && GoldenFrame.activeBackend != nil),
              arguments: [SpriteRenderingMode.automatic, .batched])
        func ordinarySprites(mode: SpriteRenderingMode) async throws {
            let backend: RenderBackendType = GoldenFrame.activeBackend == .saga ? .saga : .metal
            unsafe RenderEngine.configurations.preferredBackend = backend
            try RenderEngine.setupRenderEngine()
            try #require(unsafe RenderEngine.shared.type == backend)
            let device = unsafe RenderEngine.shared.renderDevice
            let app = AppWorlds(main: World())
            app.insertResource(OffscreenRenderWorld())
                .insertResource(PrimaryWindowId(windowId: RID()))
                .addPlugin(MainSchedulerPlugin()).addPlugin(TransformPlugin())
                .addPlugin(RenderWorldPlugin()).addPlugin(CameraPlugin())
                .addPlugin(AssetsPlugin(filePath: #filePath)).addPlugin(VisibilityPlugin())
                .addPlugin(ScenePlugin()).addPlugin(Core2DPlugin()).addPlugin(SpritePlugin())
            try await app.build()
            let render = try #require(app.getSubworldBuilder(by: .renderWorld)?.main)
            var configuration = SpriteDrawData.defaultValue
            configuration.renderingMode = mode
            render.insertResource(configuration)
            let target = RenderTexture(size: [640, 480], scaleFactor: 1, format: .bgra8)
            var camera = Camera(renderTarget: target)
            camera.backgroundColor = .black
            app.main.spawn("Camera", bundle: Camera2D(camera: camera))
            for index in 0..<4096 {
                app.main.spawn("Sprite \(index)") {
                    Sprite(tintColor: Color(red: 0.1, green: 0.3, blue: 0.9), size: Size(width: 5, height: 5))
                    Transform(position: [Float(index % 64) * 6 - 192, Float(index / 64) * 6 - 192, 0])
                }
            }
            let frames = max(1, Int(ProcessInfo.processInfo.environment["ADAENGINE_PERF_FRAMES"] ?? "") ?? 120)
            let rounds = max(1, Int(ProcessInfo.processInfo.environment["ADAENGINE_PERF_ROUNDS"] ?? "") ?? 3)
            var milliseconds: [Double] = []
            for _ in 0..<rounds {
                for _ in 0..<60 { try await app.update() }
                _ = try #require(try await device.readImage(from: target))
                let start = ContinuousClock.now
                for _ in 0..<frames { try await app.update() }
                let image = try #require(try await device.readImage(from: target))
                let elapsed = start.duration(to: .now).components
                let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
                milliseconds.append(seconds * 1000 / Double(frames))
                let pixel = image.getPixel(x: 320, y: 240)
                #expect(pixel.blue > pixel.red + 0.1, "The measured frames must contain ordinary sprites.")
            }
            let prepared = try #require(render.getResource(SpriteDrawData.self))
            #expect(prepared.usesInstancing == (mode == .automatic))
            let report: [String: Any] = [
                "backend": String(describing: backend), "mode": String(describing: mode), "sprites": 4096,
                "width": 640, "height": 480, "frames": frames, "rounds": rounds,
                "frameMilliseconds": milliseconds, "bestFrameMilliseconds": milliseconds.min() ?? 0,
                "measurement": "CPU + GPU frame wall time, including final readback; no per-pass GPU timestamps"
            ]
            let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted])
            print(String(decoding: data, as: UTF8.self))
            if let directory = ProcessInfo.processInfo.environment["ADAENGINE_PERF_OUTPUT_DIRECTORY"] {
                let root = URL(fileURLWithPath: directory)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                try data.write(to: root.appendingPathComponent("sprite-\(mode).json"))
            }
        }
    }
}
#endif
