//
//  TextEditorViewNode+Editing.swift
//  AdaEngine
//
//  Created by Codex on 18.05.2026.
//

import AdaInput
import Math

extension TextEditorViewNode {
    var hasSelection: Bool {
        self.selectionAnchor != self.selectionHead
    }

    var caretOffset: Int {
        self.selectionHead
    }

    var selectionRange: Range<Int> {
        min(self.selectionAnchor, self.selectionHead)..<max(self.selectionAnchor, self.selectionHead)
    }

    func handleShortcut(_ event: KeyEvent) -> Bool {
        let hasMainModifier = event.modifiers.contains(.main) || event.modifiers.contains(.control)
        guard hasMainModifier else {
            return false
        }

        switch event.keyCode {
        case .a:
            self.selectAll()
            return true
        case .c:
            self.copySelection()
            return true
        case .l:
            guard self.hasSelection, let onChatSelection = self.sourceInteraction?.onChatSelection else {
                return false
            }
            onChatSelection(self.selectedSourceRange(), self.selectedText())
            return true
        case .x:
            self.cutSelection()
            return true
        case .v:
            self.pasteText()
            return true
        case .z:
            if event.modifiers.contains(.shift) {
                self.redo()
            } else {
                self.undo()
            }
            return true
        case .y:
            self.redo()
            return true
        default:
            return false
        }
    }

    func moveCaretHorizontally(delta: Int, extendSelection: Bool) {
        let characterCount = self.text.count

        if extendSelection {
            self.selectionHead = max(0, min(characterCount, self.caretOffset + delta))
        } else if self.hasSelection {
            self.setSelection(to: delta < 0 ? self.selectionRange.lowerBound : self.selectionRange.upperBound)
        } else {
            self.setSelection(to: max(0, min(characterCount, self.caretOffset + delta)))
        }

        self.preferredColumn = nil
        self.finishCaretMove()
    }

    func moveCaretByWordBoundary(direction: Int, extendSelection: Bool) {
        if !extendSelection, self.hasSelection {
            self.setSelection(to: direction < 0 ? self.selectionRange.lowerBound : self.selectionRange.upperBound)
            self.preferredColumn = nil
            self.finishCaretMove()
            return
        }

        let targetOffset =
            direction < 0
            ? self.wordBoundaryBefore(offset: self.caretOffset)
            : self.wordBoundaryAfter(offset: self.caretOffset)

        if extendSelection {
            self.selectionHead = targetOffset
        } else {
            self.setSelection(to: targetOffset)
        }

        self.preferredColumn = nil
        self.finishCaretMove()
    }

    func moveCaretVertically(delta: Int, extendSelection: Bool) {
        let lines = self.lines()
        let position = self.position(forOffset: self.caretOffset, lines: lines)
        let targetLine = max(0, min(lines.count - 1, position.line + delta))
        let targetColumn = min(self.preferredColumn ?? position.column, lines[targetLine].text.count)
        self.preferredColumn = self.preferredColumn ?? position.column
        self.moveCaret(to: self.offset(line: targetLine, column: targetColumn, lines: lines), extendSelection: extendSelection)
    }

    func moveCaretByPage(delta: Int, extendSelection: Bool) {
        let pointSize = self.resolvedFontPointSize()
        let lineHeight = self.lineHeight(for: pointSize)
        let visibleLineCount = max(1, Int(self.textContentRect().height / max(1, lineHeight)))
        self.moveCaretVertically(delta: delta * visibleLineCount, extendSelection: extendSelection)
    }

    func moveCaretToLineStart(extendSelection: Bool) {
        let lines = self.lines()
        let position = self.position(forOffset: self.caretOffset, lines: lines)
        self.moveCaret(to: lines[position.line].startOffset, extendSelection: extendSelection)
        self.preferredColumn = nil
    }

    func moveCaretToDocumentStart(extendSelection: Bool) {
        self.moveCaret(to: 0, extendSelection: extendSelection)
        self.preferredColumn = nil
    }

    func moveCaretToLineEnd(extendSelection: Bool) {
        let lines = self.lines()
        let position = self.position(forOffset: self.caretOffset, lines: lines)
        let line = lines[position.line]
        self.moveCaret(to: line.startOffset + line.text.count, extendSelection: extendSelection)
        self.preferredColumn = nil
    }

    func moveCaret(to offset: Int, extendSelection: Bool) {
        if extendSelection {
            self.selectionHead = max(0, min(offset, self.text.count))
        } else {
            self.setSelection(to: offset)
        }
        self.finishCaretMove()
    }

    func finishCaretMove() {
        self.clampSelectionToBounds()
        self.ensureCaretVisibleIfNeeded()
        self.requestDisplay()
    }

    func insertText(_ rawText: String) {
        let inserted = Self.normalizeInputText(rawText)
        guard !inserted.isEmpty else {
            return
        }

        self.replaceSelection(with: inserted)
    }

    func insertNewlineWithIndentation() {
        let insertionOffset = self.selectionRange.lowerBound
        let lines = self.lines()
        let position = self.position(forOffset: insertionOffset, lines: lines)
        guard lines.indices.contains(position.line) else {
            self.replaceSelection(with: "\n")
            return
        }

        let lineText = lines[position.line].text
        let prefixEnd = lineText.index(
            lineText.startIndex,
            offsetBy: min(max(0, position.column), lineText.count)
        )
        let indentation = lineText[..<prefixEnd]
            .prefix { character in
                character == " " || character == "\t"
            }
        self.replaceSelection(with: "\n" + String(indentation))
    }

