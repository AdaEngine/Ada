//
//  GestureHelpers.swift
//  AdaEngine
//
//  Created by Vladislav Prusakov on 02.07.2024.
//

extension Gesture {
    public func updating<State>(
        _: GestureState<State>,
        body: @escaping (Self.Value, inout State) -> Void
    ) -> GestureStateGesture<Self, State> {
        GestureStateGesture(action: body, gesture: self)
    }

    public func onChanged(_ action: @escaping (Value) -> Void) -> _OnChangedGesture<Self> {
        _OnChangedGesture(action: action, gesture: self)
    }

    public func onEnded(_ action: @escaping (Value) -> Void) -> _OnEndedGesture<Self> {
        _OnEndedGesture(action: action, gesture: self)
    }

    public func map<T>(_ block: @escaping (Value) -> T) -> _MapGesture<Self, T> {
        _MapGesture(gesture: self, map: block)
    }

    public func simultaneously<Other: Gesture>(with other: Other) -> SimultaneousGesture<Self, Other> {
        SimultaneousGesture(first: self, second: other)
    }

    public func sequenced<Other: Gesture>(before other: Other) -> SequenceGesture<Self, Other> {
        SequenceGesture(first: self, second: other)
    }

    public func exclusively<Other: Gesture>(before other: Other) -> ExclusiveGesture<Self, Other> {
        ExclusiveGesture(first: self, second: other)
    }
}

// MARK: - _OnChangedGesture

public struct _OnChangedGesture<G: Gesture>: Gesture {
    public typealias Value = G.Value
    public typealias Body = Never

    let action: (G.Value) -> Void
    let gesture: G
}

extension _OnChangedGesture: _RecognizableGesture where G: _RecognizableGesture {
    func _makeRecognizer(onChanged _: ((Value) -> Void)?, onEnded: ((Value) -> Void)?) -> GestureRecognizer {
        gesture._makeRecognizer(onChanged: self.action, onEnded: onEnded)
    }
}

extension _OnChangedGesture: _GestureRecognizerConvertible where G: _RecognizableGesture {
    func _buildRecognizers() -> [GestureRecognizer] {
        [_makeRecognizer(onChanged: nil, onEnded: nil)]
    }
}

// MARK: - _OnEndedGesture

public struct _OnEndedGesture<G: Gesture>: Gesture {
    public typealias Value = G.Value
    public typealias Body = Never

    let action: (G.Value) -> Void
    let gesture: G
}

extension _OnEndedGesture: _RecognizableGesture where G: _RecognizableGesture {
    func _makeRecognizer(onChanged: ((Value) -> Void)?, onEnded _: ((Value) -> Void)?) -> GestureRecognizer {
        gesture._makeRecognizer(onChanged: onChanged, onEnded: self.action)
    }
}

extension _OnEndedGesture: _GestureRecognizerConvertible where G: _RecognizableGesture {
    func _buildRecognizers() -> [GestureRecognizer] {
        [_makeRecognizer(onChanged: nil, onEnded: nil)]
    }
}

// MARK: - _MapGesture

public struct _MapGesture<G: Gesture, T>: Gesture {
    public typealias Value = T
    public typealias Body = Never

    let map: (G.Value) -> T
    let gesture: G

    init(gesture: G, map: @escaping (G.Value) -> T) {
        self.gesture = gesture
        self.map = map
    }
}
