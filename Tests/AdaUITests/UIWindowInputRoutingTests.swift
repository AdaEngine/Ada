//
//  UIWindowInputRoutingTests.swift
//  AdaEngine
//
//  Created by Codex on 19.02.2026.
//

import Testing
@testable import AdaUI
@testable import AdaPlatform
import AdaInput
import Math

@MainActor
struct UIWindowInputRoutingTests {
    init() async throws {
        try Application.prepareForTest()
    }

    @Test
    func window_routes_text_input_to_focused_text_field() {
        final class Model {
            var text: String = "a"
        }

        let model = Model()

        let container = UIContainerView(
            rootView: TextField(
                "Type",
                text: Binding(
                    get: { model.text },
                    set: { model.text = $0 }
                )
            )
            .frame(width: 240, height: 36)
        )
        container.frame = Rect(x: 0, y: 0, width: 260, height: 80)

        let window = UIWindow(frame: Rect(x: 0, y: 0, width: 260, height: 80))
        window.addSubview(container)
        window.layoutSubviews()

        let focusPoint = Point(130, 40)
        window.sendEvent(
            MouseEvent(
                window: window.id,
                button: .left,
                mousePosition: focusPoint,
                phase: .began,
                modifierKeys: [],
                time: 0
            )
        )
        window.sendEvent(
            MouseEvent(
                window: window.id,
                button: .left,
                mousePosition: focusPoint,
                phase: .ended,
                modifierKeys: [],
                time: 0.01
            )
        )

        window.sendEvent(
            TextInputEvent(
                window: window.id,
                text: "b",
                action: .insert,
                time: 0.02
            )
        )

        #expect(model.text == "ab")
    }

    @Test
    func window_routes_text_input_to_focused_container_when_overlay_is_topmost() {
        final class Model {
            var text: String = "a"
        }

        let model = Model()

        let editorContainer = UIContainerView(
            rootView: TextField(
                "Type",
                text: Binding(
                    get: { model.text },
                    set: { model.text = $0 }
                )
            )
            .frame(width: 240, height: 36)
        )
        editorContainer.frame = Rect(x: 0, y: 0, width: 260, height: 80)

        let window = UIWindow(frame: Rect(x: 0, y: 0, width: 260, height: 80))
        window.addSubview(editorContainer)
        window.layoutSubviews()

        let focusPoint = Point(130, 40)
        window.sendEvent(
            MouseEvent(
                window: window.id,
                button: .left,
                mousePosition: focusPoint,
                phase: .began,
                modifierKeys: [],
                time: 0
            )
        )
        window.sendEvent(
            MouseEvent(
                window: window.id,
                button: .left,
                mousePosition: focusPoint,
                phase: .ended,
                modifierKeys: [],
                time: 0.01
            )
        )

        let overlay = UIView(frame: Rect(x: 0, y: 0, width: 260, height: 80))
        overlay.backgroundColor = .clear
        window.addSubview(overlay)

        window.sendEvent(
            TextInputEvent(
                window: window.id,
                text: "b",
                action: .insert,
                time: 0.02
            )
        )

        #expect(model.text == "ab")
    }
}
