@_spi(AdaEngine) import AdaEngine
import AdaInput
@_spi(Internal) import AdaUI
import Math
import Testing

@testable import AdaEditor

@Suite("Editor preview viewport")
@MainActor
struct EditorPreviewViewportTests {
    init() throws {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            let app = AppWorlds(main: World(name: "EditorPreviewViewportTests"))
            RenderWorldPlugin().setup(in: app)
        }
    }

    @Test("preview surface is static until interaction is enabled")
    func previewSurfaceGatesInputByInteractionState() throws {
        let preview = PreviewSpyView()
        let host = try Self.makeHost(preview: preview, zoom: 1, isInteractive: false)
        let mouseEvent = MouseEvent(
            window: RID(),
            button: .left,
            mousePosition: Point(100, 50),
            phase: .began,
            modifierKeys: [],
            time: 0
        )

        host.onMouseEvent(mouseEvent)
        #expect(preview.mouseEvents.isEmpty)

        host.configure(previewView: preview, zoom: 1, isInteractive: true)
        host.onMouseEvent(mouseEvent)
        #expect(preview.mouseEvents.count == 1)
    }

    @Test("zoomed preview maps viewport input through inverse centered scale")
    func zoomedPreviewMapsInputToContentCoordinates() throws {
        let preview = PreviewSpyView()
        let host = try Self.makeHost(preview: preview, zoom: 2, isInteractive: true)
        host.frame = Rect(x: 0, y: 0, width: 200, height: 100)
        host.bounds.size = host.frame.size
        host.layoutSubviews()

        host.onMouseEvent(
            MouseEvent(
                window: RID(),
                button: .left,
                mousePosition: Point(150, 50),
                phase: .began,
                modifierKeys: [],
                time: 0
            )
        )

        let forwarded = try #require(preview.mouseEvents.first)
        #expect(forwarded.mousePosition == Point(125, 50))
    }

    @Test("keyboard and text input are gated by interactive state")
    func previewSurfaceGatesKeyboardAndTextInput() throws {
        let preview = PreviewSpyView()
        let host = try Self.makeHost(preview: preview, zoom: 1, isInteractive: false)
        let keyEvent = KeyEvent(
            window: RID(),
            keyCode: .a,
            modifiers: [],
            status: .down,
            time: 0,
            isRepeated: false
        )
        let textEvent = TextInputEvent(
            window: RID(),
            text: "a",
            action: .insert,
            time: 0
        )

        host.onKeyEvent(keyEvent)
        host.onTextInputEvent(textEvent)
        #expect(preview.keyEvents.isEmpty)
        #expect(preview.textEvents.isEmpty)

        host.configure(previewView: preview, zoom: 1, isInteractive: true)
        host.onKeyEvent(keyEvent)
        host.onTextInputEvent(textEvent)
        #expect(preview.keyEvents.count == 1)
        #expect(preview.textEvents.count == 1)

        host.configure(previewView: preview, zoom: 1, isInteractive: false)
        host.onKeyEvent(keyEvent)
        host.onTextInputEvent(textEvent)
        #expect(preview.keyEvents.count == 1)
        #expect(preview.textEvents.count == 1)
    }

    @Test("viewport controls fit inside the viewport and update host zoom")
    func viewportControlsAreCompactAndInteractive() async throws {
        let preview = PreviewSpyView()
        let container = UIContainerView(rootView: EditorPreviewViewport(previewView: preview))
        container.frame = Rect(x: 0, y: 0, width: 320, height: 240)
        container.bounds.size = container.frame.size
        container.layoutIfNeeded()

        let viewport = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.PreviewViewport"))
        let controls = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.PreviewViewport.Controls"))
        #expect(controls.absoluteFrame.width <= 220)
        #expect(controls.absoluteFrame.maxY <= viewport.absoluteFrame.maxY)
        #expect(controls.absoluteFrame.minY >= viewport.absoluteFrame.minY)

        let host = try #require(preview.parentView as? EditorPreviewHostView)
        #expect(host.zoom == 1)
        #expect(host.isInteractive == false)

        _ = try container.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.PreviewViewport.ZoomIn"))
        for _ in 0..<100 where host.zoom != 1.25 {
            await Task.yield()
            container.layoutIfNeeded()
        }
        #expect(host.zoom == 1.25)

        _ = try container.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.PreviewViewport.ZoomReset"))
        for _ in 0..<100 where host.zoom != 1 {
            await Task.yield()
            container.layoutIfNeeded()
        }
        #expect(host.zoom == 1)

        _ = try container.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.PreviewViewport.Interactive"))
        for _ in 0..<100 where !host.isInteractive {
            await Task.yield()
            container.layoutIfNeeded()
        }
        #expect(host.isInteractive)
    }

    @Test("interactive preview forwards clicks to the actual preview UI")
    func interactivePreviewForwardsButtonClicksAtDifferentZooms() throws {
        final class Counter {
            var value = 0
        }

        let counter = Counter()
        let preview = UIContainerView(
            rootView: Button(action: { counter.value += 1 }) {
                Text("Preview Action")
                    .frame(width: 140, height: 36)
            }
            .accessibilityIdentifier("Preview.Action")
        )
        let host = try Self.makeHost(preview: preview, zoom: 1, isInteractive: false)
        let button = try preview.uiNode(matching: .accessibilityIdentifier("Preview.Action"))
        let buttonCenter = Point(button.absoluteFrame.midX, button.absoluteFrame.midY)

        Self.sendClick(to: host, at: buttonCenter)
        #expect(counter.value == 0)

        host.configure(previewView: preview, zoom: 1, isInteractive: true)
        host.layoutSubviews()
        Self.sendClick(to: host, at: buttonCenter)
        #expect(counter.value == 1)

        host.configure(previewView: preview, zoom: 2, isInteractive: true)
        host.layoutSubviews()
        let viewportCenter = Point(host.bounds.midX, host.bounds.midY)
        let zoomedButtonCenter = Point(
            viewportCenter.x + (buttonCenter.x - viewportCenter.x) * 2,
            viewportCenter.y + (buttonCenter.y - viewportCenter.y) * 2
        )
        Self.sendClick(to: host, at: zoomedButtonCenter)
        #expect(counter.value == 2)
    }

    private static func makeHost(
        preview: UIView,
        zoom: Float,
        isInteractive: Bool
    ) throws -> EditorPreviewHostView {
        let container = UIContainerView(
            rootView: EditorPreviewSurface(
                previewView: preview,
                zoom: zoom,
                isInteractive: isInteractive
            )
        )
        container.frame = Rect(x: 0, y: 0, width: 200, height: 100)
        container.bounds.size = container.frame.size
        container.layoutIfNeeded()
        return try #require(preview.parentView as? EditorPreviewHostView)
    }

    private static func sendClick(to host: EditorPreviewHostView, at point: Point) {
        let window = RID()
        host.onMouseEvent(
            MouseEvent(
                window: window,
                button: .left,
                mousePosition: point,
                phase: .began,
                modifierKeys: [],
                time: 0
            )
        )
        host.onMouseEvent(
            MouseEvent(
                window: window,
                button: .left,
                mousePosition: point,
                phase: .ended,
                modifierKeys: [],
                time: 0.01
            )
        )
    }
}

@MainActor
private final class PreviewSpyView: UIView {
    var mouseEvents: [MouseEvent] = []
    var keyEvents: [KeyEvent] = []
    var textEvents: [TextInputEvent] = []

    override func onMouseEvent(_ event: MouseEvent) {
        mouseEvents.append(event)
    }

    override func onKeyEvent(_ event: KeyEvent) {
        keyEvents.append(event)
    }

    override func onTextInputEvent(_ event: TextInputEvent) {
        textEvents.append(event)
    }
}
