//
//  RectInt.swift
//  AdaEngine
//
//  Created by Vladislav Prusakov on 21.04.2026.
//

public struct RectInt: Equatable, Codable, Hashable, Sendable {
    public var origin: PointInt
    public var size: SizeInt

    public init(origin: PointInt, size: SizeInt) {
        self.origin = origin
        self.size = size
    }
}

extension RectInt {
    @inline(__always)
    public static let zero = RectInt(origin: .zero, size: .zero)

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.origin = [x, y]
        self.size = SizeInt(width: width, height: height)
    }
}
