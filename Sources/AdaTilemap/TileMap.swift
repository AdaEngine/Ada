//
//  TileMap.swift
//  AdaEngine
//
//  Created by v.prusakov on 5/4/24.
//

import AdaAssets
import AdaRender
@_spi(Runtime) import AdaUtils
import Foundation
import Math
import OrderedCollections

/// One palette slot linked to a tile authored in a `.tileset` asset.
public struct TileMapSourceTile: Codable, Equatable, Hashable, Sendable {
    public var sourceID: Int
    public var atlasCoordinates: [Int]

    public init(sourceID: Int, atlasCoordinates: [Int]) {
        self.sourceID = sourceID
        self.atlasCoordinates = atlasCoordinates
    }
}

/// A tile map.
public class TileMap: @unsafe Asset, @unchecked Sendable {
    /// The tile set of the tile map.
    public var tileSet: TileSet = TileSet() {
        didSet {
            self.tileSetDidChange()
        }
    }

    /// The layers of the tile map.
    public internal(set) var layers: [TileMapLayer] = [TileMapLayer()]

    /// The asset meta info of the tile map.
    nonisolated(unsafe) public var assetMetaInfo: AssetMetaInfo?

    /// A Boolean value indicating whether the tile map needs to be updated.
    internal private(set) var needsUpdate: Bool = false

    /// The revision of the tile map's renderable state.
    internal private(set) var updateRevision: UInt64 = 0

    /// Initialize a new tile map.
    public init() {
        self.tileSetDidChange()
    }

    /// Initialize a new tile map from a decoder.
    ///
    /// - Parameter decoder: The decoder to initialize the tile map from.
    /// - Throws: An error if the tile map cannot be initialized from the decoder.
    public required init(from decoder: AssetDecoder) async throws {
        let fileContent = try decoder.decode(FileContent.self)
        self.tileSet = fileContent.tileSet ?? TileSet()

        if fileContent.atlasTextures?.isEmpty != false, let colors = fileContent.atlasColors, !colors.isEmpty {
            var atlas = Image(width: colors.count, height: 1, color: .white)
            for (index, color) in colors.enumerated() {
                atlas.setPixel(in: [Float(index), 0], color: color)
            }
            let source = TextureAtlasTileSource(from: atlas, size: [1, 1])
            source.name = "Map palette"
            for index in colors.indices {
                source.createTile(for: [index, 0])
            }
            let sourceID = tileSet.addTileSource(source)
            if let cells = fileContent.cells {
                for cell in cells where cell.count >= 3 && colors.indices.contains(cell[2]) {
                    layers[0].setCell(at: [cell[0], cell[1]], sourceId: sourceID, atlasCoordinates: [cell[2], 0])
                }
            }
        }

        if let paths = fileContent.atlasTextures, !paths.isEmpty {
            var images: [Image] = []
            for path in paths {
                let resolvedPath = path.hasPrefix("@res://") || path.hasPrefix("/")
                    ? path
                    : URL(fileURLWithPath: path, relativeTo: decoder.assetMeta.filePath.deletingLastPathComponent()).standardizedFileURL.path
                let handle = try await AssetsManager.load(Image.self, at: resolvedPath)
                guard let image = handle.asset else {
                    throw AssetDecodingError.decodingProblem("Unable to load tile texture: \(path)")
                }
                images.append(image)
            }
            if let first = images.first {
                for color in (fileContent.atlasColors ?? []).dropFirst(images.count) {
                    images.append(Image(width: first.width, height: first.height, color: color))
                }
            }
            try setImagePalette(images, cells: fileContent.cells ?? [])
        }

        if let reference = fileContent.tileSetReference, !reference.isEmpty {
            let path = reference.hasPrefix("@res://") || reference.hasPrefix("/")
                ? reference
                : URL(fileURLWithPath: reference, relativeTo: decoder.assetMeta.filePath.deletingLastPathComponent()).standardizedFileURL.path
            let handle = try await AssetsManager.load(TileSet.self, at: path)
            guard let linkedSet = handle.asset else {
                throw AssetDecodingError.decodingProblem("Unable to load linked tile set: \(reference)")
            }
            try installTileSetPalette(
                linkedSet,
                palette: fileContent.tileSetTiles ?? [],
                cells: fileContent.cells ?? [],
                firstPaletteIndex: max(fileContent.atlasColors?.count ?? 0, fileContent.atlasTextures?.count ?? 0)
            )
        }

        for (index, layer) in (fileContent.layers ?? []).enumerated() {
            let newLayer = index == 0 ? layers[0] : self.createLayer()
            newLayer.name = layer.name

            for tile in layer.tiles {
                newLayer.setCell(
                    at: tile.position,
                    sourceId: tile.sourceId,
                    atlasCoordinates: tile.atlasPosition
                )
            }
        }
        tileSetDidChange()
    }

