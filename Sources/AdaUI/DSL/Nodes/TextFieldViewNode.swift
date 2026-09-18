//
//  TextFieldViewNode.swift
//  AdaEngine
//
//  Created by Codex on 19.02.2026.
//

import AdaInput
import AdaRender
import AdaText
import AdaUtils
import Foundation
import Math

final class TextFieldViewNode: ViewNode {
    private struct Snapshot: Equatable {
        let text: String
        let selectionAnchor: Int
        let selectionHead: Int
    }

    enum Constants {
        static let horizontalInset: Float = 8
        static let verticalInset: Float = 6
        static let minimumWidth: Float = 140
        static let minimumHeight: Float = 30
        static let placeholderOpacity: Float = 0.8
        static let selectionOpacity: Float = 0.25
        static let maxUndoDepth: Int = 128
        static let caretPadding: Float = 0
        static let minimumCaretHeight: Float = 15
        static let caretLineWidth: Float = 2.5
        static let caretBlinkInterval: AdaUtils.TimeInterval = 1.15
        static let tapMovementToleranceSquared: Float = 36
        static let doubleTapMovementToleranceSquared: Float = 100
        static let doubleTapMaxInterval: AdaUtils.TimeInterval = 0.35

        static let backgroundColor = Color.fromHex(0xF5F5F5)
        static let borderColor = Color.fromHex(0x969696)
        static let focusedBorderColor = Color.fromHex(0x2D7EFF)
    }

    private var placeholder: String
    private var onSubmit: (() -> Void)?
    private var textBinding: Binding<String>

    var text: String
    private var textLayout: TextLayoutManager?

    private var isFocused: Bool = false
    private var isSelectingWithMouse: Bool = false
    private var isSelectingWithTouch: Bool = false
    private var horizontalOffset: Float = 0
    private var wrapsTextToWidth: Bool = false
    private var caretVisible: Bool = true
    private var caretBlinkElapsed: AdaUtils.TimeInterval = 0
    private var mousePressStartPoint: Point?
    private var touchPressStartPoint: Point?
    var lastTapTime: AdaUtils.TimeInterval?
    var lastTapPosition: Point?

    var selectionAnchor: Int = 0
    var selectionHead: Int = 0

    private var undoStack: [Snapshot] = []
    private var redoStack: [Snapshot] = []

    init(inputs: _ViewInputs, content: TextField) {
        self.placeholder = content.placeholder
        self.onSubmit = content.onSubmit
        self.textBinding = content.text
        self.text = Self.normalizeInputText(content.text.wrappedValue)
        super.init(content: content)
        self.updateEnvironment(inputs.environment)
        self.clampSelectionToBounds()
    }

    override var canBecomeFocused: Bool {
        true
    }

    override func sizeThatFits(_ proposal: ProposedViewSize) -> Size {
        let pointSize = self.resolvedFontPointSize()
        let maxCharacterCount = max(self.text.count, self.placeholder.count, 1)
        let measuredWidth = Float(maxCharacterCount) * self.characterAdvance(for: pointSize)
        let measuredHeight = pointSize * 1.2
        let hasFixedWidth = proposal.width.map { $0 != .infinity } ?? false
        let hasFixedHeight = proposal.height.map { $0 != .infinity } ?? false
        self.wrapsTextToWidth = hasFixedWidth && !hasFixedHeight

        let ideal = Size(
            width: max(Constants.minimumWidth, measuredWidth + Constants.horizontalInset * 2),
            height: max(Constants.minimumHeight, measuredHeight + Constants.verticalInset * 2)
        )

        var result = proposal.replacingUnspecifiedDimensions(by: ideal)
        if result.width == .infinity {
            result.width = ideal.width
        }
        if result.height == .infinity {
            result.height = ideal.height
        }

        if self.wrapsTextToWidth {
            let contentWidth = max(1, result.width - Constants.horizontalInset * 2)
            let wrappedLines = max(1, Int(ceil(measuredWidth / contentWidth)))
            let wrappedHeight = Float(wrappedLines) * measuredHeight + Constants.verticalInset * 2
            result.height = max(result.height, max(Constants.minimumHeight, wrappedHeight))
        }

        return result
    }

