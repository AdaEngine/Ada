//
//  BorderModifier.swift
//  AdaEngine
//
//  Created by Vladislav Prusakov on 29.07.2024.
//

import AdaUtils
import Math

extension View {
    public func border(_ color: Color, lineWidth: Float = 1) -> some View {
        modifier(_BorderModifier(color: color, lineWidth: lineWidth))
    }
}

struct _BorderModifier: ViewModifier {
    let color: Color
    let lineWidth: Float

    func body(content: Content) -> some View {
        content.overlay {
            Canvas { context, size in
                context.drawLine(start: Vector2(0, 0), end: Vector2(size.width, 0), lineWidth: lineWidth, color: color)
                context.drawLine(start: Vector2(0, 0), end: Vector2(0, -size.height), lineWidth: lineWidth, color: color)
                context.drawLine(start: Vector2(size.width, 0), end: Vector2(size.width, -size.height), lineWidth: lineWidth, color: color)
                context.drawLine(start: Vector2(0, -size.height), end: Vector2(size.width, -size.height), lineWidth: lineWidth, color: color)
            }
        }
    }
}
