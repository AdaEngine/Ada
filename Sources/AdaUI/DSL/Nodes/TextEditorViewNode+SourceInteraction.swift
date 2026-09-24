//
//  TextEditorViewNode+SourceInteraction.swift
//  AdaEngine
//
//  Created by Codex on 24.05.2026.
//

import AdaInput
import AdaText
import Math

extension TextEditorViewNode {
    func handleSourceInteractionMouseEvent(_ event: MouseEvent) -> Bool {
        let localPoint = self.convertPointFromRoot(event.mousePosition)
        if let foldMouseLine {
            if event.phase == .ended, self.foldLine(at: localPoint) == foldMouseLine {
                self.toggleFold(at: foldMouseLine)
            }
            if event.phase == .ended || event.phase == .cancelled {
                self.foldMouseLine = nil
            }
            return true
        }
        if let line = self.foldLine(at: localPoint) {
            if event.phase == .began, event.button == .left {
                self.foldMouseLine = line
            }
            if event.button == .left || (event.phase == .changed && event.button == .none) {
                self.updateHoveredGutterLine(nil)
                self.notifySourceHover(nil)
                self.resetTextCursorIfNeeded()
                return true
            }
        }
        guard let sourceInteraction else {
            return false
        }

        if event.phase == .changed, event.button == .none {
            let hoveredLine = gutterLine(at: localPoint)
            updateHoveredGutterLine(hoveredLine)
            if hoveredLine != nil {
                notifySourceHover(nil)
                resetSourceCursorIfNeeded()
                resetTextCursorIfNeeded()
                return true
            }
        }
        if let line = gutterLine(at: localPoint), let action = sourceInteraction.onGutterClick {
            if event.phase == .began, event.button == .left {
                action(line)
            }
            if event.button == .left {
                return true
            }
        }
        let sourcePosition = self.sourcePosition(at: localPoint)

        if event.phase == .began, event.button == .right {
            self.presentSourceContextMenu(at: event.mousePosition, sourcePosition: sourcePosition, interaction: sourceInteraction)
            return true
        }

        if event.modifierKeys.contains(.main) {
            switch event.phase {
            case .changed where event.button == .none:
                self.activateSourceCursorIfNeeded()
                self.notifySourceHover(sourcePosition)
                return true
            case .began where event.button == .left:
                sourceInteraction.onPrimaryClick?(sourcePosition)
                self.notifySourceHover(sourcePosition)
                return true
            case .ended,
                .cancelled:
                return true
            default:
                break
            }
        } else if event.phase == .changed, event.button == .none {
            updateHoveredGutterLine(nil)
            self.notifySourceHover(nil)
            self.resetSourceCursorIfNeeded()
        }

        return false
    }

    func updateHoveredGutterLine(_ line: Int?) {
        guard hoveredGutterLine != line else {
            return
        }
        hoveredGutterLine = line
        requestDisplay()
    }

    func gutterLine(at point: Point) -> Int? {
        guard showsLineNumbers, sourceInteraction?.onGutterClick != nil else {
            return nil
        }
        let content = textContentRect()
        let gutter = gutterViewportRect()
        guard point.x >= gutter.minX, point.x < gutter.maxX, point.y >= content.minY else {
            return nil
        }
        let row = Int((point.y - content.minY) / lineHeight(for: resolvedFontPointSize()))
        guard row >= 0, row < displayedLines().count else { return nil }
        return sourceLine(atDisplayRow: row)
    }

    func notifySourceHover(_ position: TextEditorSourcePosition?) {
        guard self.lastHoveredSourcePosition != position else {
            return
        }

        self.lastHoveredSourcePosition = position
        self.sourceInteraction?.onHover?(position)
    }