    override func update(from newNode: ViewNode) {
        super.update(from: newNode)

        guard let node = newNode as? TextFieldViewNode else {
            return
        }

        self.placeholder = node.placeholder
        self.onSubmit = node.onSubmit
        self.textBinding = node.textBinding

        let externalText = Self.normalizeInputText(node.textBinding.wrappedValue)
        if externalText != self.text {
            self.text = externalText
            self.undoStack.removeAll(keepingCapacity: true)
            self.redoStack.removeAll(keepingCapacity: true)
        }

        self.clampSelectionToBounds()
        self.ensureCaretVisibleIfNeeded()
        self.requestDisplay()
    }

    override func hitTest(_ point: Point, with event: any InputEvent) -> ViewNode? {
        guard self.point(inside: point, with: event) else {
            return nil
        }
        return self
    }

    override func onFocusChanged(isFocused: Bool) {
        self.isFocused = isFocused
        if !isFocused {
            self.isSelectingWithMouse = false
            self.isSelectingWithTouch = false
            self.mousePressStartPoint = nil
            self.touchPressStartPoint = nil
            self.clearTapCandidate()
            #if canImport(UIKit)
                self.hideEditMenu()
            #endif
        }
        self.caretVisible = isFocused
        self.caretBlinkElapsed = 0
        self.owner?.window?.windowManager.textInputFocusDidChange(isFocused)
        self.requestDisplay()
    }

    override func onMouseEvent(_ event: MouseEvent) {
        self.owner?.window?.windowManager.setCursorShape(.iBeam)

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
        let contentRect = self.textContentRect()
        let pointSize = self.resolvedFontPointSize()
        self.refreshInteractiveTextLayoutIfPossible(size: contentRect.size)
        let horizontalOffset = self.wrapsTextToWidth ? 0 : self.horizontalOffset
        let textX = localPoint.x - contentRect.origin.x + horizontalOffset
        let caretOffset = self.closestOffset(for: textX, pointSize: pointSize)

        switch event.phase {
        case .began:
            self.isSelectingWithMouse = true
            self.mousePressStartPoint = localPoint
            if event.modifierKeys.contains(.shift), self.isFocused {
                self.selectionHead = caretOffset
                self.clampSelectionToBounds()
            } else {
                self.setSelection(to: caretOffset)
            }
            self.ensureCaretVisibleIfNeeded()
            self.requestDisplay()
        case .changed:
            guard self.isSelectingWithMouse else {
                return
            }
            self.selectionHead = caretOffset
            self.clampSelectionToBounds()
            self.ensureCaretVisibleIfNeeded()
            self.requestDisplay()
        case .ended,
            .cancelled:
            self.isSelectingWithMouse = false
            self.selectionHead = caretOffset
            self.clampSelectionToBounds()
            self.ensureCaretVisibleIfNeeded()
            self.requestDisplay()

            if event.phase == .ended, self.isTap(at: localPoint, start: self.mousePressStartPoint) {
                self.handleTapCompletion(at: localPoint, time: event.time, caretOffset: caretOffset)
            } else {
                self.clearTapCandidate()
            }
            self.mousePressStartPoint = nil
        }

        self.resetCaretBlink()
    }

