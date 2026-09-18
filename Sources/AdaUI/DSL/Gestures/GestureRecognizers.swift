//
//  GestureRecognizers.swift
//  AdaEngine
//
//  Created by Vladislav Prusakov on 25.03.2025.
//

import AdaInput
import AdaUtils
import Math

// MARK: - TapGestureRecognizer

@MainActor
final class TapGestureRecognizer: GestureRecognizer {
    private let requiredCount: Int
    private var tapCount: Int = 0
    private let onEnded: () -> Void

    init(count: Int, onEnded: @escaping () -> Void) {
        self.requiredCount = count
        self.onEnded = onEnded
    }

    override func mouseEventBegan(_ event: MouseEvent) {
        guard event.button == .left else {
            return
        }
        setState(.began)
    }

    override func mouseEventEnded(_ event: MouseEvent) {
        guard event.button == .left else {
            return
        }
        tapCount += 1
        if tapCount >= requiredCount {
            onEnded()
            tapCount = 0
            reset()
        }
    }

    override func mouseEventCancelled(_: MouseEvent) {
        tapCount = 0
        reset()
    }

    override func touchesBegan(_: Set<TouchEvent>) {
        setState(.began)
    }

    override func touchesEnded(_: Set<TouchEvent>) {
        tapCount += 1
        if tapCount >= requiredCount {
            onEnded()
            tapCount = 0
            reset()
        }
    }

    override func touchesCancelled(_: Set<TouchEvent>) {
        tapCount = 0
        reset()
    }

    override func onCancelled() {
        tapCount = 0
    }
}

// MARK: - LongPressGestureRecognizer

@MainActor
final class LongPressGestureRecognizer: GestureRecognizer {
    private let minimumDuration: TimeInterval
    private let onEnded: () -> Void

    private var pressStartTime: TimeInterval?
    private var elapsed: TimeInterval = 0
    private var fired: Bool = false

    init(minimumDuration: TimeInterval, onEnded: @escaping () -> Void) {
        self.minimumDuration = minimumDuration
        self.onEnded = onEnded
    }

    override func mouseEventBegan(_ event: MouseEvent) {
        guard event.button == .left else {
            return
        }
        pressStartTime = event.time
        elapsed = 0
        fired = false
        setState(.began)
    }

    override func mouseEventEnded(_: MouseEvent) {
        pressStartTime = nil
        elapsed = 0
        reset()
    }

    override func mouseEventCancelled(_: MouseEvent) {
        pressStartTime = nil
        elapsed = 0
        reset()
    }

    override func touchesBegan(_ touches: Set<TouchEvent>) {
        guard let first = touches.first else {
            return
        }
        pressStartTime = first.time
        elapsed = 0
        fired = false
        setState(.began)
    }

    override func touchesEnded(_: Set<TouchEvent>) {
        pressStartTime = nil
        elapsed = 0
        reset()
    }

    override func touchesCancelled(_: Set<TouchEvent>) {
        pressStartTime = nil
        elapsed = 0
        reset()
    }

    override func update(_ deltaTime: TimeInterval) {
        guard state == .began || state == .changed, !fired else {
            return
        }
        elapsed += deltaTime
        if elapsed >= minimumDuration {
            fired = true
            setState(.ended)
            onEnded()
            reset()
        }
    }

    override func onCancelled() {
        pressStartTime = nil
        elapsed = 0
        fired = false
    }
}

// MARK: - DragGestureRecognizer

@MainActor
final class DragGestureRecognizer: GestureRecognizer {
    private let minimumDistance: Float
    private let onChanged: ((DragGesture.Value) -> Void)?
    private let onEnded: ((DragGesture.Value) -> Void)?

    private var startLocation: Point?
    private var lastLocation: Point?

    init(
        minimumDistance: Float,
        onChanged: ((DragGesture.Value) -> Void)?,
        onEnded: ((DragGesture.Value) -> Void)?
    ) {
        self.minimumDistance = minimumDistance
        self.onChanged = onChanged
        self.onEnded = onEnded
    }

    override func mouseEventBegan(_ event: MouseEvent) {
        guard event.button == .left else {
            return
        }
        startLocation = event.mousePosition
        lastLocation = event.mousePosition
        setState(.began)
    }

    override func mouseEventChanged(_ event: MouseEvent) {
        // A plain hover after capture means the platform missed the mouse-up
        // (for example, because it happened outside the window). End the drag
        // so it cannot keep consuming cursor movement without a pressed button.
        if event.button == .none, startLocation != nil {
            finishMouseDrag()
            return
        }
        guard event.button == .left else {
            return
        }
        guard let start = startLocation else {
            return
        }

        let current = event.mousePosition
        lastLocation = current

        let dx = current.x - start.x
        let dy = current.y - start.y
        let distance = (dx * dx + dy * dy).squareRoot()

        // The threshold only starts a drag; returning near its origin must still update it.
        guard state == .changed || distance >= minimumDistance else {
            return
        }

        if state == .began {
            setState(.changed)
        }
        let value = DragGesture.Value(startLocation: start, location: current)
        onChanged?(value)
    }

    override func mouseEventEnded(_ event: MouseEvent) {
        guard event.button == .left else {
            return
        }
        finishMouseDrag()
    }

    private func finishMouseDrag() {
        defer {
            startLocation = nil
            lastLocation = nil
            reset()
        }
        guard let start = startLocation, let current = lastLocation else {
            return
        }
        let value = DragGesture.Value(startLocation: start, location: current)
        onEnded?(value)
    }

    override func mouseEventCancelled(_: MouseEvent) {
        startLocation = nil
        lastLocation = nil
        reset()
    }

    override func touchesBegan(_ touches: Set<TouchEvent>) {
        guard let first = touches.first else {
            return
        }
        startLocation = first.location
        lastLocation = first.location
        setState(.began)
    }

    override func touchesMoved(_ touches: Set<TouchEvent>) {
        guard let first = touches.first, let start = startLocation else {
            return
        }
        let current = first.location
        lastLocation = current

        let dx = current.x - start.x
        let dy = current.y - start.y
        let distance = (dx * dx + dy * dy).squareRoot()
        // The threshold only starts a drag; returning near its origin must still update it.
        guard state == .changed || distance >= minimumDistance else {
            return
        }

        if state == .began {
            setState(.changed)
        }
        let value = DragGesture.Value(startLocation: start, location: current)
        onChanged?(value)
    }

    override func touchesEnded(_: Set<TouchEvent>) {
        defer {
            startLocation = nil
            lastLocation = nil
            reset()
        }
        guard let start = startLocation, let current = lastLocation else {
            return
        }
        let value = DragGesture.Value(startLocation: start, location: current)
        onEnded?(value)
    }

    override func touchesCancelled(_: Set<TouchEvent>) {
        startLocation = nil
        lastLocation = nil
        reset()
    }

    override func onCancelled() {
        startLocation = nil
        lastLocation = nil
    }
}
