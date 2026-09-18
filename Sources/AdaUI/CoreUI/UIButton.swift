//
//  UIButton.swift
//  AdaEngine
//
//  Created by Vladislav Prusakov on 18.06.2024.
//

import AdaInput
import AdaRender
import AdaText
import AdaUtils
import Math

/// A button UI element.
open class UIButton: UIControl {
    /// A button style.
    private struct ButtonStyle {
        /// The icon of the button style.
        var icon: Texture2D?
        /// The background color of the button style.
        var backgroundColor: Color?
        /// The text container of the button style.
        var textContainer = TextContainer(text: "Button") {
            didSet {
                textLayout.setTextContainer(self.textContainer)
            }
        }

        /// The text layout manager of the button style.
        let textLayout = TextLayoutManager()
    }

    private var styles: [State: ButtonStyle] = [:]

    // MARK: - Style Configuration

    /// Set the icon for the button style.
    ///
    /// - Parameters:
    ///   - texture: The texture to set for the button style.
    ///   - state: The state to set the icon for.
    public func setIcon(_ texture: Texture2D?, for state: State) {
        self.styles[state, default: ButtonStyle()].icon = texture
        setNeedsDisplay()
    }

    /// Set the background color for the button style.
    ///
    /// - Parameters:
    ///   - color: The color to set for the button style.
    ///   - state: The state to set the background color for.
    public func setBackgroundColor(_ color: Color, for state: State) {
        self.styles[state, default: ButtonStyle()].backgroundColor = color
        setNeedsDisplay()
    }

    /// Set the attributed text for the button style.
    ///
    /// - Parameters:
    ///   - text: The attributed text to set for the button style.
    ///   - state: The state to set the attributed text for.
    public func setAttributedText(_ text: AttributedText, for state: State) {
        self.styles[state, default: ButtonStyle()].textContainer.text = text
        setNeedsDisplay()
    }

    /// Draw the button in the given rect with the given context.
    ///
    /// - Parameters:
    ///   - rect: The rect to draw the button in.
    ///   - context: The context to draw the button in.
    override open func draw(in rect: Rect, with context: UIGraphicsContext) {
        let style = self.styles[self.state]
        let color = style?.backgroundColor ?? self.backgroundColor
        context.drawRect(rect, color: color)

        if let textLayout = style?.textLayout {
            context.drawText(in: rect, from: textLayout)
        }

        if let texture = style?.icon {
            context.drawRect(rect, texture: texture, color: .white)
        }
    }

    /// Handle the mouse event.
    ///
    /// - Parameter event: The mouse event to handle.
    override open func onMouseEvent(_ event: MouseEvent) {
        if !self.state.isEnabled {
            return
        }

        super.onMouseEvent(event)

        switch event.phase {
        case .began:
            self.triggerActions(for: .touchDown)
        case .changed:
            self.triggerActions(for: .touchDragInside)
        case .ended:
            self.triggerActions(for: .touchUp)
        case .cancelled:
            self.triggerActions(for: .touchCancel)
        }
    }
}
