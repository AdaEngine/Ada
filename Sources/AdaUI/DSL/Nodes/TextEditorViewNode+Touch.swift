//
//  TextEditorViewNode+Touch.swift
//  AdaEngine
//

import AdaInput
import AdaUtils
import Math

extension TextEditorViewNode {
    struct TouchSession {
        enum Mode { case pending, scrolling, selecting }
        var mode: Mode = .pending
        let start: TouchEvent
        let caretOffset: Int
        var latest: TouchEvent
        var heldFor: AdaUtils.TimeInterval = 0
        var handleDrag: TextSelectionHandleDrag?
    }

    static var touchSelectionDelay: AdaUtils.TimeInterval { 0.45 }

    func updateTextEditorFocus(_ isFocused: Bool) {
        self.isFocused = isFocused
        if !isFocused {
            showsTouchSelectionHandles = false
            self.isSelectingWithMouse = false
            if let session = touchSession { cancelScrollForTouch(session.latest) }
            resetTouchSession()
            self.mousePressStartPoint = nil
            self.foldMouseLine = nil
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
        if touch.phase == .began {
            // Keep one stable contact; another finger must not restart selection.
            guard touchSession == nil else {
                return
            }
            let local = convertPointFromRoot(touch.location)
            if let handle = touchSelectionHandles()?.hitTest(local) {
                // Stop any scroll inertia before capturing a selection grip.
                nearestScrollView()?.onTouchesEvent([touch])
                cancelScrollForTouch(touch)
                var session = TouchSession(start: touch, caretOffset: closestOffset(to: local), latest: touch)
                session.mode = .selecting
                session.handleDrag = TextSelectionHandleDrag(handle: handle, range: selectionRange, point: local)
                touchSession = session
                isSelectingWithTouch = true
                clearTapCandidate()
                return
            }
            touchPressStartPoint = touch.location
            foldTouchLine = foldLine(at: local)
            gutterTouchLine = gutterLine(at: local)
            touchSession = TouchSession(start: touch, caretOffset: closestOffset(to: local), latest: touch)
            nearestScrollView()?.onTouchesEvent([touch])
            if foldTouchLine == nil, gutterTouchLine == nil,
               touch.tapCount == 2 || isDoubleTap(at: touch.location, time: touch.time) {
                beginLongPressSelection()
            }
            return
        }
        guard let session = touchSession, session.start.contactID == touch.contactID else {
            return
        }
        touchSession?.latest = touch

        if session.mode == .pending, touch.phase != .cancelled {
            let elapsed = max(session.heldFor, touch.time - session.start.time)
            if elapsed >= Self.touchSelectionDelay {
                beginLongPressSelection()
            } else if !isTap(at: touch.location, start: session.start.location) {
                touchSession?.mode = .scrolling
                clearTapCandidate()
                foldTouchLine = nil
                gutterTouchLine = nil
            }
        }

        switch touchSession?.mode {
        case .scrolling:
            nearestScrollView()?.onTouchesEvent([touch])
        case .selecting:
            if (touch.phase == .moved || touch.phase == .ended),
               session.handleDrag != nil || !isTap(at: touch.location, start: session.start.location) {
                let local = convertPointFromRoot(touch.location)
                if let drag = session.handleDrag {
                    selectionAnchor = drag.fixedOffset
                    selectionHead = drag.movingOffset(closestOffset(to: drag.caretPoint(for: local)), textCount: text.count)
                } else {
                    selectionHead = closestOffset(to: local)
                }
                refreshTouchSelection()
            }
        case .pending:
            if touch.phase == .ended {
                cancelScrollForTouch(touch)
                finishTouchTap(touch)
            } else if touch.phase == .cancelled {
                cancelScrollForTouch(touch)
            }
        case nil: break
        }
        if touch.phase == .ended || touch.phase == .cancelled {
            resetTouchSession()
        }
    }

    /// Recognition uses UI updates as well as event timestamps, so a stationary hold works.
    func advanceTouchHold(_ deltaTime: AdaUtils.TimeInterval) {
        guard touchSession?.mode == .pending, deltaTime.isFinite, deltaTime > 0 else {
            return
        }
        // A resumed application's large frame delta must not turn a new touch into a hold.
        touchSession?.heldFor += min(deltaTime, 0.1)
        if let session = touchSession, session.heldFor >= Self.touchSelectionDelay {
            beginLongPressSelection()
        }
    }

    private func beginLongPressSelection() {
        guard let session = touchSession, session.mode == .pending else {
            return
        }
        cancelScrollForTouch(session.latest)
        touchSession?.mode = .selecting
        isSelectingWithTouch = true
        showsTouchSelectionHandles = true
        foldTouchLine = nil
        gutterTouchLine = nil
        clearTapCandidate()
        owner?.requestFocus(for: self)
        selectWord(at: session.caretOffset)
        refreshTouchSelection()
    }

    private func finishTouchTap(_ touch: TouchEvent) {
        let local = convertPointFromRoot(touch.location)
        if let line = foldTouchLine {
            if foldLine(at: local) == line { toggleFold(at: line) }
            return
        }
        if let line = gutterTouchLine {
            if gutterLine(at: local) == line { sourceInteraction?.onGutterClick?(line) }
            return
        }
        owner?.requestFocus(for: self)
        let offset = closestOffset(to: local)
        setSelection(to: offset)
        showsTouchSelectionHandles = true
        // Compare contacts in root space: revealing the caret can move the editor between taps.
        handleTapCompletion(at: touch.location, time: touch.time, caretOffset: offset)
        refreshTouchSelection()
    }

    private func refreshTouchSelection() {
        preferredColumn = nil
        clampSelectionToBounds()
        notifyCaretChange(requestsCompletion: false)
        ensureCaretVisibleIfNeeded()
        resetCaretBlink()
        requestDisplay()
    }

    private func cancelScrollForTouch(_ touch: TouchEvent) {
        nearestScrollView()?.onTouchesEvent([
            TouchEvent(
                window: touch.window,
                location: touch.location,
                phase: .cancelled,
                time: touch.time,
                contactID: touch.contactID
            )
        ])
    }

    private func resetTouchSession() {
        touchSession = nil
        isSelectingWithTouch = false
        touchPressStartPoint = nil
        foldTouchLine = nil
        gutterTouchLine = nil
    }

    func handleTextEditorMouseLeave() {
        self.updateHoveredGutterLine(nil)
        self.notifySourceHover(nil)
        self.resetSourceCursorIfNeeded()
        self.resetTextCursorIfNeeded()
    }
}