    func notifyCaretChange(requestsCompletion: Bool = true) {
        if self.hasSelection {
            self.sourceInteraction?.onSelectionChange?(self.selectedSourceRange(), self.selectedText())
        } else {
            self.sourceInteraction?.onSelectionChange?(nil, nil)
        }

        let position = self.position(forOffset: self.selectionHead, lines: self.lines())
        let sourcePosition = TextEditorSourcePosition(line: position.line, column: position.column)
        self.sourceInteraction?.onCaretViewportRectChange?(sourcePosition, self.caretViewportRect())

        guard requestsCompletion else {
            return
        }

        self.sourceInteraction?.onCaretChange?(
            sourcePosition,
            self.text
        )
    }

    func applyFocusedRangeIfNeeded() {
        let focusedRange = self.sourceInteraction?.focusedRange
        guard focusedRange != self.appliedFocusedRange else {
            return
        }

        self.appliedFocusedRange = focusedRange
        guard let focusedRange else {
            return
        }

        let range = self.rangeOffsets(for: focusedRange)
        self.selectionAnchor = range.lowerBound
        self.selectionHead = range.upperBound
        self.clampSelectionToBounds()
        self.ensureCaretVisibleIfNeeded()
    }

    private func presentSourceContextMenu(
        at location: Point,
        sourcePosition: TextEditorSourcePosition,
        interaction: TextEditorSourceInteraction
    ) {
        guard let provider = interaction.contextMenuItems else {
            return
        }

        let items = provider(sourcePosition)
        guard !items.isEmpty else {
            return
        }

        ContextMenuPresentationCenter.present?(
            ContextMenuPresentation(
                sourceWindow: owner?.window,
                location: location,
                items: items.enumerated()
                    .map { index, item in
                        ContextMenuPresentation.Item(
                            id: index,
                            title: item.title,
                            action: item.action,
                            submenu: item.submenu.presentationItems()
                        )
                    }
            )
        )
    }
}

extension [TextEditorContextMenuItem] {
    func presentationItems() -> [ContextMenuPresentation.Item] {
        self.enumerated()
            .map { index, item in
                ContextMenuPresentation.Item(
                    id: index,
                    title: item.title,
                    action: item.action,
                    submenu: item.submenu.presentationItems()
                )
            }
    }
}

extension TextEditorViewNode {
    /// Frame in the scrolling text node's coordinates, with horizontal placement fixed to the viewport.
    func selectionHintFrame() -> Rect? {
        guard isFocused, hasSelection, sourceInteraction?.selectionHint != nil else {
            return nil
        }
        let viewport = viewportChromeRect()
        let width: Float = 166
        let height: Float = 26
        guard viewport.width >= width + 24, viewport.height >= height + 8 else {
            return nil
        }
        let content = textContentRect()
        let lineHeight = lineHeight(for: resolvedFontPointSize())
        let lines = lines()
        let first = position(forOffset: selectionRange.lowerBound, lines: lines).line
        let last = position(forOffset: selectionRange.upperBound - 1, lines: lines).line
        let firstVisible = max(displayRow(forLine: first), Int(((viewport.minY - content.minY) / lineHeight).rounded(.down)))
        let lastVisible = min(displayRow(forLine: last), Int(((viewport.maxY - content.minY - 1) / lineHeight).rounded(.down)))
        guard firstVisible <= lastVisible else {
            return nil
        }
        let activeRow = selectionHead < selectionAnchor ? firstVisible : lastVisible
        let rowCenter = content.minY + (Float(activeRow) + 0.5) * lineHeight
        return Rect(
            x: viewport.maxX - width - 12,
            y: min(max(viewport.minY + 4, rowCenter - height / 2), viewport.maxY - height - 4),
            width: width,
            height: height
        )
    }

    func drawSelectionHint(in context: inout UIGraphicsContext) {
        guard let hint = sourceInteraction?.selectionHint, let frame = selectionHintFrame() else {
            return
        }
        let path = RoundedRectangleShape(cornerRadius: 5).path(in: frame)
        context.fill(path, with: hint.background)
        context.stroke(path, with: hint.border, style: StrokeStyle(lineWidth: 1))
        drawString(hint.text, font: .system(size: 10), color: hint.foreground, in: &context, at: Point(frame.minX + 10, frame.minY + 4))
    }
}
