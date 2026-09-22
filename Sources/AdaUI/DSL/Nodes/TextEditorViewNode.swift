//
//  TextEditorViewNode.swift
//  AdaEngine
//
//  Created by Codex on 18.05.2026.
//

import AdaInput
import AdaRender
import AdaText
import AdaUtils
import Math

final class TextEditorViewNode: ViewNode {
    struct Snapshot: Equatable {
        var text: String
        var selectionAnchor: Int
        var selectionHead: Int
    }

    struct TextPosition: Equatable {
        var line: Int
        var column: Int
    }

    struct LineInfo {
        var text: String
        var startOffset: Int
    }

    struct CachedTextLayout {
        var layout: TextLayoutManager
        var lastAccess: UInt64
    }

    struct TextLayoutCacheKey: Hashable {
        var text: AttributedText
        var lineHeight: Float
    }

    enum Constants {
        static let horizontalInset: Float = 10
        static let verticalInset: Float = 8
        static let gutterWidth: Float = 52
        static let gutterSpacing: Float = 10
        static let minimumWidth: Float = 260
        static let minimumHeight: Float = 120
        static let placeholderOpacity: Float = 0.45
        static let maxUndoDepth = 128
        static let caretLineWidth: Float = 1.5
        static let caretBlinkInterval: AdaUtils.TimeInterval = 1.15
        static let tapMovementToleranceSquared: Float = 36
        static let doubleTapMovementToleranceSquared: Float = 100
        static let doubleTapMaxInterval: AdaUtils.TimeInterval = 0.35
        static let caretScrollPadding: Float = 24
    }

    var placeholder: String
    var textBinding: Binding<String>
    var tokenSpans: [TextEditorTokenSpan]
    var sourceInteraction: TextEditorSourceInteraction?
    var showsLineNumbers: Bool
    var text: String

    var isFocused = false
    var isCursorActive = false
    var isSourceCursorActive = false
    var isSelectingWithMouse = false
    var isSelectingWithTouch = false
    var gutterTouchLine: Int?
    var hoveredGutterLine: Int?
    var mousePressStartPoint: Point?
    var touchPressStartPoint: Point?
    var lastTapTime: AdaUtils.TimeInterval?
    var lastTapPosition: Point?
    var lastHoveredSourcePosition: TextEditorSourcePosition?
    var appliedFocusedRange: TextEditorSourceRange?
    var preferredColumn: Int?
    var caretVisible = true
    var caretBlinkElapsed: AdaUtils.TimeInterval = 0
    var selectionAnchor = 0
    var selectionHead = 0

    var undoStack: [Snapshot] = []
    var redoStack: [Snapshot] = []

    var textLayoutCache: [TextLayoutCacheKey: CachedTextLayout] = [:]
    var textLayoutCacheAccess: UInt64 = 0
    var textLayoutCacheHits = 0
    var textLayoutCacheMisses = 0
    var lineCache: [LineInfo]?

    init(inputs: _ViewInputs, content: TextEditorPrimitive) {
        self.placeholder = content.placeholder
        self.textBinding = content.text
        self.tokenSpans = content.tokenSpans
        self.sourceInteraction = content.sourceInteraction
        self.showsLineNumbers = content.showsLineNumbers
        self.text = Self.normalizeInputText(content.text.wrappedValue)
        super.init(content: content)
        self.updateEnvironment(inputs.environment)
        self.clampSelectionToBounds()
        self.applyFocusedRangeIfNeeded()
    }

    override var canBecomeFocused: Bool {
        true
    }

    override func sizeThatFits(_ proposal: ProposedViewSize) -> Size {
        let pointSize = self.resolvedFontPointSize()
        let lineHeight = self.lineHeight(for: pointSize)
        let lines = self.lines()
        let maxLineCharacterCount = max(lines.map(\.text.count).max() ?? 0, self.placeholder.count, 1)
        let maxLineWidth = Float(maxLineCharacterCount) * self.characterAdvance(for: pointSize)
        let ideal = Size(
            width: max(Constants.minimumWidth, Constants.horizontalInset * 2 + self.gutterInset + maxLineWidth),
            height: max(Constants.minimumHeight, Constants.verticalInset * 2 + lineHeight * Float(max(lines.count, 1)))
        )

        var result = proposal.replacingUnspecifiedDimensions(by: ideal)
        if result.width == .infinity {
            result.width = ideal.width
        }
        if result.height == .infinity {
            result.height = ideal.height
        }

        return result
    }