    override func onTouchesEvent(_ touches: Set<TouchEvent>) {
        guard let touch = touches.min(by: { $0.time < $1.time }) else {
            return
        }

        let localPoint = self.convertPointFromRoot(touch.location)
        let contentRect = self.textContentRect()
        let pointSize = self.resolvedFontPointSize()
        self.refreshInteractiveTextLayoutIfPossible(size: contentRect.size)
        let horizontalOffset = self.wrapsTextToWidth ? 0 : self.horizontalOffset
        let textX = localPoint.x - contentRect.origin.x + horizontalOffset
        let caretOffset = self.closestOffset(for: textX, pointSize: pointSize)

        switch touch.phase {
        case .began:
            self.isSelectingWithTouch = true
            self.touchPressStartPoint = localPoint
            self.setSelection(to: caretOffset)
            self.ensureCaretVisibleIfNeeded()
            self.requestDisplay()
        case .moved:
            guard self.isSelectingWithTouch else {
                return
            }
            self.selectionHead = caretOffset
            self.clampSelectionToBounds()
            self.ensureCaretVisibleIfNeeded()
            self.requestDisplay()
        case .ended,
            .cancelled:
            self.isSelectingWithTouch = false
            self.selectionHead = caretOffset
            self.clampSelectionToBounds()
            self.ensureCaretVisibleIfNeeded()
            self.requestDisplay()

            if touch.phase == .ended, self.isTap(at: localPoint, start: self.touchPressStartPoint) {
                self.handleTapCompletion(at: localPoint, time: touch.time, caretOffset: caretOffset)
            } else {
                self.clearTapCandidate()
            }
            self.touchPressStartPoint = nil
        }

        self.resetCaretBlink()
    }

    override func onMouseLeave() {
        self.owner?.window?.windowManager.setCursorShape(.arrow)
    }

    override func onTextInputEvent(_ event: TextInputEvent) {
        guard self.isFocused else {
            return
        }

        self.resetCaretBlink()

        switch event.action {
        case .insert:
            self.insertText(event.text)
        case .deleteBackward:
            self.deleteBackward()
        }
    }

    override func onKeyEvent(_ event: KeyEvent) {
        guard self.isFocused, event.status == .down else {
            return
        }

        if self.handleShortcut(event) {
            self.resetCaretBlink()
            return
        }

        let extendSelection = event.modifiers.contains(.shift)
        let movesByWordBoundary = event.modifiers.contains(.main)
        switch event.keyCode {
        case .enter:
            self.onSubmit?()
        case .arrowLeft:
            if movesByWordBoundary {
                self.moveCaretByWordBoundary(direction: -1, extendSelection: extendSelection)
            } else {
                self.moveCaret(delta: -1, extendSelection: extendSelection)
            }
        case .arrowRight:
            if movesByWordBoundary {
                self.moveCaretByWordBoundary(direction: 1, extendSelection: extendSelection)
            } else {
                self.moveCaret(delta: 1, extendSelection: extendSelection)
            }
        case .home,
            .pageUp:
            self.moveCaretToStart(extendSelection: extendSelection)
        case .pageDown:
            self.moveCaretToEnd(extendSelection: extendSelection)
        case .delete:
            self.deleteForward()
        default:
            return
        }

        self.resetCaretBlink()
    }

