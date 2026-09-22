//
//  TextEditorTests.swift
//  AdaEngine
//
//  Created by Codex on 18.05.2026.
//

import AdaInput
import AdaText
import Math
import Testing
@testable import AdaPlatform
@_spi(Internal) @testable import AdaUI

@MainActor
struct TextEditorTests {
    init() async throws {
        try Application.prepareForTest()
    }

    @Test
    func textEditor_canHideSourceLineNumbersForPlainMultilineInput() throws {
        var text = "Prompt"
        let tester = ViewTester {
            TextEditor(
                text: Binding(get: { text }, set: { text = $0 }),
                showsLineNumbers: false
            )
            .frame(width: 360, height: 160)
        }
        .setSize(Size(width: 380, height: 180))
        .performLayout()

        let node = try #require(tester.sendMouseEvent(at: Point(20, 28), phase: .began) as? TextEditorViewNode)

        #expect(!node.showsLineNumbers)
        #expect(node.textRect().minX == node.textContentRect().minX)
    }

    @Test
    func textEditor_supportsMultilineEditingAndUndoRedo() {
        final class Model {
            var text = "alpha"
        }

        let model = Model()
        let tester = ViewTester {
            TextEditor(
                "Write code",
                text: Binding(
                    get: { model.text },
                    set: { model.text = $0 }
                )
            )
            .font(.system(size: 12))
            .frame(width: 360, height: 160)
        }
        .setSize(Size(width: 380, height: 180))
        .performLayout()

        tester.sendMouseEvent(at: Point(100, 28), phase: .began, time: 0)
        tester.sendMouseEvent(at: Point(100, 28), phase: .ended, time: 0.01)
        tester.sendKeyEvent(.a, modifiers: [.control], time: 0.02)
        tester.sendTextInput("one", time: 0.03)
        tester.sendKeyEvent(.enter, time: 0.04)
        tester.sendTextInput("two", time: 0.05)

        #expect(model.text == "one\ntwo")

        tester.sendKeyEvent(.z, modifiers: [.control], time: 0.06)
        #expect(model.text == "one\n")

        tester.sendKeyEvent(.y, modifiers: [.control], time: 0.07)
        #expect(model.text == "one\ntwo")
    }

    @Test
    func textEditor_newlinePreservesCurrentIndentation() {
        final class Model {
            var text = "placeholder"
        }

        let model = Model()
        let tester = ViewTester {
            TextEditor(
                text: Binding(
                    get: { model.text },
                    set: { model.text = $0 }
                )
            )
            .font(.system(size: 12))
            .frame(width: 360, height: 160)
        }
        .setSize(Size(width: 380, height: 180))
        .performLayout()

        tester.sendMouseEvent(at: Point(100, 28), phase: .began, time: 0)
        tester.sendMouseEvent(at: Point(100, 28), phase: .ended, time: 0.01)
        tester.sendKeyEvent(.a, modifiers: [.control], time: 0.02)
        tester.sendTextInput("\t    return value", time: 0.03)
        tester.sendKeyEvent(.enter, time: 0.04)
        tester.sendTextInput("next", time: 0.05)

        #expect(model.text == "\t    return value\n\t    next")

        tester.sendKeyEvent(.z, modifiers: [.control], time: 0.06)
        tester.sendKeyEvent(.z, modifiers: [.control], time: 0.07)
        #expect(model.text == "\t    return value")
    }

    @Test
    func textEditor_supportsCommandUndoAndRedo() {
        final class Model {
            var text = "original"
        }

        let model = Model()
        let tester = ViewTester {
            TextEditor(
                text: Binding(
                    get: { model.text },
                    set: { model.text = $0 }
                )
            )
            .font(.system(size: 12))
            .frame(width: 360, height: 160)
        }
        .setSize(Size(width: 380, height: 180))
        .performLayout()

        tester.sendMouseEvent(at: Point(100, 28), phase: .began, time: 0)
        tester.sendMouseEvent(at: Point(100, 28), phase: .ended, time: 0.01)
        tester.sendKeyEvent(.a, modifiers: [.main], time: 0.02)
        tester.sendTextInput("changed", time: 0.03)

        tester.sendKeyEvent(.z, modifiers: [.main], time: 0.04)
        #expect(model.text == "original")

        tester.sendKeyEvent(.z, modifiers: [.main, .shift], time: 0.05)
        #expect(model.text == "changed")
    }

