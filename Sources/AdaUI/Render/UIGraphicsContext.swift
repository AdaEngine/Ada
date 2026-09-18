//
//  UIGraphicsContext.swift
//  AdaEngine
//
//  Created by v.prusakov on 5/16/22.
//

import AdaApp
import AdaRender
import AdaText
import AdaUtils
import Collections
import Foundation
import Math

/// An immediate mode drawing destination, and its current state.
///
/// Use a context to execute 2D drawing primitives.
///
/// ```swift
/// // Draw plain rect.
/// func draw(in context: inout UIGraphicsContext) {
///     context.drawRect(Rect(x: 0, y: 0, width: 100, height: 30), color: .red)
/// }
/// ```
///
/// ```swift
/// // Draw rect with scale and opacity
/// func draw(in context: inout UIGraphicsContext) {
///     var context = context
///     context.opacity = 0.5
///     context.scaledBy(x: 2, y: 2)
///     context.drawRect(Rect(x: 0, y: 0, width: 100, height: 30), color: .red)
/// }
/// ```
///
/// The context has access to an ``AdaUtils/EnvironmentValues`` instance called
/// ``environment`` that’s initially copied from the environment of its enclosing
/// view or entity. You can also access values stored in the environment for your
/// own purposes.
public struct UIGraphicsContext: Sendable {
    public enum PathDrawingMode: Sendable, Equatable {
        case legacy
        case fill(color: Color)
        case stroke(color: Color, style: StrokeStyle)
    }

    /// Returns current transform.
    public private(set) var transform: Transform3D = .identity
    private var clipPath: Path?

    /// The opacity of drawing operations in the context.
    ///
    /// Set this value to affect the opacity of content that you subsequently draw into the context.
    /// Changing this value has no impact on the content you previously drew into the context.
    public var opacity: Float = 1

    /// Whether descendants may reuse recorded and tessellated layer contents.
    public var allowsLayerCaching: Bool = true

    /// The environment associated with the graphics context.
    public var environment: EnvironmentValues = EnvironmentValues()

    /// Optional dirty rectangle in window coordinates.
    public var dirtyRect: Rect?

    /// Window this draw context belongs to. A nil value renders into every window camera.
    public var windowId: WindowID?

    private(set) var commandQueue = CommandQueue()

    /// Create graphics context.
    public init() {}

    /// Appends the given transform to the context’s existing transform.
    /// - Parameter matrix: A transform to append to the existing transform.
    public mutating func concatenate(_ transform: Transform3D) {
        self.transform = transform * self.transform
    }

    /// Moves subsequent drawing operations by an amount in each dimension.
    /// - Parameter x: The amount to move in the horizontal direction.
    /// - Parameter y: The amount to move in the vertical direction.
    public mutating func translateBy(x: Float, y: Float) {
        let translationMatrix = Transform3D(translation: [x, y, 0])
        self.transform = translationMatrix * self.transform
    }

    /// Scales subsequent drawing operations by an amount in each dimension.
    /// - Parameter x: The amount to scale in the horizontal direction.
    /// - Parameter y: The amount to scale in the vertical direction.
    public mutating func scaleBy(x: Float, y: Float) {
        let scaleMatrix = Transform3D(scale: [x, y, 1])
        self.transform = scaleMatrix * self.transform
    }

    /// Rotates subsequent drawing operations by an angle.
    /// - Parameter angle: The amount to rotate.
    public mutating func rotate(by angle: Angle) {
        self.transform = Transform3D(quat: Quat(axis: Vector3(0, 0, 1), angle: angle.radians)) * self.transform
    }

    /// Clear any applied transform
    public mutating func clearTransform() {
        self.transform = .identity
    }

    mutating func setTransform(_ transform: Transform3D) {
        self.transform = transform
    }

    // MARK: - Drawing

    /// Paints the area contained within the provided rectangle, using the passed color.
    public func drawRect(_ rect: Rect, color: Color) {
        self.drawRect(rect, texture: nil, color: applyOpacityIfNeeded(color))
    }

    /// Paints the area contained within the provided rectangle, using the passed color and texture.
    public func drawRect(_ rect: Rect, texture: Texture2D? = nil, color: Color) {
        let transform = self.transform * rect.toTransform3D
        self.commandQueue.push(.drawQuad(transform: transform, texture: texture, color: applyOpacityIfNeeded(color)))
    }

    /// Paints the provided rectangle using a reflected UI shader material.
    public func drawShaderEffect(_ rect: Rect, material: Material) {
        let transform = self.transform * rect.toTransform3D
        self.commandQueue.push(.drawShaderEffect(transform: transform, material: material))
    }

    /// Paints the area of the ellipse that fits inside the provided rectangle, using the fill color in the current graphics state.
    public func drawEllipse(
        in rect: Rect,
        color: Color,
        thickness: Float = 1
    ) {
        let transform = self.transform * rect.toTransform3D
        self.commandQueue.push(
            .drawCircle(
                transform: transform,
                thickness: thickness,
                fade: 0.005,
                color: applyOpacityIfNeeded(color)
            )
        )
    }

