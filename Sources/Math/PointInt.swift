//
//  PointInt.swift
//  Math
//
//  Created by v.prusakov on 5/5/24.
//

public struct PointInt: Codable, Equatable, Hashable, Comparable, Sendable {
    public static let zero = Self(x: 0, y: 0)
    public var x: Int
    public var y: Int

    public init(x: Int, y: Int) {
        self.x = x
        self.y = y
    }

    public init(_ elements: [Int]) {
        assert(elements.count == 2)
        self.x = elements[0]
        self.y = elements[1]
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.x < rhs.x && lhs.y < rhs.y
    }
}

extension PointInt: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: Int...) {
        assert(elements.count == 2)
        self.x = elements[0]
        self.y = elements[1]
    }
}