    @Test
    func textEditor_movesCaretAcrossLines() {
        final class Model {
            var text = "abc\ndefg\nhi"
        }

        let model = Model()
        let tester = ViewTester {
            TextEditor(
                text: Binding(
                    get: { model.text },
                    set: { model.text = $0 }
                )
            )
            .font(.system(size: 12))
            .frame(width: 360, height: 160)
        }
        .setSize(Size(width: 380, height: 180))
        .performLayout()

        tester.sendMouseEvent(at: Point(100, 28), phase: .began, time: 0)
        tester.sendMouseEvent(at: Point(100, 28), phase: .ended, time: 0.01)
        tester.sendKeyEvent(.a, modifiers: [.control], time: 0.02)
        tester.sendTextInput(model.text, time: 0.03)
        tester.sendKeyEvent(.arrowUp, time: 0.04)
        tester.sendTextInput("X", time: 0.05)

        #expect(model.text == "abc\ndeXfg\nhi")
    }

    @Test
    func textEditor_routesCompletionKeysBeforeEditingCommands() {
        final class Model {
            var text = "value"
            var selectionMoves: [Int] = []
            var acceptedCompletionCount = 0
        }

        let model = Model()
        let tester = ViewTester {
            TextEditor(
                text: Binding(
                    get: { model.text },
                    set: { model.text = $0 }
                ),
                sourceInteraction: TextEditorSourceInteraction(
                    onMoveCompletionSelection: { delta in
                        model.selectionMoves.append(delta)
                        return true
                    },
                    onAcceptCompletion: {
                        model.acceptedCompletionCount += 1
                        return true
                    }
                )
            )
            .font(.system(size: 12))
            .frame(width: 360, height: 160)
        }
        .setSize(Size(width: 380, height: 180))
        .performLayout()

        tester.sendMouseEvent(at: Point(100, 28), phase: .began, time: 0)
        tester.sendMouseEvent(at: Point(100, 28), phase: .ended, time: 0.01)
        tester.sendKeyEvent(.arrowUp, time: 0.02)
        tester.sendKeyEvent(.arrowDown, time: 0.03)
        tester.sendKeyEvent(.enter, time: 0.04)

        #expect(model.selectionMoves == [-1, 1])
        #expect(model.acceptedCompletionCount == 1)
        #expect(model.text == "value")
    }

    @Test
    func textEditor_supportsCopyPasteAndTabInsertion() {
        final class Model {
            var text = "value"
        }

        let model = Model()
        let tester = ViewTester {
            TextEditor(
                text: Binding(
                    get: { model.text },
                    set: { model.text = $0 }
                )
            )
            .font(.system(size: 12))
            .frame(width: 360, height: 160)
        }
        .setSize(Size(width: 380, height: 180))
        .performLayout()

        tester.sendMouseEvent(at: Point(100, 28), phase: .began, time: 0)
        tester.sendMouseEvent(at: Point(100, 28), phase: .ended, time: 0.01)
        tester.sendKeyEvent(.a, modifiers: [.control], time: 0.02)
        tester.sendKeyEvent(.c, modifiers: [.control], time: 0.03)
        tester.sendKeyEvent(.pageDown, time: 0.04)
        tester.sendKeyEvent(.enter, time: 0.05)
        tester.sendKeyEvent(.tab, time: 0.06)
        tester.sendKeyEvent(.v, modifiers: [.control], time: 0.07)

        #expect(model.text == "value\n    value")
    }

