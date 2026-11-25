//
//  DrawingGroupModifier.swift
//  AdaEngine
//
//  Created by vladislav.prusakov on 31.07.2024.
//

import Math

extension View {
    public func drawingGroup() -> some View {
        drawingGroup(cachesContents: true)
    }

    /// Groups drawing commands. Set `cachesContents` to false to redraw this entire subtree.
    public func drawingGroup(cachesContents: Bool) -> some View {
        self.modifier(DrawingGroupModifier(content: self, cachesContents: cachesContents, scrollDrawOutset: nil))
    }

    /// Groups bounded drawing and skips it when the group is outside its scroll viewport.
    /// Use for content whose drawing extends at most `outset` points beyond its layout bounds.
    @_spi(AdaEngine)
    public func drawingGroup(cullingOutsideScrollViewWithOutset outset: Float) -> some View {
        self.modifier(DrawingGroupModifier(content: self, cachesContents: true, scrollDrawOutset: max(0, outset)))
    }
}

struct DrawingGroupModifier<Content: View>: ViewModifier, ViewNodeBuilder {
    typealias Body = Never
    let content: Content
    let cachesContents: Bool
    let scrollDrawOutset: Float?

    func buildViewNode(in context: BuildContext) -> ViewNode {
        DrawingGroupViewNode(
            contentNode: context.makeNode(from: content),
            content: content,
            cachesContents: cachesContents,
            scrollDrawOutset: scrollDrawOutset
        )
    }
}

class DrawingGroupViewNode: ViewModifierNode {
    private var cachesContents: Bool
    private var scrollDrawOutset: Float?

    init<Content: View>(contentNode: ViewNode, content: Content, cachesContents: Bool, scrollDrawOutset: Float?) {
        self.cachesContents = cachesContents
        self.scrollDrawOutset = scrollDrawOutset
        super.init(contentNode: contentNode, content: content)
    }

    override func update(from newNode: ViewNode) {
        guard let node = newNode as? DrawingGroupViewNode else {
            return
        }
        cachesContents = node.cachesContents
        scrollDrawOutset = node.scrollDrawOutset
        super.update(from: newNode)
        invalidateLayerIfNeeded()
    }

    override func draw(with context: UIGraphicsContext) {
        if let outset = scrollDrawOutset, let scroll = nearestScrollView() {
            let frame = visualAbsoluteFrame()
            let drawBounds = Rect(
                x: frame.minX - outset,
                y: frame.minY - outset,
                width: frame.width + 2 * outset,
                height: frame.height + 2 * outset
            )
            guard drawBounds.intersects(scroll.visualAbsoluteFrame()) else {
                return
            }
        }
        var context = context
        context.allowsLayerCaching = context.allowsLayerCaching && cachesContents
        context.translateBy(x: frame.origin.x, y: -frame.origin.y)

        if let layer {
            layer.drawLayer(in: context)
        }
    }

    private func nearestScrollView() -> ScrollViewNode? {
        var ancestor = parent
        while let node = ancestor {
            if let scrollView = node as? ScrollViewNode {
                return scrollView
            }
            ancestor = node.parent
        }
        return nil
    }

    override func performLayout() {
        super.performLayout()
        invalidateLayerIfNeeded()
    }

    override func createLayer() -> UILayer? {
        let layer = UILayer(frame: self.frame) { [weak self] context, _ in
            guard let self else {
                return
            }
            self.contentNode.draw(with: context)
        }
        layer.debugLabel = "Drawing Group \(self.accessibilityIdentifier ?? "")"
        layer.propagatesInvalidation = false
        return layer
    }
}
