//
//  SizeInt.swift
//  Math
//
//  Created by Vladislav Prusakov on 02.06.2024.
//

public struct SizeInt: Equatable, Codable, Hashable, Comparable, Sendable {
    public var width: Int
    public var height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.width < rhs.width && lhs.height < rhs.height
    }
}

extension SizeInt {
    @inline(__always)
    public static let zero = SizeInt(width: 0, height: 0)

    public func toSize() -> Size {
        Size(width: Float(width), height: Float(height))
    }
}

extension SizeInt: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: Int...) {
        assert(elements.count == 2, "Array must be contains only two elements.")

        self.init(width: elements[0], height: elements[1])
    }
}
