#if os(macOS) && canImport(SAGAMetal)
    import AdaCorePipelines
    @_spi(AdaEngine) import AdaEngine
    @_spi(Internal) @testable import AdaRender
    @testable import AdaUI
    import Foundation
    import Math
    import Testing

    @testable import AdaEditor

    /// Draws the mounted AdaUI tree through the production tessellator and SAGA draw pass.
    @MainActor
    struct EditorUISnapshotRenderer {
        private let device: any RenderDevice
        private let world = World(name: "Studio UI snapshots")

        init() throws {
            // The snapshot suite runs in its own process. Pin localization without writing preferences to disk.
            let defaults = UserDefaults.standard
            var arguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
            arguments[EditorLocalization.preferenceKey] = EditorLanguage.english.rawValue
            defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
            unsafe RenderEngine.configurations.preferredBackend = .saga
            try RenderEngine.setupRenderEngine()
            try #require(unsafe RenderEngine.shared.type == .saga, "Run only the snapshot suite in its own Swift test invocation.")
            device = unsafe RenderEngine.shared.renderDevice
            RenderViewTarget.registerComponent()
            world.insertResource(RenderDeviceHandler(renderDevice: device))
            world.insertResource(RenderPipelines(configurator: TextPipeline()))
            world.insertResource(RenderPipelines(configurator: QuadPipeline()))
            world.insertResource(RenderPipelines(configurator: CirclePipeline()))
            world.insertResource(RenderPipelines(configurator: LinePipeline()))
            world.insertResource(RenderPipelines(configurator: LinearGradientPipeline()))
            world.insertResource(RenderPipelines(configurator: GlassPipeline()))
            world.insertResource(UIRenderPipelines(from: world))
            world.insertResource(RenderItems<UITransparentRenderItem>())
            world.insertResource(UIDrawPass())
            world.insertResource(UILayerDrawCache())
            world.setSchedulers([.update])
            world.addSystem(UIRenderTesselationSystem.self)
        }

        func render<Content: View>(_ container: UIContainerView<Content>) async throws -> Image {
            let width = container.frame.width
            let height = container.frame.height
            let target = RenderTexture(size: [Int(width), Int(height)], scaleFactor: 1, format: .bgra8)
            var viewTarget = RenderViewTarget()
            viewTarget.mainTexture = target
            let view = world.spawn { viewTarget }
            defer { world.removeEntity(view) }

            let context = UIGraphicsContext()
            container.draw(in: container.bounds, with: context)
            context.commitDraw()
            var pending = PendingUIGraphicsContext()
            pending.graphicContexts.append(context)
            world.insertResource(pending)
            world.insertResource(UIRenderBuildState())
            await world.runScheduler(.update)
            let items = try #require(world.getResource(RenderItems<UITransparentRenderItem>.self)).items
            try #require(!items.isEmpty, "The transcript produced no draw items.")

            let command = device.createCommandQueue().makeCommandBuffer()
            let pass = command.beginRenderPass(.init(colorAttachments: [
                .init(texture: target, operation: .init(loadAction: .clear, storeAction: .store), clearColor: Theme.adaEditor.editorColors.background)
            ]))
            pass.setViewport(Rect(x: 0, y: 0, width: width, height: height))
            let projection = Transform3D.createUIProjection(width: width, height: height)
            pass.setVertexBuffer(GlobalViewUniform(projectionMatrix: projection, viewProjectionMatrix: projection), slot: GlobalBufferIndex.viewUniform)
            for item in items {
                try UIDrawPass().render(with: pass, world: world, view: view, item: item)
            }
            pass.endRenderPass()
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                command.addCompletedHandler { continuation.resume() }
                command.commit()
            }
            return try #require(try await device.readImage(from: target))
        }
    }

    enum EditorUISnapshot {
        static let enabled = ProcessInfo.processInfo.environment["ADAEDITOR_CHAT_SNAPSHOTS"] == "1"
        private static let recording = ProcessInfo.processInfo.environment["ADAEDITOR_CHAT_SNAPSHOTS_RECORD"] == "1"
        private static let references = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/AgentChatSnapshots/saga-metal", isDirectory: true)
        private static let output = ProcessInfo.processInfo.environment["ADAEDITOR_CHAT_SNAPSHOTS_OUTPUT"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("AdaEditorChatSnapshots", isDirectory: true)

        static func check(_ actual: Image, named name: String) throws {
            // A solid-color readback must never become a reference.
            try #require(Set(actual.data.enumerated().filter { $0.offset.isMultiple(of: 4) }.map(\.element)).count > 8)
            let reference = references.appendingPathComponent("\(name).png")
            if recording {
                try FileManager.default.createDirectory(at: references, withIntermediateDirectories: true)
                try actual.writePNG(to: reference)
                return
            }

            let actualURL = output.appendingPathComponent("\(name)-actual.png")
            guard FileManager.default.fileExists(atPath: reference.path) else {
                try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                try actual.writePNG(to: actualURL)
                Issue.record("Missing reference \(reference.path). Captured \(actualURL.path).")
                return
            }

            let expected = try Image(contentsOf: reference)
            guard actual.width == expected.width, actual.height == expected.height else {
                try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                try actual.writePNG(to: actualURL)
                Issue.record("\(name): expected \(expected.width)×\(expected.height), got \(actual.width)×\(actual.height). Captured \(actualURL.path).")
                return
            }

            var changed: [(x: Int, y: Int)] = []
            for y in 0..<actual.height {
                for x in 0..<actual.width {
                    let a = actual.getPixel(x: x, y: y)
                    let b = expected.getPixel(x: x, y: y)
                    let largest = max(abs(a.red - b.red), abs(a.green - b.green), abs(a.blue - b.blue))
                    if largest > 3.01 / 255 { changed.append((x, y)) }
                }
            }
            // Allow isolated driver rounding without masking a short label or a small chat icon.
            guard Double(changed.count) > Double(actual.width * actual.height) * 0.0001 else {
                return
            }
            var difference = Image(width: actual.width, height: actual.height, color: .black)
            for pixel in changed {
                difference.setPixel(in: [Float(pixel.x), Float(pixel.y)], color: .red)
            }
            let differenceURL = output.appendingPathComponent("\(name)-difference.png")
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            try actual.writePNG(to: actualURL)
            try difference.writePNG(to: differenceURL)
            Issue.record("\(name): \(changed.count) pixels changed. Actual: \(actualURL.path). Diff: \(differenceURL.path).")
        }
    }
#endif
