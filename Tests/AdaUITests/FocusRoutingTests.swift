//
//  FocusRoutingTests.swift
//  AdaEngine
//
//  Created by Codex on 24.03.2026.
//

import Testing
@testable import AdaUI
@testable import AdaPlatform
import AdaInput
import Math

@MainActor
struct FocusRoutingTests {
    init() async throws {
        try Application.prepareForTest()
    }

    @Test
    func tabKeyMovesFocusBetweenTextFields() {
        final class Model {
            var first: String = ""
            var second: String = ""
        }

        let model = Model()

        let tester = ViewTester {
            VStack(alignment: .leading, spacing: 8) {
                TextField(
                    "First",
                    text: Binding(get: { model.first }, set: { model.first = $0 })
                )
                .frame(width: 200, height: 36)
                .accessibilityIdentifier("field-1")

                TextField(
                    "Second",
                    text: Binding(get: { model.second }, set: { model.second = $0 })
                )
                .frame(width: 200, height: 36)
                .accessibilityIdentifier("field-2")
            }
        }
        .setSize(Size(width: 300, height: 120))
        .performLayout()

        let fieldPoint = Point(100, 20)
        tester.sendMouseEvent(at: fieldPoint, phase: .began, time: 0)
        tester.sendMouseEvent(at: fieldPoint, phase: .ended, time: 0.01)

        tester.sendTextInput("A", time: 0.02)
        #expect(model.first == "A")
        #expect(model.second == "")

        tester.sendKeyEvent(.tab, time: 0.03)

        tester.sendTextInput("B", time: 0.04)
        #expect(model.second == "B")
    }

    @Test
    func shiftTabMovesFocusBackward() {
        final class Model {
            var first: String = ""
            var second: String = ""
        }

        let model = Model()

        let tester = ViewTester {
            VStack(alignment: .leading, spacing: 8) {
                TextField(
                    "First",
                    text: Binding(get: { model.first }, set: { model.first = $0 })
                )
                .frame(width: 200, height: 36)

                TextField(
                    "Second",
                    text: Binding(get: { model.second }, set: { model.second = $0 })
                )
                .frame(width: 200, height: 36)
            }
        }
        .setSize(Size(width: 300, height: 120))
        .performLayout()

        let fieldPoint = Point(100, 20)
        tester.sendMouseEvent(at: fieldPoint, phase: .began, time: 0)
        tester.sendMouseEvent(at: fieldPoint, phase: .ended, time: 0.01)

        tester.sendKeyEvent(.tab, time: 0.02)
        tester.sendTextInput("B", time: 0.03)
        #expect(model.second == "B")

        tester.sendKeyEvent(.tab, modifiers: [.shift], time: 0.04)
        tester.sendTextInput("A", time: 0.05)
        #expect(model.first == "A")
    }

    @Test
    func tabWrapsAroundToFirstField() {
        final class Model {
            var first: String = ""
            var second: String = ""
        }

        let model = Model()

        let tester = ViewTester {
            VStack(alignment: .leading, spacing: 8) {
                TextField(
                    "First",
                    text: Binding(get: { model.first }, set: { model.first = $0 })
                )
                .frame(width: 200, height: 36)

                TextField(
                    "Second",
                    text: Binding(get: { model.second }, set: { model.second = $0 })
                )
                .frame(width: 200, height: 36)
            }
        }
        .setSize(Size(width: 300, height: 120))
        .performLayout()

        let fieldPoint = Point(100, 20)
        tester.sendMouseEvent(at: fieldPoint, phase: .began, time: 0)
        tester.sendMouseEvent(at: fieldPoint, phase: .ended, time: 0.01)

        tester.sendKeyEvent(.tab, time: 0.02)
        tester.sendKeyEvent(.tab, time: 0.03)

        tester.sendTextInput("Wrap", time: 0.04)
        #expect(model.first == "Wrap")
    }
}