    /// Paints the area contained within the provided rectangle, using the passed linear gradient.
    func drawLinearGradient(_ gradient: ResolvedLinearGradient, in rect: Rect) {
        let transform = self.transform * rect.toTransform3D
        self.commandQueue.push(
            .drawLinearGradient(
                transform: transform,
                startPoint: gradient.startPoint,
                endPoint: gradient.endPoint,
                stops: gradient.applyingOpacity(self.opacity).stops
            )
        )
    }

    /// Draws line into the graphics context.
    public func drawLine(start: Vector2, end: Vector2, lineWidth: Float, color: Color) {
        let start = (transform * Vector4(start.x, start.y, 0, 1))
        let end = (transform * Vector4(end.x, end.y, 0, 1))
        self.commandQueue.push(
            .drawLine(
                start: start.xyz,
                end: end.xyz,
                lineWidth: lineWidth,
                color: applyOpacityIfNeeded(color)
            )
        )
    }

    // MARK: - Text Drawing

    /// Draws text into the graphics context.
    public func drawText(in rect: Rect, from textLayout: TextLayoutManager) {
        let transform = self.transform * rect.toTransform3D
        self.commandQueue.push(
            .drawText(
                textLayout: textLayout,
                transform: transform,
                opacity: self.opacity
            )
        )
    }

    /// Draws attributed text into the graphics context.
    public func drawText(_ text: AttributedText, in rect: Rect) {
        let layout = TextLayoutManager()
        layout.setTextContainer(TextContainer(text: text))
        layout.fitToSize(rect.size)
        let transform = self.transform * rect.toTransform3D
        self.commandQueue.push(.drawText(textLayout: layout, transform: transform, opacity: self.opacity))
    }

    /// Draws path into the graphics context.
    public func draw(_ path: Path) {
        self.commandQueue.push(.drawPath(path, transform: self.transform, .legacy))
    }

    /// Fills a path with the provided color.
    public func fill(_ path: Path, with color: Color) {
        self.commandQueue.push(
            .drawPath(
                path,
                transform: self.transform,
                .fill(color: applyOpacityIfNeeded(color))
            )
        )
    }

    /// Strokes a path with the provided color and style.
    public func stroke(_ path: Path, with color: Color, style: StrokeStyle) {
        self.commandQueue.push(
            .drawPath(
                path,
                transform: self.transform,
                .stroke(
                    color: applyOpacityIfNeeded(color),
                    style: style
                )
            )
        )
    }

    /// Draws text line into the graphics context.
    @inlinable
    public func draw(_ line: TextLine) {
        for run in line {
            self.draw(run)
        }
    }

    /// Draws text run into the graphics context.
    @inlinable
    public func draw(_ run: TextRun) {
        for glyph in run {
            self.draw(glyph)
        }
    }

    /// Draws text glyph into the graphics context.
    public func draw(_ glyph: Glyph) {
        // Use identity transform - glyph.position already contains correct pixel coordinates
        // The current context transform will be applied during tessellation
        self.commandQueue.push(.drawGlyph(glyph, transform: self.transform, opacity: self.opacity))
    }

    /// Commits draws.
    public func commitDraw() {
        self.commandQueue.push(.commit)
    }

    /// Pushes a clipping rectangle in the current coordinate space.
    public mutating func pushClipRect(_ rect: Rect) {
        let scale = max(environment.scaleFactor, 1)
        let scaledRect = Rect(
            x: rect.minX * scale,
            y: rect.minY * scale,
            width: rect.width * scale,
            height: rect.height * scale
        )
        let minX = max(0, scaledRect.minX)
        let minY = max(0, scaledRect.minY)
        let maxX = max(0, scaledRect.maxX)
        let maxY = max(0, scaledRect.maxY)
        let clipped = Rect(
            x: minX,
            y: minY,
            width: max(0, maxX - minX),
            height: max(0, maxY - minY)
        )
        commandQueue.push(.pushClipRect(clipped))
    }

    /// Pushes a local clipping rectangle after applying the current transform.
    ///
    /// - Returns: `false` when the transformed rectangle is not axis-aligned and
    ///   therefore cannot be represented by a GPU scissor rectangle.
    mutating func pushTransformedClipRect(_ rect: Rect) -> Bool {
        let corners = [
            Vector4(rect.minX, -rect.minY, 0, 1),
            Vector4(rect.maxX, -rect.minY, 0, 1),
            Vector4(rect.maxX, -rect.maxY, 0, 1),
            Vector4(rect.minX, -rect.maxY, 0, 1),
        ]
        .map { transform * $0 }
        let horizontalEdge = corners[1] - corners[0]
        let verticalEdge = corners[3] - corners[0]
        let epsilon: Float = 0.0001
        let preservesAxes = abs(horizontalEdge.y) <= epsilon && abs(verticalEdge.x) <= epsilon
        let swapsAxes = abs(horizontalEdge.x) <= epsilon && abs(verticalEdge.y) <= epsilon
        guard preservesAxes || swapsAxes else {
            return false
        }

        let minX = corners.map(\.x).min() ?? 0
        let maxX = corners.map(\.x).max() ?? 0
        let minY = corners.map(\.y).min() ?? 0
        let maxY = corners.map(\.y).max() ?? 0
        pushClipRect(
            Rect(
                x: minX,
                y: -maxY,
                width: maxX - minX,
                height: maxY - minY
            )
        )
        return true
    }

