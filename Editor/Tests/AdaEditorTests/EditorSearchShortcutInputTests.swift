@_spi(Internal) import AdaApp
@_spi(AdaEngine) import AdaEngine
@_spi(Internal) @testable import AdaInput
@_spi(Internal) @testable import AdaUI
import Foundation
import Testing

@testable import AdaEditor

@MainActor
@Suite("Double Shift input routing", .serialized)
struct EditorSearchShortcutInputTests {
    @Test("A held or repeated Shift is not a second press")
    func ignoresHeldShift() {
        var detector = EditorDoubleShiftDetector()
        let window = RID()
        #expect(detector.register(key(window, .shift, .down, 1, modifiers: .shift)) == false)
        #expect(detector.register(key(window, .shift, .down, 1.1, modifiers: .shift, repeated: true)) == false)
        #expect(detector.register(key(window, .shift, .down, 1.2, modifiers: .shift)) == false)
        #expect(detector.register(key(window, .shift, .up, 1.25)) == false)
        #expect(detector.register(key(window, .shift, .down, 1.3, modifiers: .shift)) == true)
    }

    @Test("Other modifiers and intervening letters cancel the shortcut", arguments: [KeyModifier.control, .alt, .main])
    func ignoresModifierChords(modifiers: KeyModifier) {
        var detector = EditorDoubleShiftDetector()
        let window = RID()
        #expect(detector.register(key(window, .shift, .down, 1, modifiers: .shift)) == false)
        #expect(detector.register(key(window, .a, .down, 1.05, modifiers: .shift)) == false)
        #expect(detector.register(key(window, .shift, .up, 1.1)) == false)
        #expect(detector.register(key(window, .shift, .down, 1.2, modifiers: .shift)) == false)
        #expect(detector.register(key(window, .shift, .up, 1.25)) == false)
        #expect(detector.register(key(window, .shift, .down, 1.3, modifiers: modifiers.union(.shift))) == false)
        #expect(detector.register(key(window, .shift, .up, 1.35)) == false)
        #expect(detector.register(key(window, .shift, .down, 1.4, modifiers: .shift)) == false)
    }

    @Test("Native-style input focuses search while the code editor owns keyboard focus")
    func inputSystemFocusesSearch() async throws {
        let fixture = try await Fixture()
        defer { fixture.stop() }
        await fixture.send([key(fixture.window.id, .shift, .down, 1, modifiers: [.shift, .capsLock]), key(fixture.window.id, .shift, .up, 1.05, modifiers: .capsLock)])
        #expect(!fixture.searchIsFocused)
        await fixture.send([key(fixture.window.id, .shift, .down, 1.2, modifiers: [.shift, .capsLock]), key(fixture.window.id, .shift, .up, 1.25, modifiers: .capsLock)])
        #expect(fixture.searchIsFocused)
        fixture.window.sendEvent(TextInputEvent(window: fixture.window.id, text: "Player", action: .insert, time: 1.3))
        #expect(fixture.model.query == "Player")
        #expect(fixture.model.source == "let player = 1")
    }

    @Test("Clicks and window deactivation prevent presses from forming an accidental pair")
    func cancelsAcrossClickAndDeactivation() async throws {
        let fixture = try await Fixture()
        defer { fixture.stop() }
        await fixture.send([key(fixture.window.id, .shift, .down, 1, modifiers: .shift), key(fixture.window.id, .shift, .up, 1.05)])
        await fixture.send([MouseEvent(window: fixture.window.id, button: .left, mousePosition: Point(20, 80), phase: .began, modifierKeys: [], time: 1.1)])
        await fixture.send([key(fixture.window.id, .shift, .down, 1.2, modifiers: .shift), key(fixture.window.id, .shift, .up, 1.25)])
        #expect(!fixture.searchIsFocused)
        fixture.manager.resignActiveWindow(fixture.window)
        await fixture.send([])
        fixture.manager.setActiveWindow(fixture.window)
        await fixture.send([key(fixture.window.id, .shift, .down, 1.3, modifiers: .shift), key(fixture.window.id, .shift, .up, 1.35)])
        #expect(!fixture.searchIsFocused)
        let otherWindow = UIWindow(frame: fixture.window.frame, configuration: .init(frame: fixture.window.frame), windowManager: fixture.manager)
        fixture.manager.setActiveWindow(otherWindow)
        await fixture.send([key(fixture.window.id, .shift, .down, 1.4, modifiers: .shift), key(fixture.window.id, .shift, .up, 1.45)])
        #expect(!fixture.searchIsFocused)
        fixture.manager.setActiveWindow(fixture.window)
        await fixture.send([key(fixture.window.id, .shift, .down, 1.5, modifiers: .shift), key(fixture.window.id, .shift, .up, 1.55)])
        #expect(!fixture.searchIsFocused)
        await fixture.send([key(fixture.window.id, .shift, .down, 1.7, modifiers: .shift), key(fixture.window.id, .shift, .up, 1.75)])
        #expect(fixture.searchIsFocused)
    }