    @Test
    func textEditor_visibleLineRangeHandlesBottomOverscroll() throws {
        final class Model {
            var text = "value"
        }

        let model = Model()
        let tester = ViewTester {
            TextEditor(
                text: Binding(
                    get: { model.text },
                    set: { model.text = $0 }
                )
            )
            .font(.system(size: 12))
            .frame(width: 240, height: 80)
        }
        .setSize(Size(width: 260, height: 100))
        .performLayout()

        let node = try #require(tester.sendMouseEvent(at: Point(40, 40), phase: .began, time: 0) as? TextEditorViewNode)
        tester.sendMouseEvent(at: Point(40, 40), phase: .ended, time: 0.01)
        tester.sendMouseEvent(
            at: Point(40, 40),
            button: .scrollWheel,
            phase: .changed,
            scrollDelta: Point(0, -100),
            time: 0.02
        )

        let lineHeight = node.lineHeight(for: node.resolvedFontPointSize())
        let range = node.visibleLineRange(lineHeight: lineHeight, viewportHeight: 80)

        #expect(node.nearestScrollView()?.contentOffset.y ?? 0 > lineHeight)
        #expect(range == node.lines().count..<node.lines().count)
    }

    @Test
    func textEditor_reportsCaretRectInScrolledViewportCoordinates() throws {
        final class Model {
            var text = (1...60).map { "line \($0)" }.joined(separator: "\n")
        }

        let model = Model()
        var reportedPosition: TextEditorSourcePosition?
        var reportedRect: Rect?
        let tester = ViewTester {
            TextEditor(
                text: Binding(
                    get: { model.text },
                    set: { model.text = $0 }
                ),
                sourceInteraction: TextEditorSourceInteraction(
                    onCaretViewportRectChange: { position, rect in
                        reportedPosition = position
                        reportedRect = rect
                    }
                )
            )
            .font(.system(size: 12))
            .frame(width: 360, height: 160)
        }
        .setSize(Size(width: 380, height: 180))
        .performLayout()

        let node = try #require(tester.sendMouseEvent(at: Point(100, 28), phase: .began, time: 0) as? TextEditorViewNode)
        let lines = node.lines()
        let offset = node.offset(line: 50, column: 4, lines: lines)
        node.selectionAnchor = offset
        node.selectionHead = offset
        node.ensureCaretVisibleIfNeeded()
        node.notifyCaretChange(requestsCompletion: false)

        let scrollOffset = try #require(node.nearestScrollView()?.contentOffset)
        let contentRect = node.caretRect()
        let viewportRect = try #require(reportedRect)
        #expect(scrollOffset.y > 0)
        #expect(reportedPosition == TextEditorSourcePosition(line: 50, column: 4))
        #expect(abs(viewportRect.minX - (contentRect.minX - scrollOffset.x)) < 0.01)
        #expect(abs(viewportRect.minY - (contentRect.minY - scrollOffset.y)) < 0.01)
        #expect(viewportRect.minY >= 0)
        #expect(viewportRect.maxY <= 160)
    }

    @Test
    func textEditor_reusesVisibleGlyphLayoutsAcrossScrollFrames() throws {
        final class Model {
            var text = (1...20).map { "line \($0) has source text" }.joined(separator: "\n")
        }

        let model = Model()
        let tester = ViewTester {
            TextEditor(
                text: Binding(
                    get: { model.text },
                    set: { model.text = $0 }
                )
            )
            .font(.system(size: 12))
            .frame(width: 360, height: 160)
        }
        .setSize(Size(width: 380, height: 180))
        .performLayout()

        let node = try #require(tester.sendMouseEvent(at: Point(40, 40), phase: .began, time: 0) as? TextEditorViewNode)
        tester.sendMouseEvent(at: Point(40, 40), phase: .ended, time: 0.01)
        tester.containerView.viewTree.rootNode.draw(with: UIGraphicsContext())
        let firstFrameMisses = node.textLayoutCacheMisses

        tester.sendMouseEvent(
            at: Point(40, 40),
            button: .scrollWheel,
            phase: .changed,
            scrollDelta: Point(0, -1),
            time: 0.02
        )
        tester.containerView.viewTree.rootNode.draw(with: UIGraphicsContext())

        let secondFrameMisses = node.textLayoutCacheMisses - firstFrameMisses
        #expect(firstFrameMisses > 0)
        #expect(node.textLayoutCacheHits > 0)
        #expect(secondFrameMisses < firstFrameMisses)
    }

