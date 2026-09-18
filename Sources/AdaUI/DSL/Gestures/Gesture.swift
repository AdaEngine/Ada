//
//  Gesture.swift
//  AdaEngine
//
//  Created by Vladislav Prusakov on 01.07.2024.
//

import AdaInput
import AdaUtils
import Math

// MARK: - Gesture Protocol

/// A protocol that defines a gesture for views.
public protocol Gesture<Value> {
    associatedtype Value

    associatedtype Body: Gesture

    var body: Body { get }

    @MainActor
    static func _makeGesture(gesture: _ViewGraphNode<Self>, inputs: _ViewInputs) -> _Gesture
}

extension Gesture {
    @MainActor
    // Protocol default is an invariant trap for non-primitive gesture implementations.
    // swiftlint:disable:next unavailable_function
    public static func _makeGesture(gesture _: _ViewGraphNode<Self>, inputs _: _ViewInputs) -> _Gesture {
        preconditionFailure("Primitive gestures must implement _makeGesture(gesture:inputs:).")
    }
}

extension Never: Gesture {
    public typealias Value = Never
}

extension Gesture where Body == Never {
    // Primitive gestures satisfy View-style associated types without exposing a body.
    public var body: Never {
        preconditionFailure("Primitive gestures do not expose a body.")
    }
}

// MARK: - Internal bridge protocols

/// Implemented by primitive gesture types to create a concrete recognizer with callbacks.
protocol _RecognizableGesture: Gesture {
    @MainActor func _makeRecognizer(
        onChanged: ((Value) -> Void)?,
        onEnded: ((Value) -> Void)?
    ) -> GestureRecognizer
}

/// Implemented by gesture modifier types that can produce one or more recognizers.
protocol _GestureRecognizerConvertible {
    @MainActor func _buildRecognizers() -> [GestureRecognizer]
}

// MARK: - View Modifier

struct GestureViewModifier<G: Gesture, Content: View>: ViewModifier, ViewNodeBuilder {
    typealias Body = Never

    let gesture: G
    let content: Content

    func buildViewNode(in context: BuildContext) -> ViewNode {
        let recognizers = (gesture as? _GestureRecognizerConvertible)?._buildRecognizers() ?? []
        return GestureAreaViewNode(
            contentNode: context.makeNode(from: content),
            content: content,
            recognizers: recognizers
        )
    }
}

// MARK: - Gesture Runtime Base

@MainActor
public class _Gesture {
    weak var node: ViewNode?

    func onReceiveEvent(_: any InputEvent) {}

    func onMouseEvent(_: MouseEvent) {}
}

// MARK: - GestureRecognizer

@MainActor
class GestureRecognizer {
    enum State {
        case possible
        case began
        case changed
        case ended
        case cancelled
        case failed
    }

    private(set) var state: State = .possible

    func setState(_ newState: State) {
        state = newState
    }

    func reset() {
        state = .possible
    }

    func mouseEventBegan(_: MouseEvent) {}
    func mouseEventChanged(_: MouseEvent) {}
    func mouseEventEnded(_: MouseEvent) {}
    func mouseEventCancelled(_: MouseEvent) {}

    func touchesBegan(_: Set<TouchEvent>) {}
    func touchesMoved(_: Set<TouchEvent>) {}
    func touchesEnded(_: Set<TouchEvent>) {}
    func touchesCancelled(_: Set<TouchEvent>) {}

    func update(_: TimeInterval) {}

    func cancel() {
        guard state == .began || state == .changed else {
            return
        }
        setState(.cancelled)
        onCancelled()
        reset()
    }

    func onCancelled() {}
}

// MARK: - GestureAreaViewNode

class GestureAreaViewNode: ViewModifierNode {
    override var allowsNestedFrameAnimation: Bool {
        true
    }

    var gestures: [GestureRecognizer]

    init<Content: View>(contentNode: ViewNode, content: Content, recognizers: [GestureRecognizer]) {
        self.gestures = recognizers
        super.init(contentNode: contentNode, content: content)
    }

    override func hitTest(_ point: Point, with event: any InputEvent) -> ViewNode? {
        guard self.point(inside: point, with: event) else {
            return nil
        }
        return self
    }

    override func onMouseEvent(_ event: MouseEvent) {
        for recognizer in gestures {
            switch event.phase {
            case .began: recognizer.mouseEventBegan(event)
            case .changed: recognizer.mouseEventChanged(event)
            case .ended: recognizer.mouseEventEnded(event)
            case .cancelled: recognizer.mouseEventCancelled(event)
            }
        }
        contentNode.onMouseEvent(event)
    }

    override func onTouchesEvent(_ touches: Set<TouchEvent>) {
        for recognizer in gestures {
            let phases = touches.map(\.phase)
            if phases.contains(.began) {
                recognizer.touchesBegan(touches)
            }
            if phases.contains(.moved) {
                recognizer.touchesMoved(touches)
            }
            if phases.contains(.ended) {
                recognizer.touchesEnded(touches)
            }
            if phases.contains(.cancelled) {
                recognizer.touchesCancelled(touches)
            }
        }
        contentNode.onTouchesEvent(touches)
    }

    override func update(_ deltaTime: TimeInterval) {
        for recognizer in gestures {
            recognizer.update(deltaTime)
        }
        super.update(deltaTime)
    }

    override func onMouseLeave() {
        for recognizer in gestures {
            recognizer.cancel()
        }
        super.onMouseLeave()
    }
}

// MARK: - Gesture Types

/// A single- or multi-tap gesture.
public struct TapGesture: Gesture {
    public typealias Value = Void
    public typealias Body = Never

    public var count: Int

    public init(count: Int = 1) {
        self.count = count
    }
}

extension TapGesture: _RecognizableGesture {
    func _makeRecognizer(onChanged _: ((()) -> Void)?, onEnded: ((()) -> Void)?) -> GestureRecognizer {
        TapGestureRecognizer(count: count, onEnded: { onEnded?(()) })
    }
}

/// A press-and-hold gesture.
public struct LongPressGesture: Gesture {
    public typealias Value = Void
    public typealias Body = Never

    public var minimumDuration: TimeInterval

    public init(minimumDuration: TimeInterval = 1) {
        self.minimumDuration = minimumDuration
    }
}

extension LongPressGesture: _RecognizableGesture {
    func _makeRecognizer(onChanged _: ((()) -> Void)?, onEnded: ((()) -> Void)?) -> GestureRecognizer {
        LongPressGestureRecognizer(minimumDuration: minimumDuration, onEnded: { onEnded?(()) })
    }
}

/// A drag gesture that tracks movement.
public struct DragGesture: Gesture {
    public typealias Body = Never

    public struct Value: Sendable {
        public let startLocation: Point
        public let location: Point

        public var translation: Size {
            Size(
                width: location.x - startLocation.x,
                height: location.y - startLocation.y
            )
        }
    }

    public var minimumDistance: Float

    public init(minimumDistance: Float = 10) {
        self.minimumDistance = minimumDistance
    }
}

extension DragGesture: _RecognizableGesture {
    func _makeRecognizer(
        onChanged: ((DragGesture.Value) -> Void)?,
        onEnded: ((DragGesture.Value) -> Void)?
    ) -> GestureRecognizer {
        DragGestureRecognizer(minimumDistance: minimumDistance, onChanged: onChanged, onEnded: onEnded)
    }
}

// MARK: - GestureStateGesture

public struct GestureStateGesture<G: Gesture, State>: Gesture {
    public typealias Value = G.Value
    public typealias Body = Never

    let action: (G.Value, inout State) -> Void
    let gesture: G
}
