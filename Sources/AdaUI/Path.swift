//
//  Path.swift
//  AdaEngine
//
//  Created by Vladislav Prusakov on 02.07.2024.
//

import Math

public struct Path: Sendable {
    private var elements: [Element] = []

    public var isEmpty: Bool {
        return elements.isEmpty
    }

    public var boundingRect: Rect {
        fatalError("Unreachable code")
    }

    public enum Element: Sendable, Equatable {
        case move(to: Vector2)

        case line(to: Vector2)

        case quadCurve(to: Point, control: Point)

        /// A cubic Bézier curve from the previous current point to the given
        /// end-point, using the two control points to define the curve.
        ///
        /// The end-point of the curve becomes the new current point.
        case curve(to: Point, control1: Point, control2: Point)

        /// A line from the start point of the current subpath (if any) to the
        /// current point, which terminates the subpath.
        ///
        /// After closing the subpath, the current point becomes undefined.
        case closeSubpath
    }

    public init() {}

    public init(_ callback: (inout Self) -> Void) {
        var path = Self()
        callback(&path)
        self = path
    }

    public func forEach(_ body: (Self.Element) -> Void) {
        self.elements.forEach(body)
    }
}

extension Path {
    /// Begins a new subpath at the specified point.
    ///
    /// The specified point becomes the start point of a new subpath.
    /// The current point is set to this start point.
    ///
    /// - Parameter end: The point, in user space coordinates, at which
    ///   to start a new subpath.
    ///
    public mutating func move(to end: Vector2) {
        self.elements.append(.move(to: end))
    }

    /// Appends a straight line segment from the current point to the
    /// specified point.
    ///
    /// After adding the line segment, the current point is set to the
    /// endpoint of the line segment.
    ///
    /// - Parameter end: The location, in user space coordinates, for the
    ///   end of the new line segment.
    ///
    public mutating func addLine(to end: Vector2) {
        self.elements.append(.line(to: end))
    }

    /// Adds a quadratic Bézier curve to the path, with the
    /// specified end point and control point.
    ///
    /// This method constructs a curve starting from the path's current
    /// point and ending at the specified end point, with curvature
    /// defined by the control point. After this method appends that
    /// curve to the current path, the end point of the curve becomes
    /// the path's current point.
    ///
    /// - Parameters:
    ///     the curve.
    ///   - control: The control point of the curve, in user space
    ///     coordinates.
    ///
    public mutating func addQuadCurve(to end: Point, control: Point) {
        self.elements.append(.quadCurve(to: end, control: control))
    }

    /// Adds a cubic Bézier curve to the path, with the
    /// specified end point and control points.
    ///
    /// This method constructs a curve starting from the path's current
    /// point and ending at the specified end point, with curvature
    /// defined by the two control points. After this method appends
    /// that curve to the current path, the end point of the curve
    /// becomes the path's current point.
    ///
    /// - Parameters:
    ///     the curve.
    ///   - control1: The first control point of the curve, in user
    ///     space coordinates.
    ///   - control2: The second control point of the curve, in user
    ///     space coordinates.
    ///
    public mutating func addCurve(to end: Point, control1: Point, control2: Point) {
        self.elements.append(.curve(to: end, control1: control1, control2: control2))
    }

    /// Closes and completes the current subpath.
    ///
    /// Appends a line from the current point to the starting point of
    /// the current subpath and ends the subpath.
    ///
    /// After closing the subpath, your application can begin a new
    /// subpath without first calling `move(to:)`. In this case, a new
    /// subpath is implicitly created with a starting and current point
    /// equal to the previous subpath's starting point.
    ///
    public mutating func closeSubpath() {
        self.elements.append(.closeSubpath)
    }

    /// Adds a rectangular subpath to the path.
    public mutating func addRect(_ rect: Rect, transform _: Transform2D = .identity) {
        move(to: Vector2(rect.minX, rect.minY))
        addLine(to: Vector2(rect.maxX, rect.minY))
        addLine(to: Vector2(rect.maxX, rect.maxY))
        addLine(to: Vector2(rect.minX, rect.maxY))
        closeSubpath()
    }

    /// Adds an ellipse inscribed in the given rect, approximated with 4 cubic Bézier curves.
    public mutating func addEllipse(in rect: Rect) {
        let kappa: Float = 0.5522847498
        let cx = rect.midX
        let cy = rect.midY
        let rx = rect.width * 0.5
        let ry = rect.height * 0.5
        let ox = rx * kappa
        let oy = ry * kappa

        move(to: Vector2(cx, cy - ry))
        addCurve(to: Point(cx + rx, cy), control1: Point(cx + ox, cy - ry), control2: Point(cx + rx, cy - oy))
        addCurve(to: Point(cx, cy + ry), control1: Point(cx + rx, cy + oy), control2: Point(cx + ox, cy + ry))
        addCurve(to: Point(cx - rx, cy), control1: Point(cx - ox, cy + ry), control2: Point(cx - rx, cy + oy))
        addCurve(to: Point(cx, cy - ry), control1: Point(cx - rx, cy - oy), control2: Point(cx - ox, cy - ry))
        closeSubpath()
    }

    /// Adds a rounded rectangle subpath with uniform corner radius.
    public mutating func addRoundedRect(_ rect: Rect, cornerRadius: Float) {
        let r = min(cornerRadius, min(rect.width, rect.height) * 0.5)
        let kappa: Float = 0.5522847498
        let k = r * kappa

        move(to: Vector2(rect.minX + r, rect.minY))
        addLine(to: Vector2(rect.maxX - r, rect.minY))
        addCurve(to: Point(rect.maxX, rect.minY + r), control1: Point(rect.maxX - r + k, rect.minY), control2: Point(rect.maxX, rect.minY + r - k))
        addLine(to: Vector2(rect.maxX, rect.maxY - r))
        addCurve(to: Point(rect.maxX - r, rect.maxY), control1: Point(rect.maxX, rect.maxY - r + k), control2: Point(rect.maxX - r + k, rect.maxY))
        addLine(to: Vector2(rect.minX + r, rect.maxY))
        addCurve(to: Point(rect.minX, rect.maxY - r), control1: Point(rect.minX + r - k, rect.maxY), control2: Point(rect.minX, rect.maxY - r + k))
        addLine(to: Vector2(rect.minX, rect.minY + r))
        addCurve(to: Point(rect.minX + r, rect.minY), control1: Point(rect.minX, rect.minY + r - k), control2: Point(rect.minX + r - k, rect.minY))
        closeSubpath()
    }
}