    @Test
    func textEditor_usesGlyphMetricsForCaretPosition() throws {
        final class Model {
            var text = "iiii"
        }

        let model = Model()
        let tester = ViewTester {
            TextEditor(
                text: Binding(
                    get: { model.text },
                    set: { model.text = $0 }
                )
            )
            .font(.system(size: 18))
            .frame(width: 360, height: 160)
        }
        .setSize(Size(width: 380, height: 180))
        .performLayout()

        let node = try #require(tester.sendMouseEvent(at: Point(100, 28), phase: .began, time: 0) as? TextEditorViewNode)
        tester.sendMouseEvent(at: Point(100, 28), phase: .ended, time: 0.01)

        let font = try #require(node.resolvedFontForRendering())
        let pointSize = node.resolvedFontPointSize()
        let narrowEndX = node.caretXOffset(forColumn: 4, in: "iiii", font: font, pointSize: pointSize)
        let wideEndX = node.caretXOffset(forColumn: 4, in: "WWWW", font: font, pointSize: pointSize)

        #expect(wideEndX > narrowEndX)
    }

    @Test
    func textEditor_caretStopsIncludeLeadingWhitespaceAdvance() throws {
        final class Model {
            var text = "    Text"
        }

        let model = Model()
        let tester = ViewTester {
            TextEditor(
                text: Binding(
                    get: { model.text },
                    set: { model.text = $0 }
                )
            )
            .font(.system(size: 18))
            .frame(width: 360, height: 160)
        }
        .setSize(Size(width: 380, height: 180))
        .performLayout()

        let node = try #require(tester.sendMouseEvent(at: Point(100, 28), phase: .began, time: 0) as? TextEditorViewNode)
        let font = try #require(node.resolvedFontForRendering())
        let pointSize = node.resolvedFontPointSize()
        let indentationEndX = node.caretXOffset(forColumn: 4, in: model.text, font: font, pointSize: pointSize)
        let singleSpaceEndX = node.caretXOffset(forColumn: 1, in: " ", font: font, pointSize: pointSize)

        #expect(singleSpaceEndX > 0)
        #expect(abs(indentationEndX - singleSpaceEndX * 4) < 0.01)
    }

    @Test
    func textEditor_tokenSpansPreserveInterTokenWhitespace() throws {
        final class Model {
            var text = "import AdaEngine"
        }

        let model = Model()
        let tester = ViewTester {
            TextEditor(
                text: Binding(
                    get: { model.text },
                    set: { model.text = $0 }
                )
            )
            .font(.system(size: 12))
            .frame(width: 360, height: 160)
        }
        .setSize(Size(width: 380, height: 180))
        .performLayout()

        let node = try #require(tester.sendMouseEvent(at: Point(100, 28), phase: .began, time: 0) as? TextEditorViewNode)
        let font = try #require(node.resolvedFontForRendering())
        let tokenFont = Font.system(size: 12, weight: .bold)
        let line = "import AdaEngine"
        let lineSpans = [
            TextEditorTokenSpan(line: 0, startColumn: 0, length: 6, color: .red, font: tokenFont),
            TextEditorTokenSpan(line: 0, startColumn: 7, length: 9, color: .blue)
        ]

        let attributedText = node.attributedLineText(line, lineSpans: lineSpans, font: font, fallbackColor: .white)
        let spaceIndex = line.index(line.startIndex, offsetBy: 6)
        let typeIndex = line.index(line.startIndex, offsetBy: 7)

        #expect(attributedText.text == line)
        #expect(attributedText.attributes(at: line.startIndex).font == tokenFont)
        #expect(attributedText.attributes(at: spaceIndex).foregroundColor == .white)
        #expect(attributedText.attributes(at: typeIndex).font == font)
        #expect(attributedText.attributes(at: typeIndex).foregroundColor == .blue)
    }

