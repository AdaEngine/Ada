//
//  UILabel.swift
//  AdaEngine
//
//  Created by Vladislav Prusakov on 14.06.2024.
//

import AdaText
import AdaUtils
import Math

/// A view that displays one or more lines of informational text.
@MainActor
open class UILabel: UIView {
    /// The text that the label displays.
    public var text: String = "" {
        didSet {
            updateTextLayoutManager()
        }
    }

    /// The color of the text.
    public var textColor: Color = .white {
        didSet {
            updateTextLayoutManager()
        }
    }

    /// The font of the text.
    public var font: Font = .system(size: 17) {
        didSet {
            updateTextLayoutManager()
        }
    }

    /// The styled text that the label displays.
    public var attributedString: AttributedText? {
        didSet {
            updateTextLayoutManager()
        }
    }

    private var textContainer = TextContainer()
    private var textLayout = TextLayoutManager()

    override open func draw(in rect: Rect, with context: UIGraphicsContext) {
        context.drawText(in: rect, from: self.textLayout)
    }

    override open func layoutSubviews() {
        super.layoutSubviews()

        self.textLayout.setTextContainer(self.textContainer)
        self.textLayout.fitToSize(self.frame.size)
    }

    private func updateTextLayoutManager() {
        if let attributedString {
            self.textContainer.text = attributedString
        } else {
            var container = TextAttributeContainer()
            container.font = self.font
            container.foregroundColor = self.textColor
            let attributedString = AttributedText(self.text, attributes: container)
            self.textContainer.text = attributedString
        }

        self.textLayout.setTextContainer(self.textContainer)
        self.textLayout.invalidateLayout()
        self.setNeedsLayout()
        self.setNeedsDisplay()
    }
}
