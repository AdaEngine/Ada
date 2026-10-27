import AdaInput
import AdaText
import AdaUtils
import Math

extension TextViewNode {
    func link(at index: String.Index) -> String? {
        for line in selectionLayout.textLines {
            for run in line {
                for glyph in run {
                    if glyph.sourceRange?.contains(index) == true { return glyph.attributes.link }
                }
            }
        }
        return nil
    }
    var selectedSourceRange: Range<String.Index>? {
        guard let anchor = selectionAnchor, let head = selectionHead, anchor != head else { return nil }
        return min(anchor, head)..<max(anchor, head)
    }

    func drawSelection(in context: inout UIGraphicsContext) {
        guard selectionEnabled, selectionIsFocused, let range = selectedSourceRange else { return }
        for line in selectionLayout.textLines {
            for run in line {
                for glyph in run {
                    guard let source = glyph.sourceRange, source.overlaps(range) else { continue }
                    let size = Float(glyph.attributes.font.pointSize)
                    context.drawRect(Rect(x: min(glyph.penOrigin.x, glyph.advanceX), y: -glyph.penOrigin.y - size * 0.9,
                        width: max(1, abs(glyph.advanceX - glyph.penOrigin.x)), height: size * 1.25),
                        color: environment.accentColor.opacity(0.28))
                }
            }
        }
    }

    func selectionPointFromRoot(_ point: Point) -> Point {
        var local = point
        var node: ViewNode = self
        while let parent = node.parent {
            local = node.convert(local, from: parent)
            node = parent
        }
        return Point(x: local.x - drawnTextOffset.x, y: local.y + drawnTextOffset.y)
    }

    func closestTextIndex(to point: Point) -> String.Index {
        selectionLayout.fitToSize(frame.size)
        var nearest = selectableText.startIndex
        var bestDistance: Float = .infinity
        for line in selectionLayout.textLines {
            for run in line {
                for glyph in run {
                    guard let range = glyph.sourceRange else { continue }
                    let size = Float(glyph.attributes.font.pointSize)
                    let top = -glyph.penOrigin.y - size * 0.9
                    let bottom = top + size * 1.25
                    let vertical = max(top - point.y, point.y - bottom, 0)
                    for (x, index) in [(glyph.penOrigin.x, range.lowerBound), (glyph.advanceX, range.upperBound)] {
                        let distance = vertical * vertical * 100 + (point.x - x) * (point.x - x)
                        if distance < bestDistance { nearest = index; bestDistance = distance }
                    }
                }
            }
        }
        return nearest
    }

    func invalidateSelection() {
        invalidateNearestLayer()
        owner?.containerView?.setNeedsDisplay(in: absoluteFrame())
    }
}