    @Test
    func textEditor_commandHoveredRangeOverridesTokenForeground() throws {
        final class Model {
            var text = "document.dispatchEvent"
        }

        let model = Model()
        let tester = ViewTester {
            TextEditor(
                text: Binding(
                    get: { model.text },
                    set: { model.text = $0 }
                )
            )
            .font(.system(size: 12))
            .frame(width: 360, height: 160)
        }
        .setSize(Size(width: 380, height: 180))
        .performLayout()

        let node = try #require(tester.sendMouseEvent(at: Point(100, 28), phase: .began, time: 0) as? TextEditorViewNode)
        let font = try #require(node.resolvedFontForRendering())
        let line = model.text
        let attributedText = node.attributedLineText(
            line,
            lineSpans: [TextEditorTokenSpan(line: 0, startColumn: 9, length: 13, color: .red)],
            font: font,
            fallbackColor: .white,
            hoveredRange: TextEditorSourceRange(
                start: TextEditorSourcePosition(line: 0, column: 9),
                end: TextEditorSourcePosition(line: 0, column: 22)
            ),
            lineIndex: 0,
            hoverColor: .blue
        )
        let receiverIndex = line.index(line.startIndex, offsetBy: 2)
        let methodIndex = line.index(line.startIndex, offsetBy: 10)

        #expect(attributedText.attributes(at: receiverIndex).foregroundColor == .white)
        #expect(attributedText.attributes(at: methodIndex).foregroundColor == .blue)
    }

    @Test
    func textEditor_sourceInteractionReportsCommandHoverAndClick() {
        final class Model {
            var text = "alpha\nbeta"
        }

        let model = Model()
        var hoveredPosition: TextEditorSourcePosition?
        var clickedPosition: TextEditorSourcePosition?
        let tester = ViewTester {
            TextEditor(
                text: Binding(
                    get: { model.text },
                    set: { model.text = $0 }
                ),
                sourceInteraction: TextEditorSourceInteraction(
                    onHover: { hoveredPosition = $0 },
                    onPrimaryClick: { clickedPosition = $0 }
                )
            )
            .font(.system(size: 12))
            .frame(width: 360, height: 160)
        }
        .setSize(Size(width: 380, height: 180))
        .performLayout()

        tester.sendMouseEvent(at: Point(82, 16), button: .none, phase: .changed, modifierKeys: [.main], time: 0)
        #expect(hoveredPosition?.line == 0)
        #expect((hoveredPosition?.column ?? -1) >= 0)

        tester.sendMouseEvent(at: Point(82, 16), button: .left, phase: .began, modifierKeys: [.main], time: 0.01)
        #expect(clickedPosition?.line == hoveredPosition?.line)
        #expect(clickedPosition?.column == hoveredPosition?.column)

        tester.sendMouseEvent(at: Point(82, 16), button: .none, phase: .changed, time: 0.02)
        #expect(hoveredPosition == nil)
    }

    @Test
    func textEditor_dragSelectionDoesNotRequestCompletion() {
        final class Model {
            var text = "alpha beta"
        }

        let model = Model()
        var completionRequestCount = 0
        let tester = ViewTester {
            TextEditor(
                text: Binding(
                    get: { model.text },
                    set: { model.text = $0 }
                ),
                sourceInteraction: TextEditorSourceInteraction(
                    onCaretChange: { _, _ in
                        completionRequestCount += 1
                    }
                )
            )
            .font(.system(size: 12))
            .frame(width: 360, height: 160)
        }
        .setSize(Size(width: 380, height: 180))
        .performLayout()

        tester.sendMouseEvent(at: Point(74, 28), phase: .began, time: 0)
        tester.sendMouseEvent(at: Point(160, 28), phase: .changed, time: 0.01)
        tester.sendMouseEvent(at: Point(160, 28), phase: .ended, time: 0.02)

        #expect(completionRequestCount == 0)

        tester.sendTextInput("x", time: 0.03)
        #expect(completionRequestCount == 1)
    }