    /// Encode the tile map to an encoder.
    ///
    /// - Parameter encoder: The encoder to encode the tile map to.
    /// - Throws: An error if the tile map cannot be encoded to the encoder.
    public func encodeContents(with encoder: AssetEncoder) async throws {
        var layers = [FileContent.Layer]()

        for layer in self.layers {
            let tiles = layer.tileCells.elements.map { position, data in
                FileContent.Tile(
                    position: position,
                    atlasPosition: data.atlasCoordinates,
                    sourceId: data.sourceId
                )
            }

            layers.append(
                FileContent.Layer(name: layer.name, id: layer.id, tiles: tiles)
            )
        }

        let content = FileContent(
            layers: layers, tileSet: self.tileSet, atlasColors: nil, atlasTextures: nil,
            tileSetReference: nil, tileSetTiles: nil, cells: nil
        )
        try encoder.encode(content)
    }

    /// Install equal-sized tile images as one atlas, with cell indices matching image order.
    public func setImagePalette(_ images: [Image], cells: [[Int]]) throws {
        guard let first = images.first, first.width > 0, first.height > 0,
            images.allSatisfy({ $0.width == first.width && $0.height == first.height }) else {
            throw AssetDecodingError.decodingProblem("Tile palette images must have equal, nonzero dimensions.")
        }
        var atlas = Image(width: first.width * images.count, height: first.height)
        for (index, image) in images.enumerated() {
            for y in 0..<image.height {
                for x in 0..<image.width {
                    atlas.setPixel(in: [Float(index * image.width + x), Float(y)], color: image.getPixel(x: x, y: y))
                }
            }
        }
        let source = TextureAtlasTileSource(from: atlas, size: [first.width, first.height])
        source.name = "Image palette"
        for index in images.indices {
            source.createTile(for: [index, 0])
        }
        let sourceID = tileSet.addTileSource(source)
        for cell in cells where cell.count >= 3 && images.indices.contains(cell[2]) {
            layers[0].setCell(at: [cell[0], cell[1]], sourceId: sourceID, atlasCoordinates: [cell[2], 0])
        }
    }

    /// Append palette tiles from an authored tile set while preserving the tile set asset itself.
    public func installTileSetPalette(
        _ linkedSet: TileSet,
        palette: [TileMapSourceTile],
        cells: [[Int]],
        firstPaletteIndex: Int
    ) throws {
        var copiedSources: [Int: Int] = [:]
        for tile in palette {
            guard tile.atlasCoordinates.count == 2,
                let source = linkedSet.sources[tile.sourceID] as? TextureAtlasTileSource,
                source.containsTile(at: PointInt(tile.atlasCoordinates)) else {
                throw AssetDecodingError.decodingProblem("Linked tile set contains an invalid palette tile.")
            }
            if copiedSources[tile.sourceID] == nil {
                copiedSources[tile.sourceID] = tileSet.addTileSource(try source.copyForTileMap())
            }
        }
        for cell in cells where cell.count >= 3 {
            let index = cell[2] - firstPaletteIndex
            guard palette.indices.contains(index), let sourceID = copiedSources[palette[index].sourceID] else { continue }
            layers[0].setCell(
                at: [cell[0], cell[1]], sourceId: sourceID,
                atlasCoordinates: PointInt(palette[index].atlasCoordinates)
            )
        }
    }

    /// Append individual images for a portable player that has no synchronous tile set asset loader.
    public func installLinkedImagePalette(_ images: [Image], cells: [[Int]], firstPaletteIndex: Int) throws {
        var sourceIDs: [Int] = []
        for image in images {
            guard image.width > 0, image.height > 0 else {
                throw AssetDecodingError.decodingProblem("Linked tile image has invalid dimensions.")
            }
            let source = TextureAtlasTileSource(from: image, size: [image.width, image.height])
            source.createTile(for: [0, 0])
            sourceIDs.append(tileSet.addTileSource(source))
        }
        for cell in cells where cell.count >= 3 {
            let index = cell[2] - firstPaletteIndex
            guard sourceIDs.indices.contains(index) else { continue }
            layers[0].setCell(at: [cell[0], cell[1]], sourceId: sourceIDs[index], atlasCoordinates: [0, 0])
        }
    }