    /// Pops the current clipping rectangle.
    public func popClipRect() {
        commandQueue.push(.popClipRect)
    }

    /// Pushes a clipping path in the current coordinate space.
    public func pushClipPath(_ path: Path) {
        commandQueue.push(.pushClipPath(path, transform: self.transform))
    }

    /// Pops the current clipping path.
    public func popClipPath() {
        commandQueue.push(.popClipPath)
    }

    /// Executes drawing with a clipping rectangle.
    public mutating func clip(to rect: Rect, draw: (inout Self) -> Void) {
        pushClipRect(rect)
        draw(&self)
        popClipRect()
    }

    /// Executes drawing with a clipping path.
    public mutating func clip(to path: Path, draw: (inout Self) -> Void) {
        pushClipPath(path)
        draw(&self)
        popClipPath()
    }

    @inlinable
    func applyOpacityIfNeeded(_ color: Color) -> Color {
        if color == .clear {
            return color
        }

        return color.opacity(color.alpha * self.opacity)
    }
}

extension Rect {
    var toTransform3D: Transform3D {
        Transform3D(
            translation: [self.midX, -self.midY, 0],
            rotation: .identity,
            scale: [self.size.width, self.size.height, 1]
        )
    }
}

extension UIGraphicsContext {
    /// Returns recorded draw commands.
    /// Use it for tesselation.
    public func getDrawCommands() -> [DrawCommand] {
        self.commandQueue.snapshot()
    }

    /// Thread-safe draw command buffer used by Sendable graphics contexts.
    final class CommandQueue: @unchecked Sendable {
        private let lock = NSLock()
        private var commands: [DrawCommand] = []

        func push(_ command: DrawCommand) {
            lock.lock()
            defer { lock.unlock() }
            commands.append(command)
        }

        func push(contentsOf newCommands: [DrawCommand]) {
            lock.lock()
            defer { lock.unlock() }
            commands.append(contentsOf: newCommands)
        }

        func pushLayer(id: UInt64, version: UInt64, cacheable: Bool, commands layerCommands: [DrawCommand]) {
            lock.lock()
            defer { lock.unlock() }
            commands.reserveCapacity(commands.count + layerCommands.count + 2)
            commands.append(.beginLayer(id: id, version: version, cacheable: cacheable))
            commands.append(contentsOf: layerCommands)
            commands.append(.endLayer(id: id))
        }

        func snapshot() -> [DrawCommand] {
            lock.lock()
            defer { lock.unlock() }
            return commands
        }
    }

    /// The commands that Graphic Context recorded.
    public enum DrawCommand: Sendable {
        case beginLayer(id: UInt64, version: UInt64, cacheable: Bool)
        case endLayer(id: UInt64)
        case pushClipRect(Rect)
        case popClipRect
        case pushClipPath(Path, transform: Transform3D)
        case popClipPath
        case setLineWidth(Float)
        case drawLine(start: Vector3, end: Vector3, lineWidth: Float, color: Color)

        case drawQuad(transform: Transform3D, texture: Texture2D? = nil, color: Color)
        case drawShaderEffect(transform: Transform3D, material: Material)
        case drawCircle(
            transform: Transform3D,
            thickness: Float,
            fade: Float,
            color: Color
        )
        case drawLinearGradient(transform: Transform3D, startPoint: Vector2, endPoint: Vector2, stops: [Gradient.Stop])
        case drawPath(Path, transform: Transform3D, PathDrawingMode)

        case drawText(textLayout: TextLayoutManager, transform: Transform3D, opacity: Float)
        case drawGlyph(_ glyph: Glyph, transform: Transform3D, opacity: Float)
        case drawGlassRect(transform: Transform3D, halfSize: Vector2, configuration: Glass, scaleFactor: Float)
        case commit
    }
}

extension UIGraphicsContext.DrawCommand {
    static func drawQuad(position: Vector3, size: Vector2, texture: Texture2D?, color: Color) -> Self {
        let transform = Transform3D(translation: position) * Transform3D(scale: Vector3(size, 1))
        return .drawQuad(transform: transform, texture: texture, color: color)
    }

    static func drawCircle(
        position: Vector3,
        rotation: Vector3,
        radius: Float,
        thickness: Float,
        fade: Float,
        color: Color
    ) -> Self {
        let transform =
            Transform3D(translation: position)
            * Transform3D(quat: Quat(axis: [1, 0, 0], angle: rotation.x))
            * Transform3D(quat: Quat(axis: [0, 1, 0], angle: rotation.y))
            * Transform3D(quat: Quat(axis: [0, 0, 1], angle: rotation.z))
            * Transform3D(scale: Vector3(radius))

        return .drawCircle(transform: transform, thickness: thickness, fade: fade, color: color)
    }
}