    @Test
    func textEditor_commandLChatsWithSelectedText() {
        final class Model {
            var text = "alpha\nbeta"
        }

        let model = Model()
        var selectionText: String?
        var chatText: String?
        var chatRange: TextEditorSourceRange?
        let tester = ViewTester {
            TextEditor(
                text: Binding(
                    get: { model.text },
                    set: { model.text = $0 }
                ),
                sourceInteraction: TextEditorSourceInteraction(
                    onSelectionChange: { _, text in selectionText = text },
                    onChatSelection: { range, text in
                        chatRange = range
                        chatText = text
                    }
                )
            )
            .font(.system(size: 12))
            .frame(width: 360, height: 160)
        }
        .setSize(Size(width: 380, height: 180))
        .performLayout()

        tester.sendMouseEvent(at: Point(100, 28), phase: .began, time: 0)
        tester.sendMouseEvent(at: Point(100, 28), phase: .ended, time: 0.01)
        tester.sendKeyEvent(.a, modifiers: [.main], time: 0.02)
        tester.sendKeyEvent(.l, modifiers: [.main], time: 0.03)

        #expect(selectionText == model.text)
        #expect(chatText == model.text)
        #expect(chatRange?.start == TextEditorSourcePosition(line: 0, column: 0))
        #expect(chatRange?.end == TextEditorSourcePosition(line: 1, column: 4))
    }

    @Test
    func textEditor_escapeRequestsCompletionAtCurrentCaret() {
        final class Model {
            var text = "alpha"
        }

        let model = Model()
        var requestedPosition: TextEditorSourcePosition?
        var requestedText: String?
        let tester = ViewTester {
            TextEditor(
                text: Binding(
                    get: { model.text },
                    set: { model.text = $0 }
                ),
                sourceInteraction: TextEditorSourceInteraction(
                    onRequestCompletion: { position, text in
                        requestedPosition = position
                        requestedText = text
                    }
                )
            )
            .font(.system(size: 12))
            .frame(width: 360, height: 160)
        }
        .setSize(Size(width: 380, height: 180))
        .performLayout()

        tester.sendMouseEvent(at: Point(100, 28), phase: .began, time: 0)
        tester.sendMouseEvent(at: Point(100, 28), phase: .ended, time: 0.01)
        tester.sendKeyEvent(.escape, time: 0.02)

        #expect(requestedPosition != nil)
        #expect(requestedText == model.text)
    }

    @Test
    func textEditor_sourceInteractionPresentsContextMenu() {
        final class Model {
            var text = "alpha"
        }

        let model = Model()
        var menuTitles: [String] = []
        var submenuTitles: [String] = []
        ContextMenuPresentationCenter.present = { presentation in
            menuTitles = presentation.items.map(\.title)
            submenuTitles = presentation.items.first?.submenu.map(\.title) ?? []
        }
        defer { ContextMenuPresentationCenter.present = nil }

        let tester = ViewTester {
            TextEditor(
                text: Binding(
                    get: { model.text },
                    set: { model.text = $0 }
                ),
                sourceInteraction: TextEditorSourceInteraction(
                    contextMenuItems: { _ in
                        [
                            TextEditorContextMenuItem(
                                title: "Go To",
                                submenu: [
                                    TextEditorContextMenuItem(title: "Definition")
                                ]
                            ),
                            TextEditorContextMenuItem(title: "Find References")
                        ]
                    }
                )
            )
            .font(.system(size: 12))
            .frame(width: 360, height: 160)
        }
        .setSize(Size(width: 380, height: 180))
        .performLayout()

        tester.sendMouseEvent(at: Point(82, 16), button: .right, phase: .began, time: 0)

        #expect(menuTitles == ["Go To", "Find References"])
        #expect(submenuTitles == ["Definition"])
    }

    @Test
    func textEditor_sourceHighlightKeepsZeroLengthDiagnosticsVisible() {
        let range = TextEditorSourceRange(
            start: TextEditorSourcePosition(line: 2, column: 7),
            end: TextEditorSourcePosition(line: 2, column: 7)
        )

        let columns = TextEditorViewNode.sourceUnderlineColumns(
            for: range,
            lineIndex: 2,
            lineLength: 12
        )

        #expect(columns?.start == 7)
        #expect(columns?.end == 7)
        #expect(TextEditorViewNode.sourceUnderlineColumns(for: range, lineIndex: 1, lineLength: 12) == nil)
    }
}