    override func update(_ deltaTime: AdaUtils.TimeInterval) {
        // Closure bindings can change without rebuilding the owning view (for example,
        // live editor values). Refresh only this field and preserve local edits/undo
        // when the binding already matches the displayed text.
        let boundText = textBinding.wrappedValue
        if boundText != text {
            let externalText = Self.normalizeInputText(boundText)
            if externalText != text {
                text = externalText
                undoStack.removeAll(keepingCapacity: true)
                redoStack.removeAll(keepingCapacity: true)
                clampSelectionToBounds()
                ensureCaretVisibleIfNeeded()
                requestDisplay()
            }
        }
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
        let borderColor = self.isFocused ? Constants.focusedBorderColor : Constants.borderColor

        context.translateBy(x: self.frame.origin.x, y: -self.frame.origin.y)

        if self.environment._textFieldDrawsBackground {
            context.drawRect(bounds, color: Constants.backgroundColor)
            self.drawBorder(in: &context, rect: bounds, color: borderColor)
        }

        let contentRect = self.textContentRect()
        guard contentRect.width > 0, contentRect.height > 0 else {
            return
        }
        let clipRect = self.visualAbsoluteContentRect()

        let pointSize = self.resolvedFontPointSize()
        let textColor = self.resolvedTextColor()

        let hasUserText = !self.text.isEmpty
        let renderedText = hasUserText || self.isFocused ? self.text : self.placeholder
        let renderedColor = hasUserText || self.isFocused ? textColor : textColor.opacity(Constants.placeholderOpacity)
        let resolvedFont = self.resolvedFontForRendering()
        if let resolvedFont {
            let layoutSize = self.wrapsTextToWidth ? contentRect.size : Size(width: .infinity, height: contentRect.height)
            self.updateTextLayout(text: renderedText, font: resolvedFont, color: renderedColor, size: layoutSize)
        }
        self.ensureCaretVisible(availableWidth: contentRect.width, pointSize: pointSize)

        context.clip(to: clipRect) { clipped in
            var clipped = clipped
            clipped.translateBy(x: contentRect.origin.x, y: -contentRect.origin.y)

            if self.isFocused, self.hasSelection, hasUserText {
                let range = self.selectionRange
                let horizontalOffset = self.wrapsTextToWidth ? 0 : self.horizontalOffset
                let start = self.widthForOffset(range.lowerBound, pointSize: pointSize) - horizontalOffset
                let end = self.widthForOffset(range.upperBound, pointSize: pointSize) - horizontalOffset
                if end > start {
                    clipped.drawRect(
                        Rect(x: start, y: 0, width: end - start, height: contentRect.height),
                        color: self.environment.accentColor.opacity(Constants.selectionOpacity)
                    )
                }
            }

            let verticalOffset = Self.verticalTextOffset(for: self.textLayout, height: contentRect.height)
            let xOffset: Float = hasUserText && !self.wrapsTextToWidth ? -self.horizontalOffset : 0
            clipped.translateBy(x: xOffset, y: verticalOffset)
            if resolvedFont != nil {
                self.drawText(using: &clipped)
            }

            if self.isFocused, self.caretVisible, !self.hasSelection {
                let caretX = self.widthForOffset(self.selectionHead, pointSize: pointSize)
                let caretRange = self.caretVerticalRange(contentHeight: contentRect.height)
                let caretHeight = max(0, caretRange.upperBound - caretRange.lowerBound)
                if caretHeight > 0 {
                    let caretWidth = max(1, Constants.caretLineWidth)
                    clipped.drawRect(
                        Rect(
                            x: caretX - caretWidth * 0.5,
                            y: -caretRange.upperBound,
                            width: caretWidth,
                            height: caretHeight
                        ),
                        color: self.environment.accentColor
                    )
                }
            }
        }
    }
}

extension TextFieldViewNode {
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

    func moveCaret(delta: Int, extendSelection: Bool) {
        let characterCount = self.text.count

        if extendSelection {
            let newHead = max(0, min(characterCount, self.caretOffset + delta))
            self.selectionHead = newHead
        } else if self.hasSelection {
            if delta < 0 {
                self.setSelection(to: self.selectionRange.lowerBound)
            } else {
                self.setSelection(to: self.selectionRange.upperBound)
            }
        } else {
            let newOffset = max(0, min(characterCount, self.caretOffset + delta))
            self.setSelection(to: newOffset)
        }

        self.ensureCaretVisibleIfNeeded()
        self.requestDisplay()
    }

    func moveCaretByWordBoundary(direction: Int, extendSelection: Bool) {
        if !extendSelection, self.hasSelection {
            if direction < 0 {
                self.setSelection(to: self.selectionRange.lowerBound)
            } else {
                self.setSelection(to: self.selectionRange.upperBound)
            }
            self.ensureCaretVisibleIfNeeded()
            self.requestDisplay()
            return
        }

        let targetOffset =
            if direction < 0 {
                self.wordBoundaryBefore(offset: self.caretOffset)
            } else {
                self.wordBoundaryAfter(offset: self.caretOffset)
            }

        if extendSelection {
            self.selectionHead = targetOffset
        } else {
            self.setSelection(to: targetOffset)
        }

        self.ensureCaretVisibleIfNeeded()
        self.requestDisplay()
    }

    func moveCaretToStart(extendSelection: Bool) {
        if extendSelection {
            self.selectionHead = 0
        } else {
            self.setSelection(to: 0)
        }
        self.ensureCaretVisibleIfNeeded()
        self.requestDisplay()
    }

