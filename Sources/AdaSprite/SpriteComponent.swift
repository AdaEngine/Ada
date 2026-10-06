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

    /// Point on the sprite fixed to the entity's origin. Positive Y points up.
    public var anchor: SpriteAnchor = .center
    /// How the texture fills the sprite size.
    public var imageMode: SpriteImageMode = .stretch

    /// Create a new sprite component for specific texture and tintColor.
    /// - Parameter texture: Asset that contains texture.
    /// - Parameter tintColor: Color for tinting the texture. By default is white and don't tint a texture.
    /// - Parameter flipX: Flip texture horizontally
    /// - Parameter flipY: Flip texture vertically.
    /// - Parameter size: The custom size of the sprite.
    /// - Parameter anchor: The normalized point fixed to the entity origin.
    /// - Parameter imageMode: How the texture fills the custom size.
    @AdaScriptInit
    public init(
        texture: AssetHandle<Texture2D>? = nil,
        tintColor: Color = .white,
        flipX: Bool = false,
        flipY: Bool = false,
        size: Size? = nil,
        anchor: SpriteAnchor = .center,
        imageMode: SpriteImageMode = .stretch
    ) {
        self.texture = texture
        self.tintColor = tintColor
        self.flipX = flipX
        self.flipY = flipY
        self.size = size
        self.anchor = anchor
        self.imageMode = imageMode
    }

    /// Create a new sprite component for specific texture and tintColor.
    /// - Parameter texture: Texture for rendering.
    /// - Parameter tintColor: Color for tinting the texture. By default is white and don't tint a texture.
    /// - Parameter flipX: Flip texture horizontally
    /// - Parameter flipY: Flip texture vertically.
    /// - Parameter size: The custom size of the sprite.
    /// - Parameter anchor: The normalized point fixed to the entity origin.
    /// - Parameter imageMode: How the texture fills the custom size.
    public init(
        texture: Texture2D,
        tintColor: Color = .white,
        flipX: Bool = false,
        flipY: Bool = false,
        size: Size? = nil,
        anchor: SpriteAnchor = .center,
        imageMode: SpriteImageMode = .stretch
    ) {
        self.texture = AssetHandle(texture)
        self.tintColor = tintColor
        self.flipX = flipX
        self.flipY = flipY
        self.size = size
        self.anchor = anchor
        self.imageMode = imageMode
    }

    private enum CodingKeys: String, CodingKey {
        case texture, tintColor, flipX, flipY, size, anchor, imageMode
    }

    /// Legacy scenes without layout fields keep their original centered, stretched appearance.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.texture = try container.decodeIfPresent(AssetHandle<Texture2D>.self, forKey: .texture)
        self.tintColor = try container.decode(Color.self, forKey: .tintColor)
        self.flipX = try container.decodeIfPresent(Bool.self, forKey: .flipX) ?? false
        self.flipY = try container.decodeIfPresent(Bool.self, forKey: .flipY) ?? false
        self.size = try container.decodeIfPresent(Size.self, forKey: .size)
        self.anchor = try container.decodeIfPresent(SpriteAnchor.self, forKey: .anchor) ?? .center
        self.imageMode = try container.decodeIfPresent(SpriteImageMode.self, forKey: .imageMode) ?? .stretch
    }
}
