//
//  TextEditorViewNode+Touch.swift
//  AdaEngine
//

import AdaInput
import AdaUtils
import Math

extension TextEditorViewNode {
    func updateTextEditorFocus(_ isFocused: Bool) {
        self.isFocused = isFocused
        if !isFocused {
            self.isSelectingWithMouse = false
            self.isSelectingWithTouch = false
            self.mousePressStartPoint = nil
            self.touchPressStartPoint = nil
            self.foldMouseLine = nil
            self.foldTouchLine = nil
            self.clearTapCandidate()
        }
        self.caretVisible = isFocused
        self.caretBlinkElapsed = 0
        self.owner?.window?.windowManager.textInputFocusDidChange(isFocused)
        self.requestDisplay()
    }

    func handleTextEditorTouches(_ touches: Set<TouchEvent>) {
        guard let touch = touches.min(by: { $0.time < $1.time }) else {
            return
        }

        let localPoint = self.convertPointFromRoot(touch.location)
        if touch.phase == .began, let line = self.foldLine(at: localPoint) {
            self.foldTouchLine = line
            return
        }
        if let line = self.foldTouchLine {
            if touch.phase == .ended, self.foldLine(at: localPoint) == line {
                self.toggleFold(at: line)
            }
            if touch.phase == .ended || touch.phase == .cancelled {
                self.foldTouchLine = nil
            }
            return
        }
        if touch.phase == .began, let line = gutterLine(at: localPoint) {
            gutterTouchLine = line
            return
        }
        if let line = gutterTouchLine {
            if touch.phase == .ended {
                if gutterLine(at: localPoint) == line {
                    sourceInteraction?.onGutterClick?(line)
                }
                gutterTouchLine = nil
            } else if touch.phase == .cancelled {
                gutterTouchLine = nil
            }
            return
        }
        let caretOffset = self.closestOffset(to: localPoint)
        self.updateTouchSelection(
            phase: touch.phase,
            localPoint: localPoint,
            time: touch.time,
            caretOffset: caretOffset
        )
    }

    func handleTextEditorMouseLeave() {
        self.updateHoveredGutterLine(nil)
        self.notifySourceHover(nil)
        self.resetSourceCursorIfNeeded()
        self.resetTextCursorIfNeeded()
    }

    private func updateTouchSelection(
        phase: TouchEvent.Phase,
        localPoint: Point,
        time: AdaUtils.TimeInterval,
        caretOffset: Int
    ) {
        switch phase {
        case .began:
            self.isSelectingWithTouch = true
            self.touchPressStartPoint = localPoint
            self.setSelection(to: caretOffset)
        case .moved:
            guard self.isSelectingWithTouch else {
                return
            }
            self.selectionHead = caretOffset
        case .ended,
            .cancelled:
            self.finishTouchSelection(
                phase: phase,
                localPoint: localPoint,
                time: time,
                caretOffset: caretOffset
            )
        }

        self.preferredColumn = nil
        self.clampSelectionToBounds()
        self.notifyCaretChange(requestsCompletion: false)
        self.ensureCaretVisibleIfNeeded()
        self.resetCaretBlink()
        self.requestDisplay()
    }

    private func finishTouchSelection(
        phase: TouchEvent.Phase,
        localPoint: Point,
        time: AdaUtils.TimeInterval,
        caretOffset: Int
    ) {
        self.isSelectingWithTouch = false
        if !self.isTap(at: localPoint, start: self.touchPressStartPoint) {
            self.selectionHead = caretOffset
            self.clearTapCandidate()
        } else if phase == .ended {
            self.handleTapCompletion(at: localPoint, time: time, caretOffset: caretOffset)
        }
        self.touchPressStartPoint = nil
    }
}
