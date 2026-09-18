//
//  TextComponent.swift
//  AdaEngine
//
//  Created by v.prusakov on 3/5/23.
//

import AdaECS
import Math

/// Component for rendering text on scene.
@Component
public struct TextComponent {
    /// Text with style attributes.
    public var text: AttributedText

    public var textAlignment: TextAlignment

    /// Specify render bounds for text. If bounds has infinity width and/or height, than text will render without restrictions.
    /// If bounds has restricted size, than text will clipped.
    public var bounds: Rect

    public var lineBreakMode: LineBreakMode

    public var lineSpacing: Float

    public init(
        text: AttributedText,
        textAlignment: TextAlignment = .center,
        bounds: Rect = Rect(x: 0, y: 0, width: .infinity, height: .infinity),
        lineBreakMode: LineBreakMode = .byCharWrapping,
        lineSpacing: Float = 0
    ) {
        self.text = text
        self.textAlignment = textAlignment
        self.bounds = bounds
        self.lineBreakMode = lineBreakMode
        self.lineSpacing = lineSpacing
    }
}
