//
//  NamedTextureAtlasPacker.swift
//  AdaEngine
//

import Foundation
import Math

public enum NamedTextureAtlasPackingError: LocalizedError, Sendable {
    case emptyAtlas
    case duplicateKey(String)
    case invalidSetting(name: String, value: Int)
    case unsupportedImageFormat(key: String, format: Image.Format)
    case imageTooLarge(key: String, size: SizeInt, maximum: SizeInt)
    case atlasTooLarge(size: SizeInt, maximum: SizeInt)

    public var errorDescription: String? {
        switch self {
        case .emptyAtlas:
            return "A texture atlas must contain at least one image."
        case let .duplicateKey(key):
            return "Texture atlas contains the duplicate key '\(key)'."
        case let .invalidSetting(name, value):
            return "Texture atlas setting '\(name)' has invalid value \(value)."
        case let .unsupportedImageFormat(key, format):
            return "Texture atlas image '\(key)' uses unsupported pixel format \(format); RGBA8 is required."
        case let .imageTooLarge(key, size, maximum):
            return "Texture atlas image '\(key)' (\(size.width)x\(size.height)) exceeds the maximum atlas size \(maximum.width)x\(maximum.height)."
        case let .atlasTooLarge(size, maximum):
            return "Packed texture atlas size \(size.width)x\(size.height) exceeds the maximum \(maximum.width)x\(maximum.height)."
        }
    }
}

struct NamedTextureAtlasPackingResult: Sendable {
    let image: Image
    let entriesByKey: [String: AtlasRegion]
}

enum NamedTextureAtlasPacker {
    struct Input: Sendable {
        let key: String
        let image: Image
    }

    private struct Placement {
        let key: String
        let image: Image
        let cellWidth: Int
        let cellHeight: Int
        var x: Int = 0
        var y: Int = 0
    }

    static func pack(
        _ inputs: [Input],
        descriptor: NamedTextureAtlas.Descriptor
    ) throws -> NamedTextureAtlasPackingResult {
        try validate(inputs, descriptor: descriptor)
        var placements = try makePlacements(inputs, descriptor: descriptor)
        let atlasSize = try arrange(&placements, descriptor: descriptor)

        var atlasData = Data(count: atlasSize.width * atlasSize.height * 4)
        var entries: [String: AtlasRegion] = [:]

        for placement in placements {
            copy(placement, extrude: descriptor.extrude, atlasWidth: atlasSize.width, atlasData: &atlasData)

            let contentX = placement.x + descriptor.extrude
            let contentY = placement.y + descriptor.extrude
            entries[placement.key] = AtlasRegion(
                key: placement.key,
                atlasOrigin: PointInt(x: placement.x, y: placement.y),
                atlasSize: SizeInt(width: placement.cellWidth, height: placement.cellHeight),
                uvMin: Vector2(Float(contentX) / Float(atlasSize.width), Float(contentY) / Float(atlasSize.height)),
                uvMax: Vector2(
                    Float(contentX + placement.image.width) / Float(atlasSize.width),
                    Float(contentY + placement.image.height) / Float(atlasSize.height)
                ),
                originalSize: SizeInt(width: placement.image.width, height: placement.image.height),
                contentOriginInAtlas: PointInt(x: contentX, y: contentY)
            )
        }

        return NamedTextureAtlasPackingResult(
            image: Image(width: atlasSize.width, height: atlasSize.height, data: atlasData, format: .rgba8),
            entriesByKey: entries
        )
    }

    private static func validate(
        _ inputs: [Input],
        descriptor: NamedTextureAtlas.Descriptor
    ) throws {
        guard !inputs.isEmpty else {
            throw NamedTextureAtlasPackingError.emptyAtlas
        }
        try validateNonnegative(descriptor.margin, name: "margin")
        try validateNonnegative(descriptor.padding, name: "padding")
        try validateNonnegative(descriptor.extrude, name: "extrude")

        if let maximum = descriptor.maxSize, maximum.width <= 0 || maximum.height <= 0 {
            throw NamedTextureAtlasPackingError.invalidSetting(
                name: "maxSize",
                value: min(maximum.width, maximum.height)
            )
        }
    }

