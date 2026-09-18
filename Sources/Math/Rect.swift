//
//  Rect.swift
//  AdaEngine
//
//  Created by v.prusakov on 5/16/22.
//

public struct Rect: Equatable, Codable, Hashable, Sendable {
    public var origin: Point
    public var size: Size

    public init(origin: Point, size: Size) {
        self.origin = origin
        self.size = size
    }
}

extension Rect {
    @inline(__always)
    public static let zero = Rect(origin: .zero, size: .zero)

    public init(x: Float, y: Float, width: Float, height: Float) {
        self.origin = [x, y]
        self.size = Size(width: width, height: height)
    }
}

#if canImport(CoreGraphics)
    import CoreGraphics
    extension Rect {
        @inline(__always)
        public var toCGRect: CGRect {
            return CGRect(origin: self.origin.toCGPoint, size: self.size.toCGSize)
        }
    }
#endif

extension Rect {
    @inline(__always)
    public var minX: Float {
        return self.origin.x
    }

    @inline(__always)
    public var midX: Float {
        return self.minX + self.width / 2
    }

    @inline(__always)
    public var maxX: Float {
        return self.minX + self.width
    }

    @inline(__always)
    public var minY: Float {
        return self.origin.y
    }

    @inline(__always)
    public var midY: Float {
        return self.minY + self.height / 2
    }

    @inline(__always)
    public var maxY: Float {
        return self.minY + self.height
    }

    @inline(__always)
    public var width: Float {
        return self.size.width
    }

    @inline(__always)
    public var height: Float {
        return self.size.height
    }
}

extension Rect {
    public func applying(_ transform: Transform2D) -> Rect {
        if transform == .identity {
            return self
        }

        let upLeft = Point(x: minX, y: minY).applying(transform)
        let upRight = Point(x: maxX, y: minY).applying(transform)
        let downLeft = Point(x: minX, y: maxY).applying(transform)
        let downRight = Point(x: maxX, y: maxY).applying(transform)

        let minX = min(upLeft.x, upRight.x, downLeft.x, downRight.x)
        let maxX = max(upLeft.x, upRight.x, downLeft.x, downRight.x)

        let minY = min(upLeft.y, upRight.y, downLeft.y, downRight.y)
        let maxY = max(upLeft.y, upRight.y, downLeft.y, downRight.y)

        return Rect(
            x: minX,
            y: minY,
            width: maxX - minX,
            height: maxY - minY
        )
    }

    public func contains(point: Point) -> Bool {
        point.x >= self.minX && point.x < self.maxX && point.y >= self.minY && point.y < self.maxY
    }

    /// Returns the intersection of two rectangles.
    public func intersection(_ other: Rect) -> Rect {
        let minX = max(self.minX, other.minX)
        let minY = max(self.minY, other.minY)
        let maxX = min(self.maxX, other.maxX)
        let maxY = min(self.maxY, other.maxY)

        let width = max(0, maxX - minX)
        let height = max(0, maxY - minY)

        return Rect(x: minX, y: minY, width: width, height: height)
    }

    public func intersects(_ other: Rect) -> Bool {
        return self.minX <= other.maxX
            && other.minX <= self.maxX
            && self.minY <= other.maxY
            && other.minY <= self.maxY
    }

    public func union(_ other: Rect) -> Rect {
        let minX = min(self.minX, other.minX)
        let minY = min(self.minY, other.minY)
        let maxX = max(self.maxX, other.maxX)
        let maxY = max(self.maxY, other.maxY)
        return Rect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}