    private func key(_ window: RID, _ code: KeyCode, _ status: KeyEvent.Status, _ time: Float, modifiers: KeyModifier = [], repeated: Bool = false) -> KeyEvent {
        KeyEvent(window: window, keyCode: code, modifiers: modifiers, status: status, time: time, isRepeated: repeated)
    }

    @MainActor
    private final class Model {
        var query = ""
        var source = "let player = 1"
    }

    @MainActor
    private final class Fixture {
        let manager = ShortcutTestWindowManager()
        let world = World(name: "ShortcutInput")
        let app: AppWorlds
        let model = Model()
        let window: UIWindow
        let container: UIContainerView<AnyView>

        var searchIsFocused: Bool {
            let search = try? container.uiNode(matching: .accessibilityIdentifier(EditorTopToolbar.searchAccessibilityIdentifier))
            return search?.firstFocusableDescendant?.isFocused == true
        }

        init() async throws {
            if unsafe RenderEngine.shared == nil {
                unsafe RenderEngine.configurations.preferredBackend = .headless
                RenderWorldPlugin().setup(in: AppWorlds(main: World(name: "ShortcutRendering")))
            }
            let model = model
            container = UIContainerView(rootView: AnyView(VStack {
                TextField("Search Project Files", text: Binding(get: { model.query }, set: { model.query = $0 }))
                    .accessibilityIdentifier(EditorTopToolbar.searchAccessibilityIdentifier)
                TextEditor(text: Binding(get: { model.source }, set: { model.source = $0 }))
                    .frame(width: 400, height: 160)
                    .accessibilityIdentifier("ShortcutTest.Editor")
            }))
            container.frame = Rect(x: 0, y: 0, width: 400, height: 240)
            container.bounds.size = container.frame.size
            window = UIWindow(frame: container.frame, configuration: .init(frame: container.frame), windowManager: manager)
            window.addSubview(container)
            manager.setActiveWindow(window)
            container.layoutIfNeeded()
            let editor = try container.uiNode(matching: .accessibilityIdentifier("ShortcutTest.Editor"))
            let focus = try #require(editor.firstFocusableDescendant)
            _ = try container.uiFocusNode(matching: .runtimeID(focus.runtimeId))
            world.insertResource(Input(gameControllerEngine: nil))
            world.insertResource(DeltaTime(deltaTime: 1.0 / 60))
            world.insertResource(WindowManagerResource(windowManager: manager))
            world.insertResource(UIWindowPendingDrawViews())
            world.insertResource(UIContextPendingDraw())
            world.insertResource(UIRedrawRequest())
            world.insertResource(WindowFrameRequests())
            world.addSystem(InputEventParseSystem.self, on: .preUpdate)
            world.addSystem(UpdateWindowManagerSystem.self, on: .preUpdate)
            // Match the old early registration, then recreate schedulers as app startup does.
            world.addSystem(EditorSearchShortcutInputSystem.self, on: .preUpdate)
            app = AppWorlds(main: world)
            app.addPlugin(ShortcutTestBootstrapPlugin())
            app.addPlugin(EditorSearchShortcutPlugin())
            try await app.build()
            EditorSearchShortcutMonitor.shared.start()
        }

        func send(_ events: [any InputEvent]) async {
            let input = world.getRefResource(Input.self)
            input.wrappedValue.removeEvents()
            for event in events { input.wrappedValue.receiveEvent(event) }
            await world.runScheduler(.preUpdate)
            container.layoutIfNeeded()
        }

        func stop() { EditorSearchShortcutMonitor.shared.stop() }
    }
}

private struct ShortcutTestBootstrapPlugin: Plugin {
    func setup(in app: AppWorlds) {
        app.main.addScheduler(Scheduler(name: .preUpdate))
        app.addSystem(InputEventParseSystem.self, on: .preUpdate)
        app.addSystem(UpdateWindowManagerSystem.self, on: .preUpdate)
    }
}

@MainActor
private final class ShortcutTestWindowManager: UIWindowManager {
    override func resizeWindow(_: UIWindow, size _: Size) {}
    override func getScreen(for _: UIWindow) -> Screen? { nil }
    override func setCursorShape(_: Input.CursorShape) {}
}