    /// The extensions of the tile map.
    public static func extensions() -> [String] {
        ["tilemap"]
    }

    /// Create a new layer for the tile map.
    ///
    /// - Returns: The new layer.
    public func createLayer() -> TileMapLayer {
        let layer = TileMapLayer()
        layer.name = "Layer \(self.layers.count)"
        layer.tileSet = self.tileSet
        layer.tileMap = self
        self.layers.append(layer)

        return layer
    }

    /// Remove a layer from the tile map.
    ///
    /// - Parameter layer: The layer to remove.
    public func removeLayer(_ layer: TileMapLayer) {
        guard let index = self.layers.firstIndex(where: { $0 === layer }) else {
            return
        }

        self.layers.remove(at: index)
        self.setNeedsUpdate()
    }

    /// Set a cell for a layer.
    ///
    /// - Parameters:
    ///   - layerIndex: The index of the layer.
    ///   - coordinates: The coordinates of the cell.
    ///   - sourceId: The source id of the cell.
    ///   - atlasCoordinates: The atlas coordinates of the cell.
    public func setCell(for layerIndex: Int, coordinates: PointInt, sourceId: TileSource.ID, atlasCoordinates: PointInt) {
        if !layers.indices.contains(layerIndex) {
            return
        }

        let layer = self.layers[layerIndex]
        layer.setCell(at: coordinates, sourceId: sourceId, atlasCoordinates: atlasCoordinates)
    }

    /// Remove a cell from a layer.
    ///
    /// - Parameters:
    ///   - layerIndex: The index of the layer.
    ///   - coordinates: The coordinates of the cell.
    public func removeCell(for layerIndex: Int, coordinates: PointInt) {
        if !layers.indices.contains(layerIndex) {
            return
        }

        let layer = self.layers[layerIndex]
        layer.removeCell(at: coordinates)
    }

    // MARK: - Internals

    /// Set the tile map needs update.
    ///
    /// - Parameter updateLayers: A Boolean value indicating whether the layers need to be updated.
    func setNeedsUpdate(updateLayers: Bool = false, advanceRevision: Bool = true) {
        self.needsUpdate = true
        if advanceRevision {
            self.updateRevision &+= 1
        }

        if updateLayers {
            self.layers.forEach { $0.setNeedsUpdate() }
        }
    }

    /// Update the tile map did finish.
    func updateDidFinish() {
        self.needsUpdate = false
    }

    // MARK: - Private

    /// The tile set did change.
    private func tileSetDidChange() {
        self.setNeedsUpdate(updateLayers: true)

        self.tileSet.tileMap = self

        for layer in layers {
            layer.tileSet = self.tileSet
            layer.tileMap = self
        }
    }
}

// MARK: - Codable

extension TileMap {
    struct FileContent: Codable {
        struct Layer: Codable {
            let name: String
            let id: Int
            let tiles: [Tile]
        }

        struct Tile: Codable {
            enum CodingKeys: String, CodingKey {
                case position = "p"
                case atlasPosition = "ap"
                case sourceId = "sid"
            }

            let position: PointInt
            let atlasPosition: PointInt
            let sourceId: TileSource.ID

            init(position: PointInt, atlasPosition: PointInt, sourceId: TileSource.ID) {
                self.position = position
                self.atlasPosition = atlasPosition
                self.sourceId = sourceId
            }

            init(from decoder: any Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                self.position = try PointInt(container.decode([Int].self, forKey: Self.CodingKeys.position))
                self.atlasPosition = try PointInt(container.decode([Int].self, forKey: Self.CodingKeys.atlasPosition))
                self.sourceId = try container.decode(TileSource.ID.self, forKey: Self.CodingKeys.sourceId)
            }

            func encode(to encoder: any Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode(self.sourceId, forKey: .sourceId)
                try container.encode([position.x, position.y], forKey: .position)
                try container.encode([atlasPosition.x, atlasPosition.y], forKey: .atlasPosition)
            }
        }

        let layers: [Layer]?
        let tileSet: TileSet?
        let atlasColors: [Color]?
        let atlasTextures: [String]?
        let tileSetReference: String?
        let tileSetTiles: [TileMapSourceTile]?
        let cells: [[Int]]?
    }
}