    func moveCaretToEnd(extendSelection: Bool) {
        let endOffset = self.text.count
        if extendSelection {
            self.selectionHead = endOffset
        } else {
            self.setSelection(to: endOffset)
        }
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

        let sanitized = Self.normalizeInputText(pasted)
        guard !sanitized.isEmpty else {
            return
        }

        self.replaceSelection(with: sanitized)
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

        self.clampSelectionToBounds()
        self.syncBinding()
        self.ensureCaretVisibleIfNeeded()
        self.requestDisplay()
    }

    private func restore(_ snapshot: Snapshot) {
        self.text = snapshot.text
        self.selectionAnchor = snapshot.selectionAnchor
        self.selectionHead = snapshot.selectionHead
        self.clampSelectionToBounds()
        self.syncBinding()
        self.ensureCaretVisibleIfNeeded()
        self.requestDisplay()
    }

    private func snapshot() -> Snapshot {
        Snapshot(
            text: self.text,
            selectionAnchor: self.selectionAnchor,
            selectionHead: self.selectionHead
        )
    }

    func selectedText() -> String {
        let range = self.selectionRange
        let start = self.index(forOffset: range.lowerBound)
        let end = self.index(forOffset: range.upperBound)
        return String(self.text[start..<end])
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

    func ensureCaretVisibleIfNeeded() {
        let contentRect = self.textContentRect()
        let pointSize = self.resolvedFontPointSize()
        self.refreshInteractiveTextLayoutIfPossible(size: contentRect.size)
        self.ensureCaretVisible(availableWidth: contentRect.width, pointSize: pointSize)
    }

    func ensureCaretVisible(availableWidth: Float, pointSize: Float) {
        if self.wrapsTextToWidth {
            self.horizontalOffset = 0
            return
        }

        guard availableWidth > 0 else {
            self.horizontalOffset = 0
            return
        }

        let caretX = self.widthForOffset(self.caretOffset, pointSize: pointSize)
        let totalWidth = self.widthForOffset(self.text.count, pointSize: pointSize)

        if caretX < self.horizontalOffset {
            self.horizontalOffset = caretX
        } else if caretX > self.horizontalOffset + availableWidth - Constants.caretPadding {
            self.horizontalOffset = caretX - availableWidth + Constants.caretPadding
        }

        let maxOffset = max(0, totalWidth - availableWidth)
        self.horizontalOffset = max(0, min(self.horizontalOffset, maxOffset))
    }

    func closestOffset(for x: Float, pointSize: Float) -> Int {
        if let caretStops = self.layoutCaretStops(), !caretStops.isEmpty {
            if x <= 0 {
                return 0
            }

            for index in 0..<(caretStops.count - 1) {
                let middle = (caretStops[index] + caretStops[index + 1]) * 0.5
                if x < middle {
                    return self.characterOffset(forScalarOffset: index)
                }
            }

            return self.characterOffset(forScalarOffset: caretStops.count - 1)
        }

        guard !self.text.isEmpty else {
            return 0
        }

        if x <= 0 {
            return 0
        }

        let advance = self.characterAdvance(for: pointSize)
        guard advance > 0 else {
            return 0
        }

        let characterCount = self.text.count
        let maxWidth = Float(characterCount) * advance
        if x >= maxWidth {
            return characterCount
        }

        let rawOffset = Int((x / advance).rounded())
        return max(0, min(rawOffset, characterCount))
    }

    func widthForOffset(_ offset: Int, pointSize: Float) -> Float {
        let clamped = max(0, min(offset, self.text.count))
        if let caretStops = self.layoutCaretStops(), !caretStops.isEmpty {
            let scalarOffset = self.scalarOffset(forCharacterOffset: clamped)
            let safeIndex = max(0, min(scalarOffset, caretStops.count - 1))
            return caretStops[safeIndex]
        }
        return Float(clamped) * self.characterAdvance(for: pointSize)
    }

    func characterAdvance(for pointSize: Float) -> Float {
        max(6, pointSize * 0.55)
    }

    func updateTextLayout(text: String, font: Font, color: Color, size: Size) {
        let layout = self.textLayout ?? TextLayoutManager()
        self.textLayout = layout

        let attributes = self.makeTextAttributes(font: font, color: color)
        var container = TextContainer(
            text: AttributedText(text, attributes: attributes),
            textAlignment: .leading,
            lineBreakMode: .byCharWrapping,
            lineSpacing: 0,
            allowsShaping: false
        )
        container.numberOfLines = self.wrapsTextToWidth ? nil : 1

        layout.setTextContainer(container)
        layout.fitToSize(size)
    }

    func refreshInteractiveTextLayoutIfPossible(size: Size) {
        guard size.width > 0, size.height > 0, let font = self.resolvedFontForRendering() else {
            return
        }

        let layoutSize = self.wrapsTextToWidth ? size : Size(width: .infinity, height: size.height)
        self.updateTextLayout(
            text: self.text,
            font: font,
            color: self.resolvedTextColor(),
            size: layoutSize
        )
    }

    func layoutCaretStops() -> [Float]? {
        guard let textLayout else {
            return nil
        }

        var glyphs: [Glyph] = []
        glyphs.reserveCapacity(self.text.unicodeScalars.count)

        for line in textLayout.textLines {
            for run in line {
                glyphs.append(contentsOf: run)
            }
        }

        if glyphs.isEmpty {
            return [0]
        }

        var stops: [Float] = [0]
        stops.reserveCapacity(glyphs.count + 1)

        for glyph in glyphs {
            stops.append(max(stops.last ?? 0, glyph.advanceX))
        }

        return stops
    }

    func scalarOffset(forCharacterOffset offset: Int) -> Int {
        let clamped = max(0, min(offset, self.text.count))
        if clamped == 0 {
            return 0
        }

        let index = self.text.index(self.text.startIndex, offsetBy: clamped)
        return self.text[..<index].unicodeScalars.count
    }

    func characterOffset(forScalarOffset offset: Int) -> Int {
        let clamped = max(0, min(offset, self.text.unicodeScalars.count))
        if clamped == 0 {
            return 0
        }

        var scalarCount = 0
        var characterCount = 0

        for character in self.text {
            let count = character.unicodeScalars.count
            if scalarCount + count > clamped {
                break
            }

            scalarCount += count
            characterCount += 1
            if scalarCount == clamped {
                break
            }
        }

        return characterCount
    }

    func makeTextAttributes(font: Font, color: Color) -> TextAttributeContainer {
        var attributes = TextAttributeContainer()
        attributes.font = font
        attributes.foregroundColor = color
        return attributes
    }

    func drawText(using context: inout UIGraphicsContext) {
        guard let textLayout else {
            return
        }

        for line in textLayout.textLines {
            for run in line {
                for glyph in run {
                    context.draw(glyph)
                }
            }
        }
    }

    func drawBorder(in context: inout UIGraphicsContext, rect: Rect, color: Color) {
        let topLeft = Point(rect.minX, -rect.minY)
        let topRight = Point(rect.maxX, -rect.minY)
        let bottomLeft = Point(rect.minX, -rect.maxY)
        let bottomRight = Point(rect.maxX, -rect.maxY)

        context.drawLine(start: topLeft, end: topRight, lineWidth: 1, color: color)
        context.drawLine(start: topLeft, end: bottomLeft, lineWidth: 1, color: color)
        context.drawLine(start: topRight, end: bottomRight, lineWidth: 1, color: color)
        context.drawLine(start: bottomLeft, end: bottomRight, lineWidth: 1, color: color)
    }

    func textContentRect() -> Rect {
        Rect(
            x: Constants.horizontalInset,
            y: Constants.verticalInset,
            width: max(0, self.frame.width - Constants.horizontalInset * 2),
            height: max(0, self.frame.height - Constants.verticalInset * 2)
        )
    }

    func absoluteContentRect() -> Rect {
        let absoluteFrame = self.absoluteFrame()
        return Rect(
            x: absoluteFrame.origin.x + Constants.horizontalInset,
            y: absoluteFrame.origin.y + Constants.verticalInset,
            width: max(0, absoluteFrame.width - Constants.horizontalInset * 2),
            height: max(0, absoluteFrame.height - Constants.verticalInset * 2)
        )
    }

    func visualAbsoluteContentRect() -> Rect {
        let absoluteFrame = self.visualAbsoluteFrame()
        return Rect(
            x: absoluteFrame.origin.x + Constants.horizontalInset,
            y: absoluteFrame.origin.y + Constants.verticalInset,
            width: max(0, self.frame.width - Constants.horizontalInset * 2),
            height: max(0, self.frame.height - Constants.verticalInset * 2)
        )
    }

    func convertPointToRoot(_ point: Point) -> Point {
        var convertedPoint = point
        var node: ViewNode? = self

        while let current = node {
            convertedPoint = current.convert(convertedPoint, to: current.parent)
            node = current.parent
        }

        return convertedPoint
    }

    func convertPointFromRoot(_ point: Point) -> Point {
        var convertedPoint = point
        var node: ViewNode = self

        while let parent = node.parent {
            convertedPoint = node.convert(convertedPoint, from: parent)
            node = parent
        }

        return convertedPoint
    }

    func requestDisplay() {
        self.invalidateNearestLayer()
        self.owner?.containerView?.setNeedsDisplay(in: self.absoluteFrame())
    }

    func resetCaretBlink() {
        self.caretBlinkElapsed = 0
        if !self.caretVisible {
            self.caretVisible = true
            self.requestDisplay()
        }
    }

    func resolvedFontPointSize() -> Float {
        if let font = self.environment.font {
            return Float(font.pointSize)
        }

        return 17
    }

    func resolvedFontForRendering() -> Font? {
        if let font = self.environment.font {
            return font
        }

        if unsafe RenderEngine.shared != nil {
            return .system(size: 17)
        }

        return nil
    }

    func resolvedTextColor() -> Color {
        self.environment.foregroundColor ?? .black
    }

    static func normalizeInputText(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }

    static func verticalTextOffset(for layout: TextLayoutManager?, height: Float) -> Float {
        guard let layout, !layout.textLines.isEmpty else {
            return 0
        }

        var maxTopY: Float = -.infinity
        var minBottomY: Float = .infinity

        for line in layout.textLines {
            for run in line {
                for glyph in run {
                    maxTopY = max(maxTopY, glyph.position.w)
                    minBottomY = min(minBottomY, glyph.position.y)
                }
            }
        }

        let textCenterY = (maxTopY + minBottomY) / 2
        let frameCenterY = -height / 2
        return frameCenterY - textCenterY
    }

    func caretVerticalRange(contentHeight: Float) -> ClosedRange<Float> {
        guard let textLayout, !textLayout.textLines.isEmpty else {
            return -contentHeight...0
        }

        var maxTopY: Float = -.infinity
        var minBottomY: Float = .infinity

        for line in textLayout.textLines {
            for run in line {
                for glyph in run {
                    maxTopY = max(maxTopY, glyph.position.w)
                    minBottomY = min(minBottomY, glyph.position.y)
                }
            }
        }

        guard maxTopY.isFinite, minBottomY.isFinite, maxTopY > minBottomY else {
            return -contentHeight...0
        }

        var top = maxTopY
        var bottom = minBottomY
        let height = top - bottom
        if height < Constants.minimumCaretHeight {
            let extra = (Constants.minimumCaretHeight - height) * 0.5
            top += extra
            bottom -= extra
        }

        return bottom...top
    }
}

#if canImport(UIKit)
    import UIKit

    extension TextFieldViewNode {
        func showEditMenu(at position: Point) {
            guard
                let windowScene = UIApplication.shared.connectedScenes.first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene,
                let window = windowScene.windows.first(where: { $0.isKeyWindow }),
                let view = window.rootViewController?.view
            else {
                return
            }

            let rootPoint = self.convertPointToRoot(position)
            let cgRect = CGRect(x: CGFloat(rootPoint.x), y: CGFloat(rootPoint.y), width: 1, height: 1)
            UIMenuController.shared.showMenu(from: view, rect: cgRect)
        }

        func hideEditMenu() {
            UIMenuController.shared.hideMenu()
            UIMenuController.shared.setMenuVisible(false, animated: true)
        }
    }
#endif
