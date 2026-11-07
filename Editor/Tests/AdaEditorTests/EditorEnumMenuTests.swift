@_spi(AdaEngine) import AdaEngine
import AdaInput
@_spi(Internal) import AdaUI
import Math
import Testing

@testable import AdaEditor

@MainActor @Suite(.serialized)
struct EditorEnumMenuTests {
    init() {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            RenderWorldPlugin().setup(in: AppWorlds(main: World(name: "EnumMenuTests")))
        }
    }

    @Test func menuOpensFromKeyboardAndUsesCurrentOptionsWithoutResizingField() throws {
        var selected = "one"
        var menu: ContextMenuPresentation?
        let previousPresenter = ContextMenuPresentationCenter.present
        ContextMenuPresentationCenter.present = { menu = $0 }
        defer { ContextMenuPresentationCenter.present = previousPresenter }
        let container = UIContainerView(
            rootView: EditorEnumField(
                cases: ["one", "two"],
                selection: Binding(get: { selected }, set: { selected = $0 })
            )
        )
        container.frame = Rect(x: 0, y: 0, width: 220, height: 100)
        container.layoutSubviews()
        let selector = UINodeSelector.accessibilityIdentifier("AdaEditor.Enum.Toggle")
        let before = try container.uiNode(matching: selector).absoluteFrame
        _ = try container.uiFocusNode(matching: selector)
        for key in [KeyCode.enter, .space] {
            menu = nil
            container.onKeyEvent(KeyEvent(window: RID(), keyCode: key, modifiers: [], status: .down, time: 0, isRepeated: false))
            #expect(menu?.items.count == 2)
            #expect(menu?.items.filter(\.isSelected).map(\.title) == [selected])
            #expect(try container.uiNode(matching: selector).absoluteFrame == before)
            let target = selected == "one" ? "two" : "one"
            let action = try #require(menu?.items.first { $0.title == target }?.action)
            action()
        }
        #expect(selected == "one")
    }

    @Test func fieldShowsHoverPressAndKeyboardFocusWithoutChangingItsValue() throws {
        let previousPresenter = ContextMenuPresentationCenter.present
        ContextMenuPresentationCenter.present = { _ in }
        defer { ContextMenuPresentationCenter.present = previousPresenter }
        let container = UIContainerView(rootView: EditorEnumField(cases: ["one", "two"], selection: .constant("one")).theme(.adaEditor))
        container.frame = Rect(x: 0, y: 0, width: 220, height: 100)
        container.layoutSubviews()
        let selector = UINodeSelector.accessibilityIdentifier("AdaEditor.Enum.Toggle")
        let frame = try container.uiNode(matching: selector).absoluteFrame
        let point = Point(frame.midX, frame.midY)
        let hover = Theme.adaEditor.editorColors.text.opacity(0.10)
        let pressed = Theme.adaEditor.editorColors.text.opacity(0.16)
        let focused = Theme.adaEditor.editorColors.blue.opacity(0.12)
        #expect(fillCount(container, color: hover) == 0)
        container.onMouseEvent(MouseEvent(window: .empty, button: .none, mousePosition: point, phase: .changed, modifierKeys: [], time: 0))
        container.update(1 / 60); container.layoutIfNeeded()
        #expect(fillCount(container, color: hover) > 0)
        container.onMouseEvent(MouseEvent(window: .empty, button: .left, mousePosition: point, phase: .began, modifierKeys: [], time: 0))
        container.update(1 / 60); container.layoutIfNeeded()
        #expect(fillCount(container, color: pressed) > 0)
        container.onMouseEvent(MouseEvent(window: .empty, button: .left, mousePosition: point, phase: .cancelled, modifierKeys: [], time: 0))
        container.onMouseEvent(MouseEvent(window: .empty, button: .none, mousePosition: Point(219, 99), phase: .changed, modifierKeys: [], time: 0))
        _ = try container.uiFocusNode(matching: selector)
        container.update(1 / 60); container.layoutIfNeeded()
        #expect(fillCount(container, color: focused) > 0)
        #expect(try container.uiNode(matching: selector).absoluteFrame == frame)
    }

    @Test func keyboardActivationAcceptsCapsLockWithoutRepeatingOrHandlingCommandKeys() throws {
        var count = 0
        let previousPresenter = ContextMenuPresentationCenter.present
        ContextMenuPresentationCenter.present = { _ in count += 1 }
        defer { ContextMenuPresentationCenter.present = previousPresenter }
        let field = EditorEnumField(cases: ["one", "two"], selection: .constant("one"))
        let container = UIContainerView(rootView: field)
        container.frame = Rect(x: 0, y: 0, width: 220, height: 100)
        container.layoutSubviews()
        _ = try container.uiFocusNode(matching: .accessibilityIdentifier("AdaEditor.Enum.Toggle"))
        container.onKeyEvent(KeyEvent(window: .empty, keyCode: .enter, modifiers: [.capsLock], status: .down, time: 0, isRepeated: false))
        #expect(count == 1)
        container.onKeyEvent(KeyEvent(window: .empty, keyCode: .enter, modifiers: [.capsLock], status: .down, time: 0, isRepeated: true))
        #expect(count == 1)
        container.onKeyEvent(KeyEvent(window: .empty, keyCode: .enter, modifiers: [.capsLock], status: .up, time: 0, isRepeated: false))
        #expect(count == 1)
        container.onKeyEvent(KeyEvent(window: .empty, keyCode: .space, modifiers: [], status: .down, time: 0, isRepeated: false))
        #expect(count == 2)
        container.onKeyEvent(KeyEvent(window: .empty, keyCode: .space, modifiers: [.main], status: .down, time: 0, isRepeated: false))
        #expect(count == 2)
        let disabled = UIContainerView(rootView: field.disabled(true))
        disabled.frame = container.frame
        disabled.layoutSubviews()
        disabled.onKeyEvent(KeyEvent(window: .empty, keyCode: .space, modifiers: [], status: .down, time: 0, isRepeated: false))
        #expect(count == 2)
    }

    private func fillCount<Content: View>(_ container: UIContainerView<Content>, color target: Color) -> Int {
        let context = UIGraphicsContext()
        container.draw(in: container.bounds, with: context)
        return context.getDrawCommands().filter { command in
            switch command {
            case let .drawPath(_, _, .fill(color)), let .drawQuad(_, _, color): color == target
            default: false
            }
        }.count
    }

    @Test func primaryMenuCancelsDragAndIgnoresDisabledClicks() throws {
        var presentations = 0
        let previousPresenter = ContextMenuPresentationCenter.present
        ContextMenuPresentationCenter.present = { _ in presentations += 1 }
        defer { ContextMenuPresentationCenter.present = previousPresenter }
        let field = EditorEnumField(cases: ["one"], selection: .constant("one"))
        let container = UIContainerView(rootView: field)
        container.frame = Rect(x: 0, y: 0, width: 220, height: 100)
        container.layoutSubviews()
        let rect = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.Enum.Toggle")).absoluteFrame
        let point = Point(rect.midX, rect.midY)
        for (phase, position) in [(MouseEvent.Phase.began, point), (.changed, point + Point(20, 0)), (.ended, point)] {
            container.onMouseEvent(MouseEvent(window: RID(), button: .left, mousePosition: position, phase: phase, modifierKeys: [], time: 0))
        }
        #expect(presentations == 0)
        _ = try container.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.Enum.Toggle"))
        #expect(presentations == 1)
        let window = RID()
        container.onTouchesEvent([TouchEvent(window: window, location: point, phase: .began, time: 0)])
        #expect(presentations == 1)
        container.onTouchesEvent([TouchEvent(window: window, location: point, phase: .ended, time: 0.1)])
        #expect(presentations == 2)
        let disabled = UIContainerView(rootView: field.disabled(true))
        disabled.frame = container.frame
        disabled.layoutSubviews()
        _ = try disabled.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.Enum.Toggle"))
        #expect(presentations == 2)
    }
}
