//
//  GestureCombining.swift
//  AdaEngine
//
//  Created by Vladislav Prusakov on 25.03.2025.
//

// MARK: - SimultaneousGesture

/// Combines two gestures that are recognized at the same time.
public struct SimultaneousGesture<First: Gesture, Second: Gesture>: Gesture {
    public struct Value {
        public let first: First.Value?
        public let second: Second.Value?
    }

    public typealias Body = Never

    public let first: First
    public let second: Second

    public init(first: First, second: Second) {
        self.first = first
        self.second = second
    }
}

extension SimultaneousGesture: _GestureRecognizerConvertible
where First: _GestureRecognizerConvertible, Second: _GestureRecognizerConvertible {
    func _buildRecognizers() -> [GestureRecognizer] {
        first._buildRecognizers() + second._buildRecognizers()
    }
}

// MARK: - SequenceGesture

/// A gesture formed from a sequence of two gestures, where the second gesture is recognized
/// only after the first has completed.
public struct SequenceGesture<First: Gesture, Second: Gesture>: Gesture {
    public enum Value {
        case first(First.Value)
        case second(First.Value, Second.Value?)
    }

    public typealias Body = Never

    public let first: First
    public let second: Second

    public init(first: First, second: Second) {
        self.first = first
        self.second = second
    }
}

// MARK: - ExclusiveGesture

/// A gesture where only one of two gestures succeeds.
public struct ExclusiveGesture<First: Gesture, Second: Gesture>: Gesture {
    public enum Value {
        case first(First.Value)
        case second(Second.Value)
    }

    public typealias Body = Never

    public let first: First
    public let second: Second

    public init(first: First, second: Second) {
        self.first = first
        self.second = second
    }
}

extension ExclusiveGesture: _GestureRecognizerConvertible
where First: _GestureRecognizerConvertible, Second: _GestureRecognizerConvertible {
    func _buildRecognizers() -> [GestureRecognizer] {
        first._buildRecognizers() + second._buildRecognizers()
    }
}