    override func update(from newNode: ViewNode) {
        super.update(from: newNode)

        guard let node = newNode as? TextEditorViewNode else {
            return
        }

        self.placeholder = node.placeholder
        self.textBinding = node.textBinding
        self.tokenSpans = node.tokenSpans
        self.sourceInteraction = node.sourceInteraction
        self.showsLineNumbers = node.showsLineNumbers

        let externalText = Self.normalizeInputText(node.textBinding.wrappedValue)
        if externalText != self.text {
            self.text = externalText
            self.invalidateTextCaches()
            self.undoStack.removeAll(keepingCapacity: true)
            self.redoStack.removeAll(keepingCapacity: true)
            self.appliedFocusedRange = nil
        }

        self.clampSelectionToBounds()
        self.applyFocusedRangeIfNeeded()
        self.ensureCaretVisibleIfNeeded()
        self.requestDisplay()
    }

    override func hitTest(_ point: Point, with event: any InputEvent) -> ViewNode? {
        guard self.point(inside: point, with: event) else {
            return nil
        }
        return self
    }

    override func onFocusChanged(isFocused: Bool) { self.updateTextEditorFocus(isFocused) }

    override func onMouseEvent(_ event: MouseEvent) {
        if self.handleSourceInteractionMouseEvent(event) {
            return
        }

        self.activateTextCursorIfNeeded()

        let shouldHandleSelectionEvent: Bool =
            switch event.phase {
            case .began,
                .ended,
                .cancelled:
                event.button == .left
            case .changed:
                event.button == .left || self.isSelectingWithMouse
            }

        guard shouldHandleSelectionEvent else {
            return
        }

        let localPoint = self.convertPointFromRoot(event.mousePosition)
        let caretOffset = self.closestOffset(to: localPoint)

        switch event.phase {
        case .began:
            self.isSelectingWithMouse = true
            self.mousePressStartPoint = localPoint
            if event.modifierKeys.contains(.shift), self.isFocused {
                self.selectionHead = caretOffset
            } else {
                self.setSelection(to: caretOffset)
            }
            self.preferredColumn = nil
        case .changed:
            guard self.isSelectingWithMouse else {
                return
            }
            self.selectionHead = caretOffset
            self.preferredColumn = nil
        case .ended,
            .cancelled:
            self.isSelectingWithMouse = false
            if !self.isTap(at: localPoint, start: self.mousePressStartPoint) {
                self.selectionHead = caretOffset
                self.clearTapCandidate()
            } else if event.phase == .ended {
                self.handleTapCompletion(at: localPoint, time: event.time, caretOffset: caretOffset)
            }
            self.mousePressStartPoint = nil
            self.preferredColumn = nil
        }

        self.clampSelectionToBounds()
        self.notifyCaretChange(requestsCompletion: false)
        self.ensureCaretVisibleIfNeeded()
        self.resetCaretBlink()
        self.requestDisplay()
    }

    override func onTouchesEvent(_ touches: Set<TouchEvent>) { self.handleTextEditorTouches(touches) }

    override func onMouseLeave() { self.handleTextEditorMouseLeave() }

    override func onTextInputEvent(_ event: TextInputEvent) {
        guard self.isFocused else {
            return
        }

        switch event.action {
        case .insert:
            self.insertText(event.text)
        case .deleteBackward:
            self.deleteBackward()
        }

        self.preferredColumn = nil
        self.notifyCaretChange()
        self.resetCaretBlink()
    }

