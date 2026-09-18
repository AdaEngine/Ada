//
// Created by v.prusakov on 12/25/22.
//

#if canImport(MetalKit)
    import AdaApp
    @_spi(Internal) import AdaEngine
    @_spi(Internal) import AdaPlatform
    import AdaUI
    import Logging
    import MetalKit

    // FIXME: Not works

    /// The view for rendering AdaEngine scenes and views.
    /// You can insert this view in your application and just pass scene or view to constructor.
    /// This view will perfectly fit for any sizes.
    @MainActor
    public final class AEView: MetalView {
        /// Contains view where all render happens.
        /// You can grab information about all views.
        public let engineWindow: AdaEngine.UIWindow

        private let logger = Logger(label: "org.adaengine.AEView")

        /// Create AEView with AdaEngine.View.
        public init(view: AdaUI.UIView, frame: CGRect) throws {
            let rect = frame.toEngineRect

            /// We should avoid multiple instancing of this object
            if Application.shared == nil {
                let app = try AppleApplication(argc: CommandLine.argc, argv: CommandLine.unsafeArgv)
                Application.setApplication(app)
            }

            let window = AdaEngine.UIWindow(frame: rect)
            window.addSubview(view)

            let appContext = AppContext(_EmbeddableApp(window: window))
            self.engineWindow = window

            super.init(windowId: window.id, frame: frame)

            Application.shared.appleWindowManager.nativeView = self
            self.delegate = self

            Task { @MainActor in
                do {
                    try await appContext.run()
                    try RenderEngine.shared.createWindow(window.id, for: self, size: rect.size.toSizeInt())
                    try AudioServer.shared.start()
                } catch {
                    logger.error("[AEView Error]: \(error.localizedDescription)")
                }
            }
        }

        @available(*, unavailable)
        public required init(coder _: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        deinit {
            do {
                try AudioServer.shared.stop()
            } catch {
                logger.error("[AEView Error]: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - MTKViewDelegate

    extension AEView: MTKViewDelegate {
        public func mtkView(_: MTKView, drawableSizeWillChange size: CGSize) {
            do {
                self.engineWindow.frame.size = size.toEngineSize
                try RenderEngine.shared.resizeWindow(self.engineWindow.id, newSize: size.toEngineSize.toSizeInt())
            } catch {
                logger.error("[AEView Error]: \(error.localizedDescription)")
            }
        }

        public func draw(in _: MTKView) {
        }
    }

    private struct _EmbeddableApp: AdaApp.App {
        let window: AdaEngine.UIWindow

        var body: some AppScene {
            EmptyWindow()
                .addPlugins(
                    DefaultPlugins()
                        .set(WindowPlugin(primaryWindow: window))
                )
        }
    }

    extension Application {
        var appleWindowManager: AppleWindowManager {
            self.windowManager as! AppleWindowManager
        }
    }
#endif
