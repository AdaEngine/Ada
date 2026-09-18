//
//  MetalView+iOS.swift
//  AdaEngine
//
//  Created by v.prusakov on 7/11/22.
//

#if os(iOS) || os(visionOS)
    import AdaECS
    @_spi(Internal) import AdaInput
    @_spi(Internal) import AdaUI
    import AdaUtils
    import Math
    import UIKit

    // Platform overrides live here to keep the shared MetalView platform-neutral.
    // swiftlint:disable override_in_extension

    extension MetalView: UIKeyInput {
        public var hasText: Bool {
            // Return true to indicate that we can accept text input
            return true
        }

        public func insertText(_ text: String) {
            let textEvent = TextInputEvent(
                window: self.windowID,
                text: text,
                action: .insert,
                time: TimeInterval(CACurrentMediaTime())
            )

            input?.wrappedValue.receiveEvent(textEvent)
        }

        public func deleteBackward() {
            let textEvent = TextInputEvent(
                window: self.windowID,
                text: "",
                action: .deleteBackward,
                time: TimeInterval(CACurrentMediaTime())
            )

            input?.wrappedValue.receiveEvent(textEvent)
        }
    }

    extension MetalView {
        @objc func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
            let phase: PinchEvent.Phase
            switch recognizer.state {
            case .began: phase = .began
            case .changed: phase = .changed
            case .ended: phase = .ended
            case .cancelled,
                .failed:
                phase = .cancelled
            default: return
            }
            let location = recognizer.location(in: self)
            input?.wrappedValue
                .receiveEvent(
                    PinchEvent(
                        window: windowID,
                        location: Point(x: Float(location.x), y: Float(location.y)),
                        scale: Float(recognizer.scale),
                        phase: phase,
                        time: TimeInterval(CACurrentMediaTime())
                    )
                )
        }

        // MARK: - Input Access

        var input: Ref<Input>? {
            self.windowManager?.inputRef
        }

        // MARK: - First Responder

        override open var canBecomeFirstResponder: Bool {
            return true
        }

        override open func resignFirstResponder() -> Bool {
            UIMenuController.shared.hideMenu()
            return super.resignFirstResponder()
        }

        override open var inputView: UIKit.UIView? {
            showsKeyboard ? nil : UIKit.UIView(frame: .zero)
        }

        public var keyboardType: UIKeyboardType {
            return .default
        }

        public var autocorrectionType: UITextAutocorrectionType {
            return .no
        }

        public var autocapitalizationType: UITextAutocapitalizationType {
            return .none
        }

        // MARK: - Standard Edit Actions

        override open func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
            if action == #selector(copy(_:))
                || action == #selector(paste(_:))
                || action == #selector(cut(_:))
                || action == #selector(selectAll(_:)) {
                return true
            }
            return super.canPerformAction(action, withSender: sender)
        }

        override open func copy(_: Any?) {
            performTextEditingCommand(.copy)
        }

        override open func paste(_: Any?) {
            performTextEditingCommand(.paste)
        }

        override open func cut(_: Any?) {
            performTextEditingCommand(.cut)
        }

        override open func selectAll(_: Any?) {
            performTextEditingCommand(.selectAll)
        }

        // MARK: - Touch Events

        override open func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            if !self.isFirstResponder {
                _ = self.becomeFirstResponder()
            }

            for touch in touches {
                let key = ObjectIdentifier(touch)
                let contactID = activeTouchContacts[key] ?? RID()
                activeTouchContacts[key] = contactID
                let point = touch.location(in: self)

                let touchEvent = TouchEvent(
                    window: self.windowID,
                    location: Point(Float(point.x), Float(point.y)),
                    phase: .began,
                    time: TimeInterval(event?.timestamp ?? 0),
                    contactID: contactID
                )

                input?.wrappedValue.receiveEvent(touchEvent)
            }
        }

        override open func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
            for touch in touches {
                let key = ObjectIdentifier(touch)
                let contactID = activeTouchContacts[key] ?? RID()
                activeTouchContacts[key] = contactID
                let point = touch.location(in: self)

                let touchEvent = TouchEvent(
                    window: self.windowID,
                    location: Point(Float(point.x), Float(point.y)),
                    phase: .moved,
                    time: TimeInterval(event?.timestamp ?? 0),
                    contactID: contactID
                )

                input?.wrappedValue.receiveEvent(touchEvent)
            }
        }

        override open func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
            for touch in touches {
                let key = ObjectIdentifier(touch)
                let contactID = activeTouchContacts[key] ?? RID()
                activeTouchContacts[key] = contactID
                let point = touch.location(in: self)

                let touchEvent = TouchEvent(
                    window: self.windowID,
                    location: Point(Float(point.x), Float(point.y)),
                    phase: .cancelled,
                    time: TimeInterval(event?.timestamp ?? 0),
                    contactID: contactID
                )

                input?.wrappedValue.receiveEvent(touchEvent)
                activeTouchContacts.removeValue(forKey: key)
            }
        }

        override open func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
            for touch in touches {
                let key = ObjectIdentifier(touch)
                let contactID = activeTouchContacts[key] ?? RID()
                activeTouchContacts[key] = contactID
                let point = touch.location(in: self)

                let touchEvent = TouchEvent(
                    window: self.windowID,
                    location: Point(Float(point.x), Float(point.y)),
                    phase: .ended,
                    time: TimeInterval(event?.timestamp ?? 0),
                    contactID: contactID
                )

                input?.wrappedValue.receiveEvent(touchEvent)
                activeTouchContacts.removeValue(forKey: key)
            }
        }

        // MARK: - Physical Keyboard Events

        override open func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            var didHandleEvent = false

            for press in presses {
                guard let key = press.key else {
                    continue
                }

                let keyCode = AppleEmbeddedKeyboard.shared.translateKey(from: key.keyCode)
                guard keyCode != .none else {
                    continue
                }

                let keyEvent = KeyEvent(
                    window: self.windowID,
                    keyCode: keyCode,
                    modifiers: KeyModifier(modifiers: key.modifierFlags),
                    status: .down,
                    time: TimeInterval(event?.timestamp ?? 0),
                    isRepeated: false
                )

                input?.wrappedValue.receiveEvent(keyEvent)
                self.sendHardwareTextInput(
                    keyCode: keyCode,
                    modifiers: keyEvent.modifiers,
                    characters: key.characters,
                    time: keyEvent.time
                )
                didHandleEvent = true
            }

            if !didHandleEvent {
                super.pressesBegan(presses, with: event)
            }
        }

        override open func pressesChanged(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            // Handle key repeat events
            for press in presses {
                guard let key = press.key else {
                    continue
                }

                let keyCode = AppleEmbeddedKeyboard.shared.translateKey(from: key.keyCode)
                guard keyCode != .none else {
                    continue
                }

                let keyEvent = KeyEvent(
                    window: self.windowID,
                    keyCode: keyCode,
                    modifiers: KeyModifier(modifiers: key.modifierFlags),
                    status: .down,
                    time: TimeInterval(event?.timestamp ?? 0),
                    isRepeated: true
                )

                input?.wrappedValue.receiveEvent(keyEvent)
                self.sendHardwareTextInput(
                    keyCode: keyCode,
                    modifiers: keyEvent.modifiers,
                    characters: key.characters,
                    time: keyEvent.time
                )
            }
        }

        override open func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            var didHandleEvent = false

            for press in presses {
                guard let key = press.key else {
                    continue
                }

                let keyCode = AppleEmbeddedKeyboard.shared.translateKey(from: key.keyCode)
                guard keyCode != .none else {
                    continue
                }

                let keyEvent = KeyEvent(
                    window: self.windowID,
                    keyCode: keyCode,
                    modifiers: KeyModifier(modifiers: key.modifierFlags),
                    status: .up,
                    time: TimeInterval(event?.timestamp ?? 0),
                    isRepeated: false
                )

                input?.wrappedValue.receiveEvent(keyEvent)
                didHandleEvent = true
            }

            if !didHandleEvent {
                super.pressesEnded(presses, with: event)
            }
        }

        override open func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            for press in presses {
                guard let key = press.key else {
                    continue
                }

                let keyCode = AppleEmbeddedKeyboard.shared.translateKey(from: key.keyCode)
                guard keyCode != .none else {
                    continue
                }

                let keyEvent = KeyEvent(
                    window: self.windowID,
                    keyCode: keyCode,
                    modifiers: KeyModifier(modifiers: key.modifierFlags),
                    status: .up,
                    time: TimeInterval(event?.timestamp ?? 0),
                    isRepeated: false
                )

                input?.wrappedValue.receiveEvent(keyEvent)
            }
        }

        // MARK: - Mouse/Trackpad Hover Events (iPadOS)

        override open func didMoveToWindow() {
            super.didMoveToWindow()
            configureTextInputAssistant()
            setupMouseTracking()
        }

        /// Setup mouse tracking for iPadOS pointer support.
        func setupMouseTracking() {
            guard self.window != nil else {
                return
            }
            #if os(iOS)
                guard self.traitCollection.userInterfaceIdiom == .pad else {
                    return
                }
            #endif
            guard !(self.gestureRecognizers?.contains { $0 is UIHoverGestureRecognizer } ?? false) else {
                return
            }

            let hoverGesture = UIHoverGestureRecognizer(target: self, action: #selector(handleHover(_:)))
            hoverGesture.cancelsTouchesInView = false
            hoverGesture.delaysTouchesBegan = false
            hoverGesture.delaysTouchesEnded = false
            hoverGesture.requiresExclusiveTouchType = false
            self.addGestureRecognizer(hoverGesture)
        }

        @objc private func handleHover(_ recognizer: UIHoverGestureRecognizer) {
            let location = recognizer.location(in: self)
            let position = Point(Float(location.x), Float(location.y))

            input?.mousePosition = position

            let phase: MouseEvent.Phase
            switch recognizer.state {
            case .began:
                phase = .began
            case .changed:
                phase = .changed
            case .ended,
                .cancelled:
                phase = .ended
            default:
                return
            }

            let mouseEvent = MouseEvent(
                window: self.windowID,
                button: .none,
                mousePosition: position,
                phase: phase,
                modifierKeys: [],
                time: TimeInterval(CACurrentMediaTime())
            )

            input?.wrappedValue.receiveEvent(mouseEvent)
        }

        // MARK: - Coordinate Conversion

        private func mousePosition(for location: CGPoint) -> Vector2 {
            let x = Float(location.x)
            let y = Float(location.y)
            return Point(x, y)
        }

        private func sendHardwareTextInput(
            keyCode: KeyCode,
            modifiers: KeyModifier,
            characters: String,
            time: AdaUtils.TimeInterval
        ) {
            guard
                let payload = AppleHardwareTextInput.payload(
                    keyCode: keyCode,
                    modifiers: modifiers,
                    characters: characters
                )
            else {
                return
            }

            input?.wrappedValue
                .receiveEvent(
                    TextInputEvent(
                        window: self.windowID,
                        text: payload.text,
                        action: payload.action,
                        time: time
                    )
                )
        }

        private func performTextEditingCommand(_ command: UITextEditingCommand) {
            _ = self.windowManager?.windows[self.windowID]?.uiPerformTextEditingCommand(command)
        }

        private func configureTextInputAssistant() {
            #if os(iOS)
                let undoButton = UIBarButtonItem(
                    title: "Undo",
                    style: .plain,
                    target: self,
                    action: #selector(performUndo(_:))
                )
                let redoButton = UIBarButtonItem(
                    title: "Redo",
                    style: .plain,
                    target: self,
                    action: #selector(performRedo(_:))
                )
                let cutButton = UIBarButtonItem(
                    title: "Cut",
                    style: .plain,
                    target: self,
                    action: #selector(cut(_:))
                )
                let copyButton = UIBarButtonItem(
                    title: "Copy",
                    style: .plain,
                    target: self,
                    action: #selector(copy(_:))
                )
                let pasteButton = UIBarButtonItem(
                    title: "Paste",
                    style: .plain,
                    target: self,
                    action: #selector(paste(_:))
                )
                let selectAllButton = UIBarButtonItem(
                    title: "Select All",
                    style: .plain,
                    target: self,
                    action: #selector(selectAll(_:))
                )
                self.inputAssistantItem.leadingBarButtonGroups = [
                    UIBarButtonItemGroup(barButtonItems: [undoButton, redoButton], representativeItem: nil)
                ]
                self.inputAssistantItem.trailingBarButtonGroups = [
                    UIBarButtonItemGroup(
                        barButtonItems: [cutButton, copyButton, pasteButton, selectAllButton],
                        representativeItem: nil
                    )
                ]
            #endif
        }

        @objc private func performUndo(_: Any?) {
            performTextEditingCommand(.undo)
        }

        @objc private func performRedo(_: Any?) {
            performTextEditingCommand(.redo)
        }
    }

    // swiftlint:enable override_in_extension
#endif