    override func onKeyEvent(_ event: KeyEvent) {
        guard self.isFocused, event.status == .down else {
            return
        }

        if self.handleShortcut(event) {
            self.notifyCaretChange()
            self.resetCaretBlink()
            return
        }

        if event.modifiers.isEmpty {
            let completionCommandHandled =
                switch event.keyCode {
                case .arrowUp:
                    self.sourceInteraction?.onMoveCompletionSelection?(-1) == true
                case .arrowDown:
                    self.sourceInteraction?.onMoveCompletionSelection?(1) == true
                case .enter:
                    self.sourceInteraction?.onAcceptCompletion?() == true
                default:
                    false
                }
            if completionCommandHandled {
                self.resetCaretBlink()
                return
            }
        }

        if event.keyCode == .escape, let requestCompletion = self.sourceInteraction?.onRequestCompletion {
            let position = self.position(forOffset: self.selectionHead, lines: self.lines())
            requestCompletion(
                TextEditorSourcePosition(line: position.line, column: position.column),
                self.text
            )
            self.resetCaretBlink()
            return
        }

        let extendSelection = event.modifiers.contains(.shift)
        #if os(macOS) || os(iOS) || os(tvOS) || os(visionOS)
            let movesToLineBoundary = event.modifiers.contains(.main)
            let movesByWordBoundary = event.modifiers.contains(.alt)
        #else
            let movesToLineBoundary = false
            let movesByWordBoundary =
                event.modifiers.contains(.main)
                || event.modifiers.contains(.control)
        #endif

        switch event.keyCode {
        case .enter:
            self.insertNewlineWithIndentation()
        case .tab:
            self.insertText("    ")
        case .arrowLeft:
            if movesToLineBoundary {
                self.moveCaretToLineStart(extendSelection: extendSelection)
            } else if movesByWordBoundary {
                self.moveCaretByWordBoundary(direction: -1, extendSelection: extendSelection)
            } else {
                self.moveCaretHorizontally(delta: -1, extendSelection: extendSelection)
            }
        case .arrowRight:
            if movesToLineBoundary {
                self.moveCaretToLineEnd(extendSelection: extendSelection)
            } else if movesByWordBoundary {
                self.moveCaretByWordBoundary(direction: 1, extendSelection: extendSelection)
            } else {
                self.moveCaretHorizontally(delta: 1, extendSelection: extendSelection)
            }
        case .arrowUp:
            self.moveCaretVertically(delta: -1, extendSelection: extendSelection)
        case .arrowDown:
            self.moveCaretVertically(delta: 1, extendSelection: extendSelection)
        case .home:
            if event.modifiers.contains(.main) {
                self.moveCaretToDocumentStart(extendSelection: extendSelection)
            } else {
                self.moveCaretToLineStart(extendSelection: extendSelection)
            }
        case .pageUp:
            self.moveCaretByPage(delta: -1, extendSelection: extendSelection)
        case .pageDown:
            self.moveCaretByPage(delta: 1, extendSelection: extendSelection)
        case .delete:
            self.deleteForward()
        default:
            return
        }

        self.notifyCaretChange()
        self.resetCaretBlink()
    }

    override func update(_ deltaTime: AdaUtils.TimeInterval) {
        guard self.isFocused else {
            return
        }

        self.caretBlinkElapsed += deltaTime
        guard self.caretBlinkElapsed >= Constants.caretBlinkInterval else {
            return
        }

        self.caretBlinkElapsed.formTruncatingRemainder(dividingBy: Constants.caretBlinkInterval)
        self.caretVisible.toggle()
        if !self.hasSelection {
            self.requestDisplay()
        }
    }

