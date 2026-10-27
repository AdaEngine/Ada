//
//  TextViewNode.swift
//  AdaEngine
//
//  Created by Vladislav Prusakov on 07.06.2024.
//

import AdaInput
import Foundation
import AdaText
import AdaUtils
import Math

final class TextViewNode: ViewNode {
    var selectionEnabled = false
    var selectionAnchor: String.Index?
    var selectionHead: String.Index?
    var selectionIsDragging = false
    var selectionIsFocused = false
    var drawnTextOffset: Point = .zero
    var selectableText: String { textContainer.text.text }
    var selectionLayout: TextLayoutManager { drawLayoutManager }
    var layoutManager: TextLayoutManager
    private var drawLayoutManager: TextLayoutManager
    private var textContainer: TextContainer {
        didSet {
            guard self.textContainer != oldValue else {
                return
            }

            self.layoutManager.setTextContainer(self.textContainer)
            self.drawLayoutManager.setTextContainer(self.textContainer)
            self.sizeCache = [:]
            Self.recordLayoutMutationRequiringAncestorPass()
            self.invalidateNearestLayer()
            owner?.containerView?.setNeedsLayout()
        }
    }

    private var textRenderer: any TextRenderer

    init(inputs: _ViewInputs, content: Text) {
        self.textContainer = Self.makeTextContainer(content: content, environment: inputs.environment)
        self.layoutManager = TextLayoutManager()
        self.layoutManager.setTextContainer(self.textContainer)
        self.drawLayoutManager = TextLayoutManager()
        self.drawLayoutManager.setTextContainer(self.textContainer)
        self.textRenderer = inputs.environment.textRenderer ?? DefaultRichTextRenderer()
        self.selectionEnabled = content.storage.selectionEnabled

        super.init(content: content)
        self.applyResolvedEnvironmentSilently(inputs.environment)
    }

    /// Cache the sizes while layoutmanager is consistent.
    /// If layout manager did change, we should drop cache sizes.
    private var sizeCache: [ProposedViewSize: Size] = [:]

    override func sizeThatFits(_ proposal: ProposedViewSize) -> Size {
        if let size = sizeCache[proposal] {
            return size
        }

        let size = self.textRenderer.sizeThatFits(
            proposal: proposal,
            text: Text.Proxy(layoutManager: self.layoutManager)
        )

        self.sizeCache[proposal] = size
        return size
    }

    override func draw(with context: UIGraphicsContext) {
        var context = context
        context.environment = environment
        super.draw(with: context)
        self.drawLayoutManager.fitToSize(self.frame.size)

        let scale = max(environment.scaleFactor, 1)
        func snapToPixel(_ value: Float) -> Float {
            ((value * scale).rounded()) / scale
        }

        context.translateBy(
            x: snapToPixel(self.frame.origin.x),
            y: -snapToPixel(self.frame.origin.y)
        )

        // Preserve the layout manager's horizontal alignment and side bearings.
        // Optical centering is only appropriate for explicitly centered text.
        var horizontalOffset: Float = 0
        var verticalOffset: Float = 0
        var exceedsBounds = self.drawLayoutManager.boundingSize().height > self.frame.height
        if !self.drawLayoutManager.textLines.isEmpty {
            var minX: Float = .infinity
            var maxX: Float = -.infinity
            var maxTopY: Float = -Float.infinity
            var minBottomY: Float = Float.infinity

            for line in self.drawLayoutManager.textLines {
                for run in line {
                    for glyph in run {
                        exceedsBounds = exceedsBounds || glyph.advanceX > self.frame.width
                        minX = min(minX, glyph.position.x)
                        maxX = max(maxX, glyph.position.z)
                        maxTopY = max(maxTopY, glyph.position.w)
                        minBottomY = min(minBottomY, glyph.position.y)
                    }
                }
            }

            if self.drawLayoutManager.resolvedTextAlignment == .center, minX.isFinite, maxX.isFinite {
                let textCenterX = (minX + maxX) / 2
                let frameCenterX = self.frame.size.width / 2
                horizontalOffset = frameCenterX - textCenterX
            }

            if maxTopY.isFinite, minBottomY.isFinite {
                let textCenterY = (maxTopY + minBottomY) / 2
                let frameCenterY = -self.frame.size.height / 2
                verticalOffset = frameCenterY - textCenterY
            }
        }

        self.drawLayout(
            in: &context,
            offset: Point(x: snapToPixel(horizontalOffset), y: snapToPixel(verticalOffset)),
            clipsToBounds: exceedsBounds
        )
    }

    private func drawLayout(in context: inout UIGraphicsContext, offset: Point, clipsToBounds: Bool) {
        // A proposal can be smaller than one glyph or one line. Keep drawing
        // within that constraint without treating atlas padding as overflow.
        let clipBounds = Rect(origin: .zero, size: self.frame.size)
        let usesClipRect = clipsToBounds && context.pushTransformedClipRect(clipBounds)
        let usesClipPath = clipsToBounds && !usesClipRect
        if usesClipPath {
            context.pushClipPath(RectangleShape().path(in: clipBounds))
        }
        context.translateBy(x: offset.x, y: offset.y)
        self.drawnTextOffset = offset
        self.drawSelection(in: &context)

        let layout = Text.Layout(lines: self.drawLayoutManager.textLines)
        self.textRenderer.draw(layout: layout, in: &context)
        if usesClipRect {
            context.popClipRect()
        } else if usesClipPath {
            context.popClipPath()
        }
    }

