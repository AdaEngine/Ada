import AdaUtils
import Math

/// Geometry is in the control's local coordinates, shared by drawing and touch capture.
struct TextSelectionHandle {
    enum Edge { case start, end }
    let edge: Edge
    let caret: Rect

    static let radius: Float = 4
    static let hitRadius: Float = 22

    var knobCenter: Point {
        Point(caret.minX, edge == .start ? caret.minY - Self.radius : caret.maxY + Self.radius)
    }

    func distanceSquared(to point: Point) -> Float {
        let dx = point.x - knobCenter.x
        let dy = point.y - knobCenter.y
        return dx * dx + dy * dy
    }

    func draw(in context: inout UIGraphicsContext, color: Color) {
        let stem = Rect(x: caret.minX - 1, y: caret.minY, width: 2, height: caret.height)
        context.drawRect(stem, color: color)
        let center = knobCenter
        let knob = Rect(x: center.x - Self.radius, y: center.y - Self.radius, width: Self.radius * 2, height: Self.radius * 2)
        context.fill(RoundedRectangleShape(cornerRadius: Self.radius).path(in: knob), with: color)
    }
}

struct TextSelectionHandles {
    let start: TextSelectionHandle
    let end: TextSelectionHandle

    func hitTest(_ point: Point) -> TextSelectionHandle? {
        let startDistance = start.distanceSquared(to: point)
        let endDistance = end.distanceSquared(to: point)
        guard min(startDistance, endDistance) <= TextSelectionHandle.hitRadius * TextSelectionHandle.hitRadius else {
            return nil
        }
        return startDistance <= endDistance ? start : end
    }

    func draw(in context: inout UIGraphicsContext, color: Color) {
        start.draw(in: &context, color: color)
        end.draw(in: &context, color: color)
    }
}

struct TextSelectionHandleDrag {
    let edge: TextSelectionHandle.Edge
    let fixedOffset: Int
    let grabOffset: Point

    init(handle: TextSelectionHandle, range: Range<Int>, point: Point) {
        edge = handle.edge
        fixedOffset = handle.edge == .start ? range.upperBound : range.lowerBound
        // Keep the endpoint under its original grip, including when grabbing the knob below a row.
        grabOffset = Point(point.x - handle.caret.minX, point.y - handle.caret.midY)
    }

    func caretPoint(for point: Point) -> Point {
        Point(point.x - grabOffset.x, point.y - grabOffset.y)
    }

    func movingOffset(_ offset: Int, textCount: Int) -> Int {
        switch edge {
        case .start: max(0, min(offset, fixedOffset - 1))
        case .end: min(textCount, max(offset, fixedOffset + 1))
        }
    }
}