    private static func makePlacements(
        _ inputs: [Input],
        descriptor: NamedTextureAtlas.Descriptor
    ) throws -> [Placement] {
        var keys = Set<String>()
        var placements = try inputs.map { input in
            guard keys.insert(input.key).inserted else {
                throw NamedTextureAtlasPackingError.duplicateKey(input.key)
            }
            guard input.image.format == .rgba8 else {
                throw NamedTextureAtlasPackingError.unsupportedImageFormat(key: input.key, format: input.image.format)
            }

            return Placement(
                key: input.key,
                image: input.image,
                cellWidth: input.image.width + descriptor.extrude * 2,
                cellHeight: input.image.height + descriptor.extrude * 2
            )
        }

        placements.sort {
            if $0.cellHeight != $1.cellHeight {
                return $0.cellHeight > $1.cellHeight
            }
            if $0.cellWidth != $1.cellWidth {
                return $0.cellWidth > $1.cellWidth
            }
            return $0.key < $1.key
        }
        return placements
    }

    private static func arrange(
        _ placements: inout [Placement],
        descriptor: NamedTextureAtlas.Descriptor
    ) throws -> SizeInt {
        let shelfWidth = descriptor.maxSize?.width ?? 4_096
        var cursorX = descriptor.margin
        var cursorY = descriptor.margin
        var rowHeight = 0
        var atlasWidth = descriptor.margin * 2
        var atlasHeight = descriptor.margin * 2

        for index in placements.indices {
            let placement = placements[index]
            try validate(placement, maximum: descriptor.maxSize, margin: descriptor.margin)

            if cursorX > descriptor.margin,
                cursorX + placement.cellWidth + descriptor.margin > shelfWidth {
                cursorY += rowHeight + descriptor.padding
                cursorX = descriptor.margin
                rowHeight = 0
            }

            placements[index].x = cursorX
            placements[index].y = cursorY
            cursorX += placement.cellWidth + descriptor.padding
            rowHeight = max(rowHeight, placement.cellHeight)
            atlasWidth = max(atlasWidth, placements[index].x + placement.cellWidth + descriptor.margin)
            atlasHeight = max(atlasHeight, placements[index].y + placement.cellHeight + descriptor.margin)
        }

        if descriptor.powerOfTwo {
            atlasWidth = nextPowerOfTwo(atlasWidth)
            atlasHeight = nextPowerOfTwo(atlasHeight)
        }

        let atlasSize = SizeInt(width: atlasWidth, height: atlasHeight)
        if let maximum = descriptor.maxSize, atlasWidth > maximum.width || atlasHeight > maximum.height {
            throw NamedTextureAtlasPackingError.atlasTooLarge(size: atlasSize, maximum: maximum)
        }
        return atlasSize
    }

    private static func validate(_ placement: Placement, maximum: SizeInt?, margin: Int) throws {
        guard
            let maximum,
            placement.cellWidth + margin * 2 > maximum.width
                || placement.cellHeight + margin * 2 > maximum.height
        else {
            return
        }
        throw NamedTextureAtlasPackingError.imageTooLarge(
            key: placement.key,
            size: SizeInt(width: placement.image.width, height: placement.image.height),
            maximum: maximum
        )
    }

    private static func validateNonnegative(_ value: Int, name: String) throws {
        guard value >= 0 else {
            throw NamedTextureAtlasPackingError.invalidSetting(name: name, value: value)
        }
    }

    private static func nextPowerOfTwo(_ value: Int) -> Int {
        var result = 1
        while result < max(1, value) {
            result *= 2
        }
        return result
    }

    private static func copy(
        _ placement: Placement,
        extrude: Int,
        atlasWidth: Int,
        atlasData: inout Data
    ) {
        for cellY in 0..<placement.cellHeight {
            let sourceY = min(max(cellY - extrude, 0), placement.image.height - 1)
            for cellX in 0..<placement.cellWidth {
                let sourceX = min(max(cellX - extrude, 0), placement.image.width - 1)
                let sourceOffset = (sourceY * placement.image.width + sourceX) * 4
                let destinationOffset = ((placement.y + cellY) * atlasWidth + placement.x + cellX) * 4
                atlasData[destinationOffset..<destinationOffset + 4] = placement.image.data[sourceOffset..<sourceOffset + 4]
            }
        }
    }
}
