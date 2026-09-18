//
//  View+Gestures.swift
//  AdaEngine
//
//  Created by Vladislav Prusakov on 02.07.2024.
//

extension View {
    public func gesture<G: Gesture>(_ gesture: G) -> some View {
        self.modifier(GestureViewModifier(gesture: gesture, content: self))
    }

    @inlinable
    public func onTap(count: Int = 1, perform: @escaping () -> Void) -> some View {
        onTapGesture(count: count, perform: perform)
    }

    @inlinable
    public func onTapGesture(count: Int = 1, perform: @escaping () -> Void) -> some View {
        self.gesture(
            TapGesture(count: count)
                .onEnded(perform)
        )
    }
}
