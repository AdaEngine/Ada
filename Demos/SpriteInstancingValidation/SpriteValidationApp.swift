import AdaApp
import AdaCorePipelines
import AdaECS
import AdaRender
import AdaSprite
import AdaText
import AdaTransform
import AdaUtils
import Foundation
import Math

#if os(iOS)
    import SwiftUI
    import UIKit

    /// Separate QA application; no validation hooks are installed in Studio.
    @main
    struct SpriteValidationApp: SwiftUI.App {
        var body: some SwiftUI.Scene { WindowGroup { ValidationView() } }
    }

    private struct ValidationView: SwiftUI.View {
        @State private var status = "Running Metal A/B readback…"
        @State private var image: UIImage?
        @State private var passed = false
        var body: some SwiftUI.View {
            VStack(spacing: 20) {
                Text("Sprite instancing").font(.title)
                Text(status).foregroundStyle(passed ? .green : .primary).accessibilityIdentifier("validation-status")
                if let image { SwiftUI.Image(uiImage: image).resizable().interpolation(.none).aspectRatio(contentMode: .fit) }
            }
            .padding()
            .task {
                do {
                    unsafe RenderEngine.configurations.preferredBackend = .metal
                    let host = AppWorlds(main: World())
                    host.addPlugin(RenderWorldPlugin())
                    try await host.build()
                    let result = try await SpriteValidationFixture.run()
                    let bytes = result.image.data as CFData
                    guard let provider = CGDataProvider(data: bytes),
                        let cgImage = CGImage(
                            width: 640,
                            height: 360,
                            bitsPerComponent: 8,
                            bitsPerPixel: 32,
                            bytesPerRow: 640 * 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: result.image.format == .bgra8
                                ? [.byteOrder32Little, CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)]
                                : [.byteOrder32Big, CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)],
                            provider: provider,
                            decode: nil,
                            shouldInterpolate: false,
                            intent: .defaultIntent
                        )
                    else { return }
                    let report: [String: Any] = [
                        "passed": true, "backend": String(describing: result.backend), "frames": 10,
                        "quads": result.quads, "draws": result.draws, "pixels": "identical", "controlPixels": "passed",
                    ]
                    let documents = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                    try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                        .write(to: documents.appendingPathComponent("sprite-validation.json"), options: .atomic)
                    image = UIImage(cgImage: cgImage)
                    status = "PASS · Metal · identical pixels\n10 frames · \(result.quads) quads · \(result.draws) draws"
                    passed = true
                } catch {
                    status = "FAIL: \(error)"
                    print("[SpriteValidation] FAIL: \(error)")
                }
            }
        }
    }
#else
    import AdaAssets
    import AdaInput
    import AdaPlatform
    import AdaUI

    @main
    struct SpriteValidationApp: AdaApp.App {
        var body: some AppScene {
            EmptyWindow().transformAppWorlds { world in
                world.insertPlugin(ValidationPlugin(), after: MainSchedulerPlugin.self)
            }
            .window(with: UIWindow.Configuration(title: "Sprite instancing validation", frame: Rect(x: 80, y: 80, width: 960, height: 540)))
        }
    }

    private struct ValidationPlugin: Plugin {
        func setup(in app: AppWorlds) {
            app.addPlugin(TransformPlugin())
            app.addPlugin(AppPlatformPlugin())
            app.addPlugin(InputPlugin())
            app.addPlugin(RenderWorldPlugin())
            app.addPlugin(CameraPlugin())
            app.addPlugin(AssetsPlugin())
            app.addPlugin(VisibilityPlugin())
            app.addPlugin(SpritePlugin())
            app.addPlugin(Mesh2DPlugin())
            app.addPlugin(TextPlugin())
            app.addPlugin(WindowPlugin())
            app.addPlugin(Core2DPlugin())
            app.addPlugin(UpscalePlugin())
            app.addPlugin(UIPlugin())
            app.addSystem(StartupSpriteValidationSystem.self, on: .startup)
        }
    }

    @System
    @MainActor
    func StartupSpriteValidation(_ context: WorldUpdateContext) async {
        do {
            let result = try await SpriteValidationFixture.run()
            context.world.spawn {
                Sprite(texture: Texture2D(image: result.image), size: [640, 360])
                Transform()
            }
            var camera = Camera()
            camera.projection = .custom(ValidationProjection())
            camera.backgroundColor = .green
            context.world.spawn {
                camera
                Transform()
                GlobalViewUniform()
                VisibleEntities()
                Visibility.visible
                CameraRenderGraph(subgraphLabel: .main2D, inputSlot: Main2DRenderNode.InputNode.view)
            }
        } catch {
            print("[SpriteValidation] FAIL: \(error)")
            var camera = Camera()
            camera.backgroundColor = .red
            context.world.spawn {
                camera
                Transform()
                GlobalViewUniform()
                VisibleEntities()
                Visibility.visible
                CameraRenderGraph(subgraphLabel: .main2D, inputSlot: Main2DRenderNode.InputNode.view)
            }
        }
    }

    private struct ValidationProjection: CameraProjection {
        var near: Float { -1 }
        var far: Float { 1000 }
        func makeClipView() -> Transform3D { Transform3D(scale: [Float(2) / 680, Float(2) / 400, 0.001]) }
        mutating func updateView(width: Float, height: Float) {}
    }
#endif