    override func draw(with context: UIGraphicsContext) {
        var context = context
        context.environment = environment
        super.draw(with: context)

        let bounds = Rect(x: 0, y: 0, width: self.frame.width, height: self.frame.height)
        let viewportBounds = self.viewportChromeRect()
        let contentRect = self.textContentRect()
        let textRect = self.textRect()
        let pointSize = self.resolvedFontPointSize()
        let lineHeight = self.lineHeight(for: pointSize)
        let editorColors = self.environment.textEditorColors
        let borderColor = self.isFocused ? editorColors.focusedBorder : editorColors.border

        context.translateBy(x: self.frame.origin.x, y: -self.frame.origin.y)
        context.drawRect(bounds, color: editorColors.background)
        self.drawBorder(in: &context, rect: viewportBounds, color: borderColor)

        guard contentRect.width > 0, contentRect.height > 0 else {
            return
        }

        if self.showsLineNumbers {
            context.drawLine(
                start: Point(textRect.origin.x - Constants.gutterSpacing * 0.5, -contentRect.minY),
                end: Point(textRect.origin.x - Constants.gutterSpacing * 0.5, -contentRect.maxY),
                lineWidth: 1,
                color: editorColors.gutterRule
            )
        }

        let clipRect = self.visualAbsoluteContentRect()
        context.clip(to: clipRect) { clippedContext in
            var clippedContext = clippedContext
            let viewportHeight = min(contentRect.height, self.nearestScrollView()?.frame.height ?? contentRect.height)
            let visibleLines = self.visibleLineRange(lineHeight: lineHeight, viewportHeight: viewportHeight)
            let lines = self.lines()
            let caretPosition = self.position(forOffset: self.selectionHead, lines: lines)
            let textColor = self.resolvedTextColor()
            let resolvedFont = self.resolvedFontForRendering()

            for lineIndex in visibleLines where lines.indices.contains(lineIndex) {
                let line = lines[lineIndex]
                let rowY = contentRect.origin.y + Float(lineIndex) * lineHeight
                let rowRect = Rect(x: contentRect.minX, y: rowY, width: contentRect.width, height: lineHeight)

                if self.isFocused, caretPosition.line == lineIndex {
                    clippedContext.drawRect(rowRect, color: editorColors.currentLineBackground)
                }

                if self.sourceInteraction?.executionLine == lineIndex {
                    clippedContext.drawRect(rowRect, color: self.environment.accentColor.opacity(0.20))
                    clippedContext.drawRect(
                        Rect(x: textRect.minX - 5, y: rowY, width: 3, height: lineHeight),
                        color: self.environment.accentColor
                    )
                }
                if self.showsLineNumbers,
                    let marker = self.sourceInteraction?.lineMarkers.first(where: { $0.line == lineIndex }) {
                    clippedContext.drawEllipse(
                        in: Rect(x: contentRect.minX, y: rowY + (lineHeight - 10) * 0.5, width: 10, height: 10),
                        color: marker.color,
                        thickness: marker.isFilled ? 1 : 0.22
                    )
                } else if self.showsLineNumbers,
                    self.hoveredGutterLine == lineIndex,
                    let color = self.sourceInteraction?.gutterHoverColor {
                    clippedContext.drawEllipse(
                        in: Rect(x: contentRect.minX, y: rowY + (lineHeight - 10) * 0.5, width: 10, height: 10),
                        color: color,
                        thickness: 0.22
                    )
                }

                self.drawSourceHighlightsIfNeeded(
                    in: &clippedContext,
                    line: line,
                    lineIndex: lineIndex,
                    rowY: rowY,
                    lineHeight: lineHeight,
                    pointSize: pointSize,
                    font: resolvedFont
                )

                self.drawSelectionIfNeeded(
                    in: &clippedContext,
                    line: line,
                    lineIndex: lineIndex,
                    rowY: rowY,
                    lineHeight: lineHeight,
                    pointSize: pointSize,
                    font: resolvedFont,
                    lineCount: lines.count
                )

                if let resolvedFont {
                    if self.showsLineNumbers {
                        let number = String(lineIndex + 1)
                        self.drawString(
                            number,
                            font: resolvedFont,
                            color: editorColors.gutter,
                            in: &clippedContext,
                            at: Point(contentRect.minX + Constants.gutterWidth - Float(number.count) * self.characterAdvance(for: pointSize), rowY)
                        )
                    }
                    self.drawLineText(
                        line.text,
                        lineIndex: lineIndex,
                        font: resolvedFont,
                        fallbackColor: textColor,
                        in: &clippedContext,
                        at: Point(textRect.minX, rowY)
                    )
                }
            }

            if self.text.isEmpty, !self.placeholder.isEmpty, !self.isFocused, let resolvedFont {
                self.drawString(
                    self.placeholder,
                    font: resolvedFont,
                    color: textColor.opacity(Constants.placeholderOpacity),
                    in: &clippedContext,
                    at: Point(textRect.minX, contentRect.minY)
                )
            }

            self.drawSelectionHint(in: &clippedContext)

            if self.isFocused, self.caretVisible, !self.hasSelection {
                let caretLineText = lines.indices.contains(caretPosition.line) ? lines[caretPosition.line].text : ""
                let caretX = textRect.minX + self.caretXOffset(forColumn: caretPosition.column, in: caretLineText, font: resolvedFont, pointSize: pointSize)
                let caretY = contentRect.minY + Float(caretPosition.line) * lineHeight
                clippedContext.drawRect(
                    Rect(
                        x: caretX - Constants.caretLineWidth * 0.5,
                        y: caretY,
                        width: Constants.caretLineWidth,
                        height: lineHeight
                    ),
                    color: self.environment.accentColor
                )
            }
        }
    }
}
