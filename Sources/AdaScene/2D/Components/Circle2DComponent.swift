//
//  Circle2DComponent.swift
//  AdaEngine
//
//  Created by v.prusakov on 5/10/22.
//

import AdaECS
import AdaUtils

/// Create a new 2D circle on scene.
@Component
public struct Circle2DComponent: Codable {
    public var color: Color

    @InRange public var thickness: Float

    @InRange public var fade: Float

    public init(color: Color, thickness: Float = 1, fade: Float = 0.005) {
        self.color = color
        self._thickness = InRange(wrappedValue: thickness, 0...1)
        self._fade = InRange(wrappedValue: fade, 0...1)
    }
}
