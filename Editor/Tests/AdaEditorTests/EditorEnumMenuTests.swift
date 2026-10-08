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
