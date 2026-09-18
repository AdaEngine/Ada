//
//  Shape.swift
//  AdaEngine
//
//  Created by vladislav.prusakov on 31.07.2024.
//

import AdaAnimation
import AdaUtils
import Math

/// A type that resolves into a concrete fill or stroke color for shapes.
public protocol ShapeStyle {
    func resolve(in environment: EnvironmentValues) -> Color
}

extension Color: ShapeStyle {
    public func resolve(in _: EnvironmentValues) -> Color {
        self
    }
}

/// A set of stroke attributes to apply when stroking a shape.
public struct StrokeStyle: Sendable, Equatable {
    public var lineWidth: Float

    public init(lineWidth: Float = 1) {
        self.lineWidth = lineWidth
    }
}

/// A protocol that defines a shape.
public protocol Shape: View, Animatable {
    /// The path of the shape.
    ///
    /// - Parameter rect: The rect of the shape.
    /// - Returns: The path of the shape.
    func path(in rect: Rect) -> Path

    /// The size that fits the shape.
    ///
    /// - Parameter proposal: The proposed size.
    /// - Returns: The size that fits the shape.
    func sizeThatFits(_ proposal: ProposedViewSize) -> Size
}

extension Shape {
    public var body: some View {
        _ShapeView(shape: self)
    }
}

enum ShapeRenderMode: Sendable, Equatable {
    case legacy
    case fill(Color)
    case stroke(Color, StrokeStyle)
}

struct _ShapeView<S: Shape>: View, ViewNodeBuilder {
    let shape: S
    var body: Never { fatalError("Unreachable code") }

    func buildViewNode(in _: BuildContext) -> ViewNode {
        ShapeViewNode(shape: shape, renderMode: .legacy, content: self)
    }
}

struct _ShapeStyledView<S: Shape, Style: ShapeStyle>: View, ViewNodeBuilder {
    enum Kind: Sendable, Equatable {
        case fill
        case stroke(StrokeStyle)
    }

    let shape: S
    let style: Style
    let kind: Kind
    var body: Never { fatalError("Unreachable code") }

    func buildViewNode(in context: BuildContext) -> ViewNode {
        let color = style.resolve(in: context.environment)
        let renderMode: ShapeRenderMode

        switch kind {
        case .fill:
            renderMode = .fill(color)
        case let .stroke(strokeStyle):
            renderMode = .stroke(color, strokeStyle)
        }

        return ShapeViewNode(shape: shape, renderMode: renderMode, content: self)
    }
}

public typealias CircleShape = Circle

/// A circle shape.
public struct Circle: Shape {
    public typealias AnimatableData = EmptyAnimatableData

    public init() {}

    public func path(in rect: Rect) -> Path {
        var path = Path()
        path.addEllipse(in: rect)
        return path
    }
}

public typealias RectangleShape = Rectangle

/// A rectangle shape.
public struct Rectangle: Shape {
    public typealias AnimatableData = EmptyAnimatableData

    public init() {}

    public func path(in rect: Rect) -> Path {
        var path = Path()
        path.addRect(rect)
        return path
    }
}

public typealias CapsuleShape = Capsule

/// A capsule shape — a rectangle with fully rounded ends.
public struct Capsule: Shape {
    public typealias AnimatableData = EmptyAnimatableData

    public init() {}

    public func path(in rect: Rect) -> Path {
        var path = Path()
        path.addRoundedRect(rect, cornerRadius: min(rect.width, rect.height) * 0.5)
        return path
    }
}

public typealias RoundedRectangleShape = RoundedRectangle

/// A rectangle shape with a uniform corner radius.
public struct RoundedRectangle: Shape {
    public typealias AnimatableData = Float

    public var cornerRadius: Float

    public init(cornerRadius: Float) {
        self.cornerRadius = cornerRadius
    }

    public var animatableData: Float {
        get { cornerRadius }
        set { cornerRadius = newValue }
    }

    public func path(in rect: Rect) -> Path {
        var path = Path()
        path.addRoundedRect(rect, cornerRadius: cornerRadius)
        return path
    }
}

