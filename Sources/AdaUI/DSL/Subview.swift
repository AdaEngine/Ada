//
//  Subview.swift
//  AdaEngine
//
//  Created by Vladislav Prusakov on 15.07.2024.
//

@MainActor
@preconcurrency
public struct Subview: View, Identifiable {
    public let id: ObjectIdentifier
    let view: AnyView

    init<V: View>(_ view: V) {
        self.id = ObjectIdentifier(V.self)
        self.view = AnyView(view)
    }

    public var body: some View {
        self.view
    }
}

public struct SubviewsCollection: Collection, Sequence, RandomAccessCollection {
    let subviews: [Subview]

    public typealias Element = Subview
    public typealias Index = Int

    public var startIndex: Int {
        self.subviews.startIndex
    }

    public var endIndex: Int {
        self.subviews.endIndex
    }

    public func index(after i: Int) -> Int {
        self.subviews.index(after: i)
    }

    public subscript(position: Int) -> Subview {
        _read {
            yield self.subviews[position]
        }
    }
}
