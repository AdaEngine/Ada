//
//  KeyboardShortcutTests.swift
//  AdaEngine
//

import Testing
@testable import AdaUI
@testable import AdaPlatform
import AdaInput
import Math

@MainActor
struct KeyboardShortcutTests {
    init() async throws {
        try Application.prepareForTest()
    }

    @Test
    func keyboardShortcutWithModifiersInvokesButtonAction() {
        var count = 0
        let tester = ViewTester {
            Button(action: {
                count += 1
            }) {
                HStack(alignment: .center, spacing: 0) {}
                    .frame(width: 90, height: 24)
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])
        }
        .setSize(Size(width: 320, height: 200))
        .performLayout()

        tester.sendKeyEvent(.p, modifiers: [.main, .shift], time: 0)
        #expect(count == 1)

        tester.sendKeyEvent(.p, modifiers: [.main], time: 0.01)
        #expect(count == 1)
    }

    @Test
    func keyboardShortcutArrowInvokesExplicitAction() {
        var count = 0
        let tester = ViewTester {
            Spacer()
                .frame(width: 100, height: 100)
                .keyboardShortcut(KeyCode.arrowLeft) {
                    count += 1
                }
        }
        .setSize(Size(width: 200, height: 200))
        .performLayout()

        tester.sendKeyEvent(KeyCode.arrowLeft, time: 0)
        #expect(count == 1)
    }

    @Test
    func keyboardShortcutEscapeInvokesExplicitAction() {
        var count = 0
        let tester = ViewTester {
            Spacer()
                .frame(width: 100, height: 100)
                .keyboardShortcut(KeyCode.escape) {
                    count += 1
                }
        }
        .setSize(Size(width: 200, height: 200))
        .performLayout()

        tester.sendKeyEvent(KeyCode.escape, time: 0)
        #expect(count == 1)
    }

    @Test
    func keyboardShortcutDoesNotDuplicateAfterContentInvalidation() {
        var count = 0
        let tester = ViewTester {
            Spacer()
                .frame(width: 100, height: 100)
                .keyboardShortcut(KeyCode.arrowRight) {
                    count += 1
                }
        }
        .setSize(Size(width: 200, height: 200))
        .performLayout()

        tester.invalidateContent().performLayout()
        tester.invalidateContent().performLayout()
        tester.sendKeyEvent(KeyCode.arrowRight, time: 0)

        #expect(count == 1)
    }

    @Test
    func keyboardShortcutsInvokesExplicitActionsFromSingleModifier() {
        var saveCount = 0
        var zoomCount = 0
        let tester = ViewTester {
            Spacer()
                .frame(width: 100, height: 100)
                .keyboardShortcuts([
                    KeyboardShortcutAction(.s, modifiers: .command) {
                        saveCount += 1
                    },
                    KeyboardShortcutAction(.plus, modifiers: .command) {
                        zoomCount += 1
                    }
                ])
        }
        .setSize(Size(width: 200, height: 200))
        .performLayout()

        tester.sendKeyEvent(.s, modifiers: .main, time: 0)
        tester.sendKeyEvent(.plus, modifiers: .main, time: 0.01)
        tester.sendKeyEvent(.plus, modifiers: .control, time: 0.02)

        #expect(saveCount == 1)
        #expect(zoomCount == 1)
    }
}