    override func update(from newNode: ViewNode) {
        super.update(from: newNode)

        guard let textNode = newNode as? TextViewNode else {
            return
        }

        self.textRenderer = textNode.textRenderer
        self.selectionEnabled = textNode.selectionEnabled
        if self.selectableText != textNode.selectableText {
            self.selectionAnchor = nil
            self.selectionHead = nil
        }
        self.textContainer = textNode.textContainer
    }

    override func updateEnvironment(_ environment: EnvironmentValues) {
        let previousEnvironment = self.environment
        super.updateEnvironment(environment)
        guard Self.textEnvironmentDidChange(from: previousEnvironment, to: self.environment) else {
            return
        }

        self.refreshTextContainer()
    }

    override func hitTest(_ point: Point, with event: any InputEvent) -> ViewNode? {
        if self.point(inside: point, with: event) {
            return self
        }
        return nil
    }

    override var canBecomeFocused: Bool { selectionEnabled && environment.isEnabled }

    override func onFocusChanged(isFocused: Bool) {
        selectionIsFocused = isFocused
        if !isFocused { selectionIsDragging = false }
        invalidateSelection()
    }

    override func onMouseEvent(_ event: MouseEvent) {
        guard selectionEnabled, environment.isEnabled else { return }
        owner?.window?.windowManager.setCursorShape(.iBeam)
        guard event.button == .left || selectionIsDragging else { return }
        let index = closestTextIndex(to: selectionPointFromRoot(event.mousePosition))
        switch event.phase {
        case .began:
            selectionIsDragging = true
            if !event.modifierKeys.contains(.shift) || selectionAnchor == nil { selectionAnchor = index }
            selectionHead = index
        case .changed:
            guard selectionIsDragging else { return }
            selectionHead = index
        case .ended, .cancelled:
            guard selectionIsDragging else { return }
            selectionHead = index
            selectionIsDragging = false
            if event.phase == .ended, selectedSourceRange == nil,
               let link = link(at: index), let url = URL(string: link),
               ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") {
                environment.openURL(url)
            }
        }
        invalidateSelection()
    }

    override func onMouseLeave() {
        if selectionEnabled { owner?.window?.windowManager.setCursorShape(.arrow) }
    }

    override func onKeyEvent(_ event: KeyEvent) {
        guard selectionEnabled, selectionIsFocused, event.status == .down else { return }
        if event.modifiers.contains(.main) || event.modifiers.contains(.control) {
            switch event.keyCode {
            case .a:
                selectionAnchor = selectableText.startIndex
                selectionHead = selectableText.endIndex
            case .c:
                if let range = selectedSourceRange { UIClipboard.setString(String(selectableText[range])) }
            default: return
            }
        } else if event.keyCode == .escape {
            selectionAnchor = nil
            selectionHead = nil
        }
        invalidateSelection()
    }

    private func refreshTextContainer() {
        guard let content = self.content as? Text else {
            return
        }

        self.textContainer = Self.makeTextContainer(content: content, environment: self.environment)
        self.invalidateNearestLayer()
        owner?.containerView?.setNeedsLayout()
    }

    private static func makeTextContainer(content: Text, environment: EnvironmentValues) -> TextContainer {
        let text = content.storage.applyingEnvironment(environment)
        var container = TextContainer(text: text)
        container.numberOfLines = content.storage.lineLimit
        container.lineBreakMode = content.storage.lineBreakMode ?? .byWordWrapping
        container.textAlignment = content.storage.multilineTextAlignment ?? .center
        container.writingDirection = environment.layoutDirection == .rightToLeft ? .rightToLeft : .leftToRight
        return container
    }

    private static func textEnvironmentDidChange(
        from previous: EnvironmentValues,
        to current: EnvironmentValues
    ) -> Bool {
        previous.font != current.font
            || previous.foregroundColor != current.foregroundColor
            || previous.lineLimit != current.lineLimit
            || previous.lineBreakMode != current.lineBreakMode
            || previous.multilineTextAlignment != current.multilineTextAlignment
            || previous.layoutDirection != current.layoutDirection
    }
}

struct DefaultRichTextRenderer: TextRenderer {
    func draw(layout: Text.Layout, in context: inout UIGraphicsContext) {
        for line in layout {
            for run in line {
                for glyph in run where glyph.attributes.fontTraits.contains(.code) {
                    let size = Float(glyph.attributes.font.pointSize)
                    context.drawRect(Rect(x: min(glyph.penOrigin.x, glyph.advanceX), y: -glyph.penOrigin.y - size * 0.9,
                        width: max(1, abs(glyph.advanceX - glyph.penOrigin.x)), height: size * 1.25),
                        color: glyph.attributes.foregroundColor.opacity(0.07))
                }
            }
            context.draw(line)
            for run in line {
                for glyph in run where glyph.attributes.link != nil {
                    context.drawRect(Rect(x: min(glyph.penOrigin.x, glyph.advanceX), y: -glyph.penOrigin.y + 2,
                        width: abs(glyph.advanceX - glyph.penOrigin.x), height: 1), color: context.environment.accentColor)
                }
            }
        }
    }
}
