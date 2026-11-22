//
//  Canvas.swift
//  AdaEngine
//
//  Created by Vladislav Prusakov on 21.06.2024.
//

import AdaInput
import AdaUtils
import Math

/// A view type that supports immediate mode drawing.
public struct Canvas: View, ViewNodeBuilder {
    public typealias RenderBlock = (inout UIGraphicsContext, Size) -> Void

    public typealias Body = Never
    public var body: Never { fatalError("Unreachable code") }

    let render: RenderBlock
    let drawingRevision: (() -> UInt64)?

    public init(render: @escaping RenderBlock) {
        self.render = render
        self.drawingRevision = nil
    }

    /// Retains drawing commands until the revision changes. The revision is read
    /// during updates to request display and again when drawing to use the latest value.
    @_spi(Internal)
    public init(drawingRevision: @escaping () -> UInt64, render: @escaping RenderBlock) {
        self.render = render
        self.drawingRevision = drawingRevision
    }

    func buildViewNode(in _: BuildContext) -> ViewNode {
        return CanvasViewNode(content: self, drawBlock: self.render, drawingRevision: drawingRevision)
    }
}

@MainActor
class CanvasViewNode: ViewNode {
    private(set) var drawBlock: Canvas.RenderBlock
    private var drawingRevision: (() -> UInt64)?
    private var recordedRevision: UInt64?
    private var requestedRevision: UInt64?

    init<Content: View>(content: Content, drawBlock: @escaping Canvas.RenderBlock, drawingRevision: (() -> UInt64)? = nil) {
        self.drawBlock = drawBlock
        self.drawingRevision = drawingRevision
        super.init(content: content)
    }

    override func update(_: TimeInterval) {
        guard owner?.containerView != nil, let drawingRevision else {
            return
        }
        let revision = drawingRevision()
        guard revision != recordedRevision, revision != requestedRevision else {
            return
        }
        requestedRevision = revision
        setNeedsDisplay()
    }

    override func draw(with context: UIGraphicsContext) {
        var context = context
        context.environment = self.environment
        context.translateBy(x: self.frame.origin.x, y: -self.frame.origin.y)
        if let drawingRevision {
            let revision = drawingRevision()
            if recordedRevision != revision || layer?.frame.size != frame.size {
                invalidateLayerIfNeeded()
                recordedRevision = revision
            }
            requestedRevision = nil
            layer?.drawLayer(in: context)
            return
        }
        self.drawBlock(&context, self.frame.size)
        super.draw(with: context)
    }

    override func update(from newNode: ViewNode) {
        super.update(from: newNode)

        guard let otherNode = newNode as? CanvasViewNode else {
            return
        }

        self.drawBlock = otherNode.drawBlock
        self.drawingRevision = otherNode.drawingRevision
        recordedRevision = nil
        requestedRevision = nil
        if drawingRevision == nil {
            layer = nil
        } else {
            invalidateLayerIfNeeded()
        }
    }

    override func createLayer() -> UILayer? {
        guard drawingRevision != nil else {
            return nil
        }
        let layer = UILayer(frame: frame) { [weak self] context, size in
            self?.drawBlock(&context, size)
        }
        layer.propagatesInvalidation = false
        return layer
    }

    override func sizeThatFits(_ proposal: ProposedViewSize) -> Size {
        return proposal.replacingUnspecifiedDimensions()
    }

    override func hitTest(_: Point, with _: any InputEvent) -> ViewNode? {
        // Canvas is a drawing-only primitive; it should not intercept pointer/touch events
        // from interactive content rendered below (e.g. buttons in an overlayed card).
        nil
    }

    override func point(inside _: Point, with _: any InputEvent) -> Bool {
        false
    }
}
