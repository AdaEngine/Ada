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
        self.modifier(DrawingGroupModifier(content: self, cachesContents: cachesContents))
    }
}

struct DrawingGroupModifier<Content: View>: ViewModifier, ViewNodeBuilder {
    typealias Body = Never
    let content: Content
    let cachesContents: Bool

    func buildViewNode(in context: BuildContext) -> ViewNode {
        DrawingGroupViewNode(
            contentNode: context.makeNode(from: content),
            content: content,
            cachesContents: cachesContents
        )
    }
}

class DrawingGroupViewNode: ViewModifierNode {
    private var cachesContents: Bool

    init<Content: View>(contentNode: ViewNode, content: Content, cachesContents: Bool) {
        self.cachesContents = cachesContents
        super.init(contentNode: contentNode, content: content)
    }

    override func update(from newNode: ViewNode) {
        guard let node = newNode as? DrawingGroupViewNode else {
            return
        }
        cachesContents = node.cachesContents
        super.update(from: newNode)
        invalidateLayerIfNeeded()
    }

    override func draw(with context: UIGraphicsContext) {
        var context = context
        context.allowsLayerCaching = context.allowsLayerCaching && cachesContents
        context.translateBy(x: frame.origin.x, y: -frame.origin.y)

        if let layer {
            layer.drawLayer(in: context)
        }
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
