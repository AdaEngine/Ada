//
//  MetalView+macOS.swift
//  AdaEngine
//
//  Created by v.prusakov on 7/11/22.
//

#if MACOS
    import AdaECS
    @_spi(Internal) import AdaInput
    @_spi(Internal) import AdaUI
    import AdaUtils
    import AppKit
    import Math

    // Platform overrides live here to keep the shared MetalView platform-neutral.
    // swiftlint:disable override_in_extension

    extension MetalView {
        var input: Ref<Input>? {
            self.windowManager?.inputRef
        }

        override public var acceptsFirstResponder: Bool {
            return true
        }

        override public func acceptsFirstMouse(for _: NSEvent?) -> Bool {
            return true
        }

        override public func updateTrackingAreas() {
            if let area = self.currentTrackingArea {
                self.removeTrackingArea(area)
            }

            let options: NSTrackingArea.Options = [.mouseMoved, .mouseEnteredAndExited, .cursorUpdate, .inVisibleRect, .activeAlways]

            let newTrackingArea = NSTrackingArea(rect: self.bounds, options: options, owner: self, userInfo: nil)
            self.addTrackingArea(newTrackingArea)

            self.currentTrackingArea = newTrackingArea

            super.updateTrackingAreas()
        }

        func updateMousePassthroughMonitoring() {
            if let monitor = passthroughLocalMouseMonitor {
                NSEvent.removeMonitor(monitor)
                passthroughLocalMouseMonitor = nil
            }
            if let monitor = passthroughGlobalMouseMonitor {
                NSEvent.removeMonitor(monitor)
                passthroughGlobalMouseMonitor = nil
            }

            guard allowsTransparency, allowsMousePassthrough else {
                self.window?.ignoresMouseEvents = false
                return
            }

            updateMousePassthrough(at: NSEvent.mouseLocation)

            passthroughLocalMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] event in
                self?.updateMousePassthrough(at: NSEvent.mouseLocation)
                return event
            }
            passthroughGlobalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] _ in
                self?.updateMousePassthrough(at: NSEvent.mouseLocation)
            }
        }

        private func updateMousePassthrough(at screenPoint: NSPoint) {
            guard
                allowsTransparency, allowsMousePassthrough,
                let nsWindow = self.window,
                let uiWindow = (windowManager as? MacOSWindowManager)?.findWindow(for: nsWindow),
                uiWindow.canDraw
            else {
                self.window?.ignoresMouseEvents = false
                return
            }

            let pointInWindow = NSPoint(
                x: screenPoint.x - nsWindow.frame.minX,
                y: screenPoint.y - nsWindow.frame.minY
            )
            let localPoint = Point(
                x: Float(pointInWindow.x),
                y: Float(nsWindow.frame.height - pointInWindow.y)
            )
            let hasTarget = hasInteractiveAdaUITarget(at: localPoint, in: uiWindow)
            let wasIgnoringMouseEvents = nsWindow.ignoresMouseEvents

            if hasTarget {
                nsWindow.ignoresMouseEvents = false
                if wasIgnoringMouseEvents {
                    sendSyntheticMouseMoved(at: localPoint, to: uiWindow)
                }
            } else {
                if !wasIgnoringMouseEvents {
                    sendSyntheticMouseMoved(at: localPoint, to: uiWindow)
                }
                nsWindow.ignoresMouseEvents = true
            }
        }

        private func hasInteractiveAdaUITarget(at point: Point, in uiWindow: UIWindow) -> Bool {
            let event = MouseEvent(
                window: self.windowID,
                button: .none,
                mousePosition: point,
                phase: .changed,
                modifierKeys: [],
                time: 0
            )

            for subview in uiWindow.subviews.reversed() {
                let subviewPoint = subview.convert(point, from: uiWindow)
                if subview.hitTest(subviewPoint, with: event) != nil {
                    return true
                }
            }

            return false
        }

        private func sendSyntheticMouseMoved(at point: Point, to uiWindow: UIWindow) {
            let event = MouseEvent(
                window: self.windowID,
                button: .none,
                mousePosition: point,
                phase: .changed,
                modifierKeys: [],
                time: TimeInterval(CFAbsoluteTimeGetCurrent())
            )

            for subview in uiWindow.subviews {
                guard let receiver = subview as? any UIMousePassthroughEventReceiving else {
                    continue
                }
                receiver.uiReceivePassthroughMouseMoved(event)
            }
        }

        override public func touchesBegan(with _: NSEvent) {
        }

        override public func touchesMoved(with _: NSEvent) {
        }

        override public func touchesEnded(with _: NSEvent) {
        }

        override public func touchesCancelled(with _: NSEvent) {
        }

        override public func mouseUp(with event: NSEvent) {
            let position = self.mousePosition(for: event)

            let mouseEvent = MouseEvent(
                window: self.windowID,
                button: .left,
                mousePosition: position,
                phase: .ended,
                modifierKeys: KeyModifier(modifiers: event.modifierFlags),
                time: TimeInterval(event.timestamp)
            )

            input?.mousePosition = position
            input?.wrappedValue.receiveEvent(mouseEvent)
        }

        override open func cursorUpdate(with _: NSEvent) {
            Application.shared.windowManager.updateCursor()
        }

        override public func mouseDown(with event: NSEvent) {
            if let eventWindow = event.window, eventWindow.firstResponder !== self {
                eventWindow.makeFirstResponder(self)
            }

            let position = self.mousePosition(for: event)
            if shouldPerformWindowDrag(at: position, with: event) {
                event.window?.performDrag(with: event)
                return
            }

            let isContinious = input?.wrappedValue.mouseEvents[.left]?.phase == .began

            let mouseEvent = MouseEvent(
                window: self.windowID,
                button: .left,
                mousePosition: position,
                phase: isContinious ? .changed : .began,
                modifierKeys: KeyModifier(modifiers: event.modifierFlags),
                time: TimeInterval(event.timestamp)
            )

            input?.mousePosition = position
            input?.wrappedValue.receiveEvent(mouseEvent)
        }

        override public func rightMouseDown(with event: NSEvent) {
            if let eventWindow = event.window, eventWindow.firstResponder !== self {
                eventWindow.makeFirstResponder(self)
            }

            let position = self.mousePosition(for: event)

            let isContinious = input?.wrappedValue.mouseEvents[.right]?.phase == .began

            let mouseEvent = MouseEvent(
                window: self.windowID,
                button: .right,
                mousePosition: position,
                phase: isContinious ? .changed : .began,
                modifierKeys: KeyModifier(modifiers: event.modifierFlags),
                time: TimeInterval(event.timestamp)
            )

            input?.mousePosition = position
            input?.wrappedValue.receiveEvent(mouseEvent)
        }

        override public func rightMouseUp(with event: NSEvent) {
            let position = self.mousePosition(for: event)

            let mouseEvent = MouseEvent(
                window: self.windowID,
                button: .right,
                mousePosition: position,
                phase: .ended,
                modifierKeys: KeyModifier(modifiers: event.modifierFlags),
                time: TimeInterval(event.timestamp)
            )

            input?.mousePosition = position
            input?.wrappedValue.receiveEvent(mouseEvent)
        }

        override public func otherMouseDown(with event: NSEvent) {
            guard event.buttonNumber == 2 else {
                super.otherMouseDown(with: event)
                return
            }

            if let eventWindow = event.window, eventWindow.firstResponder !== self {
                eventWindow.makeFirstResponder(self)
            }

            let position = self.mousePosition(for: event)
            let isContinuous = input?.wrappedValue.mouseEvents[.middle]?.phase == .began
            let mouseEvent = MouseEvent(
                window: self.windowID,
                button: .middle,
                mousePosition: position,
                phase: isContinuous ? .changed : .began,
                modifierKeys: KeyModifier(modifiers: event.modifierFlags),
                time: TimeInterval(event.timestamp)
            )

            input?.mousePosition = position
            input?.wrappedValue.receiveEvent(mouseEvent)
        }

        override public func otherMouseUp(with event: NSEvent) {
            guard event.buttonNumber == 2 else {
                super.otherMouseUp(with: event)
                return
            }

            let position = self.mousePosition(for: event)
            let mouseEvent = MouseEvent(
                window: self.windowID,
                button: .middle,
                mousePosition: position,
                phase: .ended,
                modifierKeys: KeyModifier(modifiers: event.modifierFlags),
                time: TimeInterval(event.timestamp)
            )

            input?.mousePosition = position
            input?.wrappedValue.receiveEvent(mouseEvent)
        }

        override public func otherMouseDragged(with event: NSEvent) {
            guard event.buttonNumber == 2 else {
                super.otherMouseDragged(with: event)
                return
            }

            let position = self.mousePosition(for: event)
            let mouseEvent = MouseEvent(
                window: self.windowID,
                button: .middle,
                mousePosition: position,
                phase: .changed,
                modifierKeys: KeyModifier(modifiers: event.modifierFlags),
                time: TimeInterval(event.timestamp)
            )

            input?.mousePosition = position
            input?.wrappedValue.receiveEvent(mouseEvent)
        }

        override public func mouseMoved(with event: NSEvent) {
            let position = self.mousePosition(for: event)
            input?.mousePosition = position

            let event = MouseEvent(
                window: self.windowID,
                button: .none,
                mousePosition: position,
                phase: .changed,
                modifierKeys: KeyModifier(modifiers: event.modifierFlags),
                time: TimeInterval(event.timestamp)
            )
            input?.wrappedValue.receiveEvent(event)
        }

        override open func mouseDragged(with event: NSEvent) {
            let position = self.mousePosition(for: event)
            input?.mousePosition = position

            let event = MouseEvent(
                window: self.windowID,
                button: .left,
                mousePosition: position,
                phase: .changed,
                modifierKeys: KeyModifier(modifiers: event.modifierFlags),
                time: TimeInterval(event.timestamp)
            )
            input?.wrappedValue.receiveEvent(event)
        }

        override open func rightMouseDragged(with event: NSEvent) {
            let position = self.mousePosition(for: event)
            input?.mousePosition = position

            let event = MouseEvent(
                window: self.windowID,
                button: .right,
                mousePosition: position,
                phase: .changed,
                modifierKeys: KeyModifier(modifiers: event.modifierFlags),
                time: TimeInterval(event.timestamp)
            )
            input?.wrappedValue.receiveEvent(event)
        }

        override public func magnify(with event: NSEvent) {
            let phase: PinchEvent.Phase
            if event.phase.contains(.began) {
                pinchScale = 1
                phase = .began
            } else if event.phase.contains(.cancelled) {
                phase = .cancelled
            } else if event.phase.contains(.ended) {
                phase = .ended
            } else {
                phase = .changed
            }
            pinchScale *= max(0.01, 1 + Float(event.magnification))
            input?.wrappedValue
                .receiveEvent(
                    PinchEvent(
                        window: windowID,
                        location: mousePosition(for: event),
                        scale: pinchScale,
                        phase: phase,
                        time: TimeInterval(event.timestamp)
                    )
                )
        }

        override public func scrollWheel(with event: NSEvent) {
            var deltaX = Float(event.scrollingDeltaX)
            var deltaY = Float(event.scrollingDeltaY)
            let phase =
                if event.phase.isEmpty && event.momentumPhase.isEmpty {
                    MouseEvent.Phase.changed
                } else {
                    self.inputPhase(from: event.phase.isEmpty ? event.momentumPhase : event.phase)
                }

            if event.hasPreciseScrollingDeltas {
                deltaX *= 0.03
                deltaY *= 0.03
            }

            let mouseEvent = MouseEvent(
                window: self.windowID,
                button: .scrollWheel,
                scrollDelta: Point(x: deltaX, y: deltaY),
                mousePosition: self.mousePosition(for: event),
                phase: phase,
                modifierKeys: KeyModifier(modifiers: event.modifierFlags),
                time: TimeInterval(event.timestamp)
            )

            input?.wrappedValue.receiveEvent(mouseEvent)
        }

        override public func keyUp(with event: NSEvent) {
            let keyCode = MacOSKeyboard.shared.translateKey(from: event.keyCode)
            let modifers = KeyModifier(modifiers: event.modifierFlags)

            let keyEvent = KeyEvent(
                window: self.windowID,
                keyCode: keyCode,
                modifiers: modifers,
                status: .up,
                time: TimeInterval(event.timestamp),
                isRepeated: event.isARepeat
            )

            input?.wrappedValue.receiveEvent(keyEvent)
        }

        override public func keyDown(with event: NSEvent) {
            let keyCode = MacOSKeyboard.shared.translateKey(from: event.keyCode)
            let modifers = KeyModifier(modifiers: event.modifierFlags)

            let keyEvent = KeyEvent(
                window: self.windowID,
                keyCode: keyCode,
                modifiers: modifers,
                status: .down,
                time: TimeInterval(event.timestamp),
                isRepeated: event.isARepeat
            )

            input?.wrappedValue.receiveEvent(keyEvent)

            guard
                let insertedText = event.characters,
                let payload = AppleHardwareTextInput.payload(
                    keyCode: keyCode,
                    modifiers: modifers,
                    characters: insertedText
                )
            else {
                return
            }

            let textEvent = TextInputEvent(
                window: self.windowID,
                text: payload.text,
                action: payload.action,
                time: TimeInterval(event.timestamp)
            )

            input?.wrappedValue.receiveEvent(textEvent)
        }

        // MARK: - Private

        @discardableResult
        private func mousePosition(for event: NSEvent) -> Vector2 {
            let x = Float(event.locationInWindow.x)
            let y = Float(self.frame.size.height - event.locationInWindow.y)

            let position = Point(x, y)

            return position
        }

        private func shouldPerformWindowDrag(at position: Point, with event: NSEvent) -> Bool {
            guard
                event.clickCount == 1,
                let nsWindow = event.window,
                nsWindow.styleMask.contains(.fullSizeContentView),
                let uiWindow = (windowManager as? MacOSWindowManager)?.findWindow(for: nsWindow)
            else {
                return false
            }

            let systemTitleBarHeight = Float(max(0, nsWindow.frame.height - nsWindow.contentLayoutRect.height))
            let dragRegionHeight = uiWindow.configuration.titleBar.dragRegionHeight ?? systemTitleBarHeight
            guard dragRegionHeight > 0, position.y <= dragRegionHeight else {
                return false
            }

            return allowsWindowDrag(at: position, in: uiWindow)
        }

        private func allowsWindowDrag(at point: Point, in uiWindow: UIWindow) -> Bool {
            let event = MouseEvent(
                window: self.windowID,
                button: .left,
                mousePosition: point,
                phase: .began,
                modifierKeys: [],
                time: 0
            )

            for subview in uiWindow.subviews.reversed() {
                let subviewPoint = subview.convert(point, from: uiWindow)
                if let resolver = subview as? any UIWindowDragRegionResolving {
                    if !resolver.uiAllowsWindowDrag(at: point, with: event) {
                        return false
                    }
                    continue
                }
                if subview.hitTest(subviewPoint, with: event) != nil {
                    return false
                }
            }

            return true
        }

        private func inputPhase(from phase: NSEvent.Phase) -> MouseEvent.Phase {
            switch phase {
            case .mayBegin: return .began
            case .began: return .began
            case .cancelled: return .cancelled
            case .ended: return .ended
            case .changed: return .changed
            default:
                return .ended
            }
        }

        static func textInputPayload(
            keyCode: KeyCode,
            modifiers: KeyModifier,
            characters: String
        ) -> String? {
            guard
                let payload = AppleHardwareTextInput.payload(
                    keyCode: keyCode,
                    modifiers: modifiers,
                    characters: characters
                ), payload.action == .insert
            else {
                return nil
            }
            return payload.text
        }
    }

    // swiftlint:enable override_in_extension
#endif
