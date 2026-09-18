//
//  NamedTextureAtlasDescriptor.swift
//  AdaEngine
//

import Foundation
import Math

extension NamedTextureAtlas {
    /// A source image included in a named texture atlas.
    ///
    /// In an `.atlas` file a source can be written as a path string or as an object with
    /// an explicit key:
    ///
    /// ```yaml
    /// images:
    ///   - images/player.png
    ///   - path: images/enemy.png
    ///     key: enemyIdle
    /// ```
    public struct Source: Codable, Equatable, Sendable {
        public var path: String
        public var key: String?

        public init(path: String, key: String? = nil) {
            self.path = path
            self.key = key
        }

        public init(from decoder: any Decoder) throws {
            if let container = try? decoder.singleValueContainer(), let path = try? container.decode(String.self) {
                self.init(path: path)
                return
            }

            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.init(
                path: try container.decode(String.self, forKey: .path),
                key: try container.decodeIfPresent(String.self, forKey: .key)
            )
        }

        public func encode(to encoder: any Encoder) throws {
            if key == nil {
                var container = encoder.singleValueContainer()
                try container.encode(path)
                return
            }

            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(path, forKey: .path)
            try container.encodeIfPresent(key, forKey: .key)
        }

        private enum CodingKeys: CodingKey {
            case path
            case key
        }
    }

    /// Texture filtering used by the generated atlas texture.
    public enum Filter: String, Codable, Sendable {
        case linear
        case nearest

        var samplerDescriptor: SamplerDescriptor {
            let filter: SamplerMinMagFilter = self == .nearest ? .nearest : .linear
            return SamplerDescriptor(
                minFilter: filter,
                magFilter: filter,
                mipFilter: .notMipmapped
            )
        }
    }

    /// Declarative contents and packing settings stored in an `.atlas` resource.
    public struct Descriptor: Codable, Equatable, Sendable {
        public var images: [Source]
        public var margin: Int
        public var padding: Int
        public var extrude: Int
        public var maxSize: SizeInt?
        public var powerOfTwo: Bool
        public var filter: Filter

        public init(
            images: [Source],
            margin: Int = 0,
            padding: Int = 2,
            extrude: Int = 1,
            maxSize: SizeInt? = nil,
            powerOfTwo: Bool = false,
            filter: Filter = .linear
        ) {
            self.images = images
            self.margin = margin
            self.padding = padding
            self.extrude = extrude
            self.maxSize = maxSize
            self.powerOfTwo = powerOfTwo
            self.filter = filter
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.init(
                images: try container.decode([Source].self, forKey: .images),
                margin: try container.decodeIfPresent(Int.self, forKey: .margin) ?? 0,
                padding: try container.decodeIfPresent(Int.self, forKey: .padding) ?? 2,
                extrude: try container.decodeIfPresent(Int.self, forKey: .extrude) ?? 1,
                maxSize: try container.decodeIfPresent(SizeInt.self, forKey: .maxSize),
                powerOfTwo: try container.decodeIfPresent(Bool.self, forKey: .powerOfTwo) ?? false,
                filter: try container.decodeIfPresent(Filter.self, forKey: .sampler) ?? .linear
            )
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(images, forKey: .images)
            try container.encode(margin, forKey: .margin)
            try container.encode(padding, forKey: .padding)
            try container.encode(extrude, forKey: .extrude)
            try container.encodeIfPresent(maxSize, forKey: .maxSize)
            try container.encode(powerOfTwo, forKey: .powerOfTwo)
            try container.encode(filter, forKey: .sampler)
        }

        private enum CodingKeys: CodingKey {
            case images
            case margin
            case padding
            case extrude
            case maxSize
            case powerOfTwo
            case sampler
        }
    }
}
