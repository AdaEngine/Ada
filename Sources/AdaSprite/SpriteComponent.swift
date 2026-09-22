//
//  Sprite.swift
//  AdaEngine
//
//  Created by v.prusakov on 5/8/22.
//

import AdaAssets
import AdaECS
import AdaRender
import AdaUtils
import Math

/// Contains information about sprite, like texture and tint coloring.
@Component(
    required: [Visibility.self, BoundingComponent.self]
)
public struct Sprite: Codable {
    /// The texture of the sprite.
    public var texture: AssetHandle<Texture2D>?
    /// The tint color of the sprite.
    public var tintColor: Color
    /// Whether to flip the sprite horizontally.
    public var flipX: Bool = false
    /// Whether to flip the sprite vertically.
    public var flipY: Bool = false
    /// The custom size of the sprite.
    public var size: Size?

    /// Create a new sprite component for specific texture and tintColor.
    /// - Parameter texture: Asset that contains texture.
    /// - Parameter tintColor: Color for tinting the texture. By default is white and don't tint a texture.
    /// - Parameter flipX: Flip texture horizontally
    /// - Parameter flipY: Flip texture vertically.
    /// - Parameter size: The custom size of the sprite.
    @AdaScriptInit
    public init(
        texture: AssetHandle<Texture2D>? = nil,
        tintColor: Color = .white,
        flipX: Bool = false,
        flipY: Bool = false,
        size: Size? = nil
    ) {
        self.texture = texture
        self.tintColor = tintColor
        self.flipX = flipX
        self.flipY = flipY
        self.size = size
    }

    /// Create a new sprite component for specific texture and tintColor.
    /// - Parameter texture: Texture for rendering.
    /// - Parameter tintColor: Color for tinting the texture. By default is white and don't tint a texture.
    /// - Parameter flipX: Flip texture horizontally
    /// - Parameter flipY: Flip texture vertically.
    /// - Parameter size: The custom size of the sprite.
    public init(
        texture: Texture2D,
        tintColor: Color = .white,
        flipX: Bool = false,
        flipY: Bool = false,
        size: Size? = nil
    ) {
        self.texture = AssetHandle(texture)
        self.tintColor = tintColor
        self.flipX = flipX
        self.flipY = flipY
        self.size = size
    }
}
