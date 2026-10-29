import AdaInput
@testable import AdaPlatform
@_spi(Internal) import AdaRender
@_spi(Internal) @testable import AdaUI
import AdaUtils
import Math
import Testing

@MainActor
@Suite(.serialized)
struct OffscreenViewportLifecycleTests {
    init() throws {
        try Application.prepareForTest()
    }

    @Test func removingRepresentedContainerShutsDownItsNestedViewport() throws {
        var delegates: [LifecycleViewportDelegate] = []
        let embedded = UIContainerView(rootView: OffscreenViewportContainer(delegateFactory: {
            let delegate = LifecycleViewportDelegate()
            delegates.append(delegate)
            return delegate
        }) { delegate in
            OffscreenViewportView(delegate: delegate)
        })
        let representable = NestedViewportSurface(content: embedded)
        let viewport = UIViewRepresentableNode(representable: representable, content: representable)
        let parent = ViewContainerNode(content: EmptyView(), nodes: [])
        parent.reconcileChildNodes(from: [viewport])
        parent.place(in: .zero, anchor: .topLeading, proposal: .init(width: 400, height: 300))
        parent.update(0.016)
        let original = try #require(delegates.first)
        #expect(original.bootstrapCount == 1 && original.tickCount == 1)
        // Keep the UIView alive, as AdaptiveSceneView and retained UI overlays do.
        parent.reconcileChildNodes(from: [])
        #expect(original.shutdownCount == 1)
    }

    @Test func reattachedViewportUsesItsNewDelegateForLayoutUpdateAndDrawing() throws {
        var delegates: [LifecycleViewportDelegate] = []
        let content = OffscreenViewportContainer(delegateFactory: {
            let delegate = LifecycleViewportDelegate()
            delegates.append(delegate)
            return delegate
        }) { delegate in
            OffscreenViewportView(delegate: delegate)
        }
        let viewport = content.buildViewNode(in: .init(parentNode: nil, environment: EnvironmentValues()))
        let parent = ViewContainerNode(content: EmptyView(), nodes: [])
        parent.reconcileChildNodes(from: [viewport])
        parent.place(in: .zero, anchor: .topLeading, proposal: .init(width: 400, height: 300))
        parent.update(0.016)
        let original = try #require(delegates.first)
        #expect(original.bootstrapCount == 1 && original.tickCount == 1)
        #expect(original.lastSize == SizeInt(width: 400, height: 300))

        parent.reconcileChildNodes(from: [])
        #expect(original.shutdownCount == 1)
        parent.reconcileChildNodes(from: [viewport])
        parent.place(in: .zero, anchor: .topLeading, proposal: .init(width: 480, height: 360))
        parent.update(0.016)

        #expect(delegates.count == 2)
        let replacement = try #require(delegates.last)
        #expect(replacement !== original)
        #expect(replacement.bootstrapCount == 1 && replacement.tickCount == 1)
        #expect(replacement.lastSize == SizeInt(width: 480, height: 360))
        #expect(original.shutdownCount == 1 && original.tickCount == 1)
        let oldTextureReads = original.textureReads
        let newTextureReads = replacement.textureReads
        let drawing = UIGraphicsContext()
        parent.draw(with: drawing)
        #expect(original.textureReads == oldTextureReads)
        #expect(replacement.textureReads > newTextureReads)
        #expect(drawing.getDrawCommands().contains { command in
            if case .drawQuad = command {
                return true
            }
            return false
        })
    }
}

private struct NestedViewportSurface: UIViewRepresentable {
    let content: UIView
    func makeUIView(in _: Context) -> UIView { content }
    func updateUIView(_: UIView, in _: Context) {}
}

@MainActor
private final class LifecycleViewportDelegate: OffscreenViewportDelegate {
    var renderTextureDidChange: (@MainActor @Sendable () -> Void)?
    var renderFrameDidChange: (@MainActor @Sendable () -> Void)?
    var bootstrapCount = 0
    var shutdownCount = 0
    var tickCount = 0
    var textureReads = 0
    var lastSize = SizeInt.zero

    var renderTexture: Texture2D? {
        textureReads += 1
        return shutdownCount == 0 && bootstrapCount > 0 ? .whiteTexture : nil
    }

    func bootstrapIfNeeded() { bootstrapCount += 1 }
    func shutdown() { shutdownCount += 1 }
    func tick(_: AdaUtils.TimeInterval) { tickCount += 1 }
    func updateSize(_ size: SizeInt, scaleFactor _: Float) { lastSize = size }
    func receiveInputEvent(_: any InputEvent) {}
    func updateMousePosition(_: Point) {}
}