/// A shape view node.
@MainActor
class ShapeViewNode<S: Shape>: ViewNode {
    private var shape: S
    private var renderMode: ShapeRenderMode
    private var path: Path = Path()

    /// Initialize a new shape view node.
    ///
    /// - Parameters:
    ///   - shape: The shape.
    ///   - content: The content.
    init<Content: View>(shape: S, renderMode: ShapeRenderMode, content: Content) {
        self.shape = shape
        self.renderMode = renderMode
        super.init(content: content)
    }

    /// Perform the layout of the shape view node.
    override func performLayout() {
        super.performLayout()

        updatePath()
    }

    /// Draw the shape view node.
    ///
    /// - Parameter context: The context.
    override func draw(with context: UIGraphicsContext) {
        var context = context
        context.environment = self.environment
        context.translateBy(x: self.frame.origin.x, y: -self.frame.origin.y)
        switch renderMode {
        case .legacy:
            context.draw(path)
        case let .fill(color):
            context.fill(path, with: color)
        case let .stroke(color, style):
            context.stroke(path, with: color, style: style)
        }
    }

    /// Update the shape view node from a new node.
    ///
    /// - Parameter newNode: The new node.
    override func update(from newNode: ViewNode) {
        guard let otherNode = newNode as? Self else {
            super.update(from: newNode)
            return
        }

        let startData = self.shape.animatableData
        let endData = otherNode.shape.animatableData
        let animationController =
            self.environment.animationController
            ?? otherNode.environment.animationController
            ?? nearestAnimationController()

        super.update(from: newNode)

        self.renderMode = otherNode.renderMode

        if let animationController, (startData - endData).magnitudeSquared > 0 {
            self.shape = otherNode.shape
            self.shape.animatableData = startData
            updatePath()

            animationController.addTweenAnimation(
                from: TweenValue(animatableData: startData),
                to: TweenValue(animatableData: endData),
                label: "shape-\(self.id)",
                environment: self.environment,
                updateBlock: { [weak self] value in
                    guard let self else {
                        return
                    }
                    self.shape.animatableData = value.animatableData
                    self.updatePath()
                    self.invalidateNearestLayer()
                    self.owner?.containerView?.setNeedsDisplay(in: self.absoluteFrame())
                }
            )
        } else {
            self.shape = otherNode.shape
            updatePath()
            invalidateNearestLayer()
        }
    }

    /// The size that fits the shape view node.
    ///
    /// - Parameter proposal: The proposed size.
    /// - Returns: The size that fits the shape view node.
    override func sizeThatFits(_ proposal: ProposedViewSize) -> Size {
        return shape.sizeThatFits(proposal)
    }

    private func updatePath() {
        self.path = self.shape.path(in: Rect(origin: .zero, size: self.frame.size))
    }
}

extension Shape {
    public func fill<S: ShapeStyle>(_ style: S) -> some View {
        _ShapeStyledView(shape: self, style: style, kind: .fill)
    }

    public func stroke<S: ShapeStyle>(_ style: S, style strokeStyle: StrokeStyle = .init()) -> some View {
        _ShapeStyledView(shape: self, style: style, kind: .stroke(strokeStyle))
    }

    public func stroke<S: ShapeStyle>(_ style: S, lineWidth: Float = 1) -> some View {
        self.stroke(style, style: StrokeStyle(lineWidth: lineWidth))
    }

    /// The size that fits the shape.
    ///
    /// - Parameter proposal: The proposed size.
    /// - Returns: The size that fits the shape.
    public func sizeThatFits(_ proposal: ProposedViewSize) -> Size {
        return proposal.replacingUnspecifiedDimensions()
    }
}

extension Shape where Self == Capsule {
    public static var capsule: Capsule { Capsule() }
}

extension Shape where Self == Circle {
    public static var circle: Circle { Circle() }
}

extension Shape where Self == Rectangle {
    public static var rectangle: Rectangle { Rectangle() }
}

extension Shape where Self == RoundedRectangle {
    public static func rect(cornerRadius: Float) -> RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius)
    }
}