    func replaceSelection(with insertedText: String) {
        self.performEdit { [self] in
            let range = self.selectionRange
            let start = self.index(forOffset: range.lowerBound)
            let end = self.index(forOffset: range.upperBound)

            var newText = self.text
            newText.replaceSubrange(start..<end, with: insertedText)
            guard newText != self.text || self.hasSelection else {
                return false
            }

            self.text = newText
            self.invalidateTextCaches()
            let newOffset = range.lowerBound + insertedText.count
            self.selectionAnchor = newOffset
            self.selectionHead = newOffset
            return true
        }
    }

    func deleteBackward() {
        if self.hasSelection {
            self.replaceSelection(with: "")
            return
        }

        guard self.caretOffset > 0 else {
            return
        }

        self.performEdit { [self] in
            let removeFrom = self.index(forOffset: self.caretOffset - 1)
            let removeTo = self.index(forOffset: self.caretOffset)
            var newText = self.text
            newText.removeSubrange(removeFrom..<removeTo)
            guard newText != self.text else {
                return false
            }

            self.text = newText
            self.invalidateTextCaches()
            let newOffset = self.caretOffset - 1
            self.selectionAnchor = newOffset
            self.selectionHead = newOffset
            return true
        }
    }

    func deleteForward() {
        if self.hasSelection {
            self.replaceSelection(with: "")
            return
        }

        guard self.caretOffset < self.text.count else {
            return
        }

        self.performEdit { [self] in
            let removeFrom = self.index(forOffset: self.caretOffset)
            let removeTo = self.index(forOffset: self.caretOffset + 1)
            var newText = self.text
            newText.removeSubrange(removeFrom..<removeTo)
            guard newText != self.text else {
                return false
            }

            self.text = newText
            self.invalidateTextCaches()
            self.selectionAnchor = self.caretOffset
            self.selectionHead = self.caretOffset
            return true
        }
    }

    func selectAll() {
        self.selectionAnchor = 0
        self.selectionHead = self.text.count
        self.ensureCaretVisibleIfNeeded()
        self.requestDisplay()
    }

    func copySelection() {
        guard self.hasSelection else {
            return
        }
        UIClipboard.setString(self.selectedText())
    }

    func cutSelection() {
        guard self.hasSelection else {
            return
        }
        self.copySelection()
        self.replaceSelection(with: "")
    }

    func pasteText() {
        guard let pasted = UIClipboard.getString(), !pasted.isEmpty else {
            return
        }
        self.insertText(pasted)
    }

    func undo() {
        guard let previous = self.undoStack.popLast() else {
            return
        }

        let current = self.snapshot()
        self.redoStack.append(current)
        self.restore(previous)
    }

    func redo() {
        guard let next = self.redoStack.popLast() else {
            return
        }

        let current = self.snapshot()
        self.undoStack.append(current)
        self.restore(next)
    }

    func performEdit(_ block: () -> Bool) {
        let previous = self.snapshot()
        guard block() else {
            return
        }

        if self.undoStack.last != previous {
            self.undoStack.append(previous)
            if self.undoStack.count > Constants.maxUndoDepth {
                self.undoStack.removeFirst()
            }
        }
        self.redoStack.removeAll(keepingCapacity: true)

        self.preferredColumn = nil
        self.clampSelectionToBounds()
        self.syncBinding()
        self.ensureCaretVisibleIfNeeded()
        self.requestDisplay()
    }

    func restore(_ snapshot: Snapshot) {
        self.text = snapshot.text
        self.invalidateTextCaches()
        self.selectionAnchor = snapshot.selectionAnchor
        self.selectionHead = snapshot.selectionHead
        self.preferredColumn = nil
        self.clampSelectionToBounds()
        self.syncBinding()
        self.ensureCaretVisibleIfNeeded()
        self.requestDisplay()
    }

    func snapshot() -> Snapshot {
        Snapshot(text: self.text, selectionAnchor: self.selectionAnchor, selectionHead: self.selectionHead)
    }

    func selectedText() -> String {
        let range = self.selectionRange
        let start = self.index(forOffset: range.lowerBound)
        let end = self.index(forOffset: range.upperBound)
        return String(self.text[start..<end])
    }

    func selectedSourceRange() -> TextEditorSourceRange {
        let lines = self.lines()
        let range = self.selectionRange
        let start = self.position(forOffset: range.lowerBound, lines: lines)
        let end = self.position(forOffset: range.upperBound, lines: lines)
        return TextEditorSourceRange(
            start: TextEditorSourcePosition(line: start.line, column: start.column),
            end: TextEditorSourcePosition(line: end.line, column: end.column)
        )
    }

    func syncBinding() {
        if self.textBinding.wrappedValue != self.text {
            self.textBinding.wrappedValue = self.text
        }
    }

    func clampSelectionToBounds() {
        let upperBound = self.text.count
        self.selectionAnchor = max(0, min(self.selectionAnchor, upperBound))
        self.selectionHead = max(0, min(self.selectionHead, upperBound))
    }

    func setSelection(to offset: Int) {
        let clamped = max(0, min(offset, self.text.count))
        self.selectionAnchor = clamped
        self.selectionHead = clamped
    }

    func index(forOffset offset: Int) -> String.Index {
        let clamped = max(0, min(offset, self.text.count))
        return self.text.index(self.text.startIndex, offsetBy: clamped)
    }
}
