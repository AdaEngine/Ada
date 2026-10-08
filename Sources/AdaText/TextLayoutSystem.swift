//
//  TextLayoutSystem.swift
//  AdaEngine
//
//  Created by v.prusakov on 3/7/23.
//

import AdaECS
import AdaRender
import AdaTransform
import Math

/// An object that store text layout manager
@Component
public struct TextLayoutComponent {
    public let textLayout: TextLayoutManager
}

/// System for layout text from ``Text2DComponent``.
@PlainSystem
public struct TextLayoutSystem {
    @FilterQuery<
        Ref<TextComponent>,
        Ref<TextLayoutComponent>,
        Visibility,
        Or<
            Changed<TextComponent>,
            Added<Transform>,
            Changed<Transform>
        >
    >
    private var textComponents

    public init(world _: World) {}

    public func update(context _: UpdateContext) {
        self.textComponents.forEach { text, layout, visibility in
            if visibility == .hidden {
                return
            }

            let textContainer = TextContainer(
                text: text.text,
                textAlignment: text.textAlignment,
                lineBreakMode: text.lineBreakMode,
                lineSpacing: text.lineSpacing
            )
            layout.wrappedValue.textLayout.setTextContainer(textContainer)
            layout.wrappedValue.textLayout.fitToSize(text.bounds.size)
        }
    }
}
