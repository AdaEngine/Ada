import AdaECS
import AdaInput
import AdaUtils
import Math

/// Pointer interaction emitted by SpritePickingPlugin, received through ECS Events<SpritePointerEvent>.
public struct SpritePointerEvent: Event, Sendable {
    public enum Kind: Hashable, Sendable {
        case enter, exit, move, down, up, click, dragStart, drag, dragEnd, cancel
    }

    public let kind: Kind
    public let pointer: InputPointerID
    public let entityID: Entity.ID
    public let cameraID: Entity.ID
    /// Mouse button, or nil for touch/hover.
    public let button: MouseButton?
    public let position: Point
    /// Delta in logical viewport points. Captured drags keep their original target outside its bounds.
    public let delta: Vector2
    /// Current hit, or nil when a captured pointer is outside its original target/viewport.
    public let hit: SpritePickHit?
}

public struct SpritePickingState: Resource {
    var pointers: [InputPointerID: SpritePointerTracker] = [:]

    public init() {}

    public func hoveredEntities(for pointer: InputPointerID) -> [Entity.ID] {
        pointers[pointer]?.hover.map(\.entityID) ?? []
    }
}

struct SpritePointerCapture: Sendable {
    var hit: SpritePickHit
    var origin: Point
    var isDragging = false
}

struct SpritePointerTracker: Sendable {
    var position: Point = .zero
    var hover: [SpritePickHit] = []
    var captures: [MouseButton: [SpritePointerCapture]] = [:]
    var suppressed: Set<MouseButton> = []

    mutating func updateHover(
        _ hits: [SpritePickHit],
        pointer: InputPointerID,
        position: Point,
        emit: (SpritePointerEvent) -> Void
    ) {
        for previous in hover where !hits.contains(where: { sameTarget($0, previous) }) {
            emit(event(.exit, pointer: pointer, target: previous, button: nil, position: position))
        }
        for hit in hits where !hover.contains(where: { sameTarget($0, hit) }) {
            emit(event(.enter, pointer: pointer, target: hit, button: nil, position: position, hit: hit))
        }
        hover = hits
    }

    mutating func process(
        pointer: InputPointerID,
        position: Point,
        phase: MouseEvent.Phase,
        button: MouseButton?,
        hits: [SpritePickHit],
        blocked: Bool,
        dragThreshold: Float,
        emit: (SpritePointerEvent) -> Void
    ) {
        let key = button ?? .none
        let delta = position - self.position
        self.position = position
        updateHover(blocked ? [] : hits, pointer: pointer, position: position, emit: emit)
        if blocked {
            cancelCaptures(pointer: pointer, position: position, emit: emit)
            if phase == .began { suppressed.insert(key) }
        }
        if phase == .began, !blocked {
            suppressed.remove(key)
        }
        if phase == .ended || phase == .cancelled {
            if suppressed.remove(key) != nil {
                return
            }
        } else if suppressed.contains(key) {
            return
        }
        guard !blocked else {
            return
        }
        switch phase {
        case .began:
            if let previous = captures.removeValue(forKey: key) {
                for capture in previous {
                    emit(event(.cancel, pointer: pointer, target: capture.hit, button: button, position: position))
                }
            }
            captures[key] = hits.map { SpritePointerCapture(hit: $0, origin: position) }
            for hit in hits {
                emit(event(.down, pointer: pointer, target: hit, button: button, position: position, hit: hit))
            }
        case .changed:
            for hit in hits {
                emit(event(.move, pointer: pointer, target: hit, button: button, position: position, delta: delta, hit: hit))
            }
            if let button, button == .none {
                // Native unbuttoned movement recovers a missing release/focus loss.
                cancelCaptures(pointer: pointer, position: position, emit: emit)
                return
            }
            guard var current = captures[key] else {
                return
            }
            for index in current.indices {
                let hit = hits.first { sameTarget($0, current[index].hit) }
                if !current[index].isDragging, (position - current[index].origin).squaredLength >= dragThreshold * dragThreshold {
                    current[index].isDragging = true
                    emit(event(.dragStart, pointer: pointer, target: current[index].hit, button: button, position: position, delta: delta, hit: hit))
                }
                if current[index].isDragging {
                    emit(event(.drag, pointer: pointer, target: current[index].hit, button: button, position: position, delta: delta, hit: hit))
                }
            }
            captures[key] = current
        case .ended, .cancelled:
            guard let current = captures.removeValue(forKey: key) else {
                return
            }
            for capture in current {
                let hit = hits.first { sameTarget($0, capture.hit) }
                if phase == .cancelled {
                    emit(event(.cancel, pointer: pointer, target: capture.hit, button: button, position: position))
                } else {
                    emit(event(.up, pointer: pointer, target: capture.hit, button: button, position: position, hit: hit))
                    if capture.isDragging {
                        emit(event(.dragEnd, pointer: pointer, target: capture.hit, button: button, position: position, hit: hit))
                    } else if let hit, (position - capture.origin).squaredLength < dragThreshold * dragThreshold {
                        emit(event(.click, pointer: pointer, target: hit, button: button, position: position, hit: hit))
                    }
                }
            }
        }
    }

    mutating func cancelCaptures(pointer: InputPointerID, position: Point, emit: (SpritePointerEvent) -> Void) {
        for (button, current) in captures {
            for capture in current {
                let eventButton: MouseButton? = button == .none ? nil : button
                emit(event(.cancel, pointer: pointer, target: capture.hit, button: eventButton, position: position))
            }
            suppressed.insert(button)
        }
        captures.removeAll(keepingCapacity: true)
    }

    func sameTarget(_ lhs: SpritePickHit, _ rhs: SpritePickHit) -> Bool {
        lhs.entityID == rhs.entityID && lhs.cameraID == rhs.cameraID
    }

    func event(
        _ kind: SpritePointerEvent.Kind,
        pointer: InputPointerID,
        target: SpritePickHit,
        button: MouseButton?,
        position: Point,
        delta: Vector2 = .zero,
        hit: SpritePickHit? = nil
    ) -> SpritePointerEvent {
        SpritePointerEvent(kind: kind, pointer: pointer, entityID: target.entityID, cameraID: target.cameraID, button: button, position: position, delta: delta, hit: hit)
    }
}
