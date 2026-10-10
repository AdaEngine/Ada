#if os(macOS)
@_spi(AdaEngine) import AdaEngine
@testable import AdaPlatform
@_spi(Internal) import AdaUI
import AppKit
import Testing

@Suite("Editor window drag region")
@MainActor
struct EditorWindowDragTests {
    @Test("double click zooms and restores a real native window")
    func doubleClickTogglesZoom() throws {
        prepareRendererIfNeeded()
        let screens = MacOSScreenManager()
        let manager = MacOSWindowManager(screens)
        let window = UIWindow(
            frame: Rect(x: 0, y: 0, width: 800, height: 600),
            configuration: .init(titleBar: .overlay),
            windowManager: manager
        )
        defer { window.close() }
        let native = try #require(window.systemWindow as? NSWindow)
        let view = try #require(native.contentView?.subviews.first as? MetalView)
        let originalFrame = native.frame

        view.mouseDown(with: try doubleClick(in: native, point: NSPoint(x: 400, y: 580)))
        #expect(native.frame != originalFrame)
        #expect(native.isZoomed)
        view.mouseDown(with: try doubleClick(in: native, point: NSPoint(x: 400, y: view.bounds.height - 20)))
        #expect(native.frame == originalFrame)
    }

    @Test("interactive controls and scene content do not zoom the window")
    func doubleClickPreservesContentInput() throws {
        prepareRendererIfNeeded()
        let screens = MacOSScreenManager()
        let manager = MacOSWindowManager(screens)
        let window = UIWindow(
            frame: Rect(x: 0, y: 0, width: 800, height: 600),
            configuration: .init(titleBar: .overlay),
            windowManager: manager
        )
        defer { window.close() }
        let native = try #require(window.systemWindow as? NSWindow)
        let view = try #require(native.contentView?.subviews.first as? MetalView)
        let button = UIContainerView(rootView: Button("Control", action: {}).frame(width: 120, height: 36))
        button.frame = Rect(x: 0, y: 0, width: 120, height: 36)
        button.bounds.size = button.frame.size
        window.addSubview(button)
        button.layoutIfNeeded()
        let originalFrame = native.frame

        view.mouseDown(with: try doubleClick(in: native, point: NSPoint(x: 60, y: 580)))
        #expect(native.frame == originalFrame)
        view.mouseDown(with: try doubleClick(in: native, point: NSPoint(x: 400, y: 300)))
        #expect(native.frame == originalFrame)
    }

    private func doubleClick(in window: NSWindow, point: NSPoint) throws -> NSEvent {
        let event = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: point,
            modifierFlags: [],
            timestamp: 1,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 2,
            pressure: 1
        ))
        try #require(event.window === window)
        return event
    }

    private func prepareRendererIfNeeded() {
        _ = NSApplication.shared
        guard unsafe RenderEngine.shared == nil else {
            return
        }
        unsafe RenderEngine.configurations.preferredBackend = .headless
        RenderWorldPlugin().setup(in: AppWorlds(main: World(name: "EditorWindowDragTests")))
    }
}
#endif
