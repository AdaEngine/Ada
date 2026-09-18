//
//  TileMap.swift
//  AdaEngine
//
//  Created by v.prusakov on 5/4/24.
//

import AdaAssets
@_spi(Runtime) import AdaUtils
import Math
import OrderedCollections

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
        self.tileSet = fileContent.tileSet

        for layer in fileContent.layers {
            let newLayer = self.createLayer()
            newLayer.name = layer.name

            for tile in layer.tiles {
                newLayer.setCell(
                    at: tile.position,
                    sourceId: tile.sourceId,
                    atlasCoordinates: tile.atlasPosition
                )
            }
        }
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

        let content = FileContent(layers: layers, tileSet: self.tileSet)
        try encoder.encode(content)
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

        let layers: [Layer]
        let tileSet: TileSet
    }
}
