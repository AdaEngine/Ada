//
//  Angle.swift
//  AdaEngine
//
//  Created by v.prusakov on 10/20/21.
//

@frozen
public struct Angle {
    public let degrees: Float

    public var radians: Float {
        return self.degrees * .pi / 180
    }

    init(radians: Float) {
        self.degrees = radians / .pi * 180
    }

    init(degrees: Float) {
        self.degrees = degrees
    }
}

extension Angle: Hashable, Equatable, Codable {}

extension Angle {
    public static func degrees(_ deg: Float) -> Angle {
        return Angle(degrees: deg)
    }

    public static func radians(_ radians: Float) -> Angle {
        return Angle(radians: radians)
    }

    public static let zero: Angle = Angle(degrees: 0)
}

extension Angle {
    public static func + (lhs: Angle, rhs: Angle) -> Angle {
        let newDegrees = lhs.degrees + rhs.degrees
        return Self.degrees(newDegrees)
    }

    public static func += (lhs: inout Angle, rhs: Angle) {
        lhs = lhs + rhs
    }

    public static func + (lhs: Angle, rhs: Float) -> Angle {
        return Angle(radians: lhs.radians + rhs)
    }

    public static func += (lhs: inout Angle, rhs: Float) {
        lhs = Angle(radians: lhs.radians + rhs)
    }
}

extension Angle: ExpressibleByFloatLiteral {
    public init(floatLiteral value: FloatLiteralType) {
        self = Angle(radians: Float(value))
    }
}

extension Angle: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: IntegerLiteralType) {
        self = Angle(radians: Float(value))
    }
}
