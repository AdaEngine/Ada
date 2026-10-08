//
//  LDtkTileMap.swift
//  AdaEngine
//
//  Created by v.prusakov on 5/11/24.
//

import AdaAssets
import AdaECS
import AdaRender
import AdaSprite
import AdaUtils
import Foundation
import Logging
import Math
import OrderedCollections

/// Namespace for LDtk
public enum LDtk {}

extension LDtk {
    /// Tile map that supports LDtk file formats (`ldtk` or `json`).
    /// - Note: We only support tilesets, layers and levels.
    ///
    /// You can load LDtk tile map using ``AssetsManager`` object.
    /// ```swift
    /// let tileMap = try await AssetsManager.load("@res://Assets/TileMap.ldtk") as LDtkTileMap
    /// ```
    public final class TileMap: AdaTilemap.TileMap, @unchecked Sendable {
        public weak var delegate: TileMapDelegate? {
            didSet {
                tileSet.sources.forEach { _, value in
                    (value as? LDtk.EntityTileSource)?.delegate = self.delegate
                }
            }
        }

        public private(set) var currentLevelIndex: Int = 0
        public private(set) var levelsCount: Int = 0
        private var project: Project?
        private let filePath: URL
        private let logger = Logger(label: "org.adaengine.tilemap.LDtk")

        private var fileWatcher: FileWatcher!
        private var fileWatcherObserver: Cancellable?

        /// When is hot reloading enabled, TileMap will automatically update tiles when LDtk project changed.
        ///
        /// - Note: Use ``TileMap/resourcePath`` field to get runtime path to your LDtk file.
        public private(set) var isHotReloadingEnabled: Bool = false

        public required init(from decoder: AssetDecoder) async throws {
            let pathExt = decoder.assetMeta.filePath.pathExtension

            guard pathExt == "ldtk" || pathExt == "json" else {
                throw AssetDecodingError.invalidAssetExtension("Invalid extension for Ldtk project: \(pathExt)")
            }

            self.filePath = decoder.assetMeta.filePath

            super.init()

            let assetPath = try AbsolutePath(validating: decoder.assetMeta.filePath.path)

            self.fileWatcher = FileWatcher(paths: [assetPath]) { [weak self] paths in
                self?.onLDtkFileMapChanged(paths: paths.map(\.pathString))
            }

            try await self.loadLdtkProject(from: decoder.assetData)
        }

        /// Load level from LDtk project at index.
        /// You can get information about levels count using ``levelsCount`` property.
        /// - Note: Each time when you call ``loadLevel(at:)`` method, then previous tiles will deleted.
        public func loadLevel(at index: Int) {
            guard let project else {
                logger.critical("LDtk Project is empty at path \(filePath)")
                return
            }

            let level = project.levels[index]
            self.currentLevelIndex = index

            for layer in self.layers {
                layer.removeAllCells()
            }

            for layerInstance in level.layerInstances where layerInstance.visible {
                guard let layer = self.layers.first(where: { $0.id == layerInstance.layerDefUid }) else {
                    logger.critical("Could not find a layer for id \(layerInstance.layerDefUid)")
                    return
                }

                guard let projectLayer = project.defs.layers.first(where: { $0.uid == layerInstance.layerDefUid }) else {
                    logger.critical("Could not find a layer in project for id: \(layerInstance.layerDefUid)")
                    return
                }

                switch layerInstance.__type {
                case .autoLayer,
                    .intGrid:
                    guard
                        let tileSetID = projectLayer.tilesetDefUid,
                        let source = tileSet.sources[tileSetID] as? TextureAtlasTileSource
                    else {
                        logger.error("Could not resolve a texture-atlas tile source for layer \(projectLayer.uid).")
                        return
                    }

                    for tile in layerInstance.autoLayerTiles {
                        let atlasCoordinates = Utils.gridCoordinates(from: tile.source, gridSize: layerInstance.__gridSize)
                        if !source.hasTile(at: atlasCoordinates) {
                            source.createTile(for: atlasCoordinates)
                        }

                        layer.setCell(
                            at: Utils.pixelCoordsToGridCoords(from: tile.position, gridSize: layerInstance.__gridSize, gridHeight: layerInstance.__cHei),
                            sourceId: tileSetID,
                            atlasCoordinates: atlasCoordinates
                        )
                    }
                case .entities:
                    let entityInstances = layerInstance.entityInstances ?? []
                    for entity in entityInstances {
                        let atlasCoordinates = Utils.gridCoordinates(from: entity.px, gridSize: layerInstance.__gridSize)

                        let source = tileSet.sources[entity.defUid] as! LDtk.EntityTileSource

                        source.createTile(at: atlasCoordinates, entityInstance: entity)

                        if !source.hasTile(at: atlasCoordinates) {
                            source.createTile(at: atlasCoordinates, entityInstance: entity)
                        }

                        layer.setCell(
                            at: Utils.pixelCoordsToGridCoords(from: entity.px, gridSize: layerInstance.__gridSize, gridHeight: layerInstance.__cHei),
                            sourceId: entity.defUid,
                            atlasCoordinates: atlasCoordinates
                        )
                    }
                case .tiles:
                    guard
                        let tileSetID = projectLayer.tilesetDefUid,
                        let source = tileSet.sources[tileSetID] as? TextureAtlasTileSource
                    else {
                        logger.error("Could not resolve a texture-atlas tile source for layer \(projectLayer.uid).")
                        return
                    }

                    for tile in layerInstance.gridTiles {
                        let atlasCoordinates = Utils.gridCoordinates(from: tile.source, gridSize: layerInstance.__gridSize)

                        if !source.hasTile(at: atlasCoordinates) {
                            source.createTile(for: atlasCoordinates)
                        }

                        layer.setCell(
                            at: Utils.pixelCoordsToGridCoords(from: tile.position, gridSize: layerInstance.__gridSize, gridHeight: layerInstance.__cHei),
                            sourceId: tileSetID,
                            atlasCoordinates: atlasCoordinates
                        )
                    }
                }
            }
        }

        /// Enable or disable hot reloading.
        ///
        /// - Note: Use ``TileMap/resourcePath`` field to get runtime path to your LDtk file.
        public func setHotReloading(enabled: Bool) throws {
            if enabled {
                try fileWatcher.start()
            } else {
                fileWatcher.stop()
            }

            self.isHotReloadingEnabled = enabled
        }

        // MARK: - Private

        private func onLDtkFileMapChanged(paths: [String]) {
            Task {
                do {
                    guard let data = FileManager.default.contents(atPath: paths[0]) else {
                        return
                    }

                    try await loadLdtkProject(from: data)
                } catch {
                    logger.critical("Failed to update ldtk file \(error)")
                }
            }
        }

        private func loadLdtkProject(from data: Data) async throws {
            let currentProject = self.project

            let jsonDecoder = JSONDecoder()
            let project = try jsonDecoder.decode(Project.self, from: data)

            if currentProject?.defs.tilesets != project.defs.tilesets || currentProject?.defs.entities != project.defs.entities {
                let tileSet = AdaTilemap.TileSet()

                for entitySource in project.defs.entities {
                    let source = LDtk.EntityTileSource()

                    source.name = entitySource.identifier
                    source.id = entitySource.uid

                    tileSet.addTileSource(source)
                }

                for tileSource in project.defs.tilesets {
                    let atlasPath =
                        filePath
                        .deletingLastPathComponent()
                        .appending(path: tileSource.relPath ?? "")

                    let image = try await AssetsManager.load(
                        Image.self,
                        at: atlasPath.absoluteString
                    )

                    let source = TextureAtlasTileSource(
                        from: image.asset,
                        size: SizeInt(width: tileSource.tileGridSize, height: tileSource.tileGridSize),
                        margin: SizeInt(width: tileSource.padding, height: tileSource.padding)
                    )

                    source.name = tileSource.identifier
                    source.id = tileSource.uid

                    tileSet.addTileSource(source)
                }

                self.tileSet = tileSet
            }

            if currentProject?.defs.layers != project.defs.layers {
                for layer in self.layers {
                    self.removeLayer(layer)
                }

                /// Add layers from project to tile map.
                for layer in project.defs.layers {
                    let newLayer = self.createLayer()
                    newLayer.name = layer.identifier
                    newLayer.id = layer.uid
                }
            }

            self.project = project
            self.levelsCount = project.levels.count

            if levelsCount > 0 {
                self.loadLevel(at: self.currentLevelIndex)
            }

            self.setNeedsUpdate()
        }
    }
}

// MARK: - Tile Source

extension LDtk {
    /// A tile source for entities.
    public class EntityTileSource: TileEntityAtlasSource, @unchecked Sendable {
        /// The delegate of the entity tile source.
        weak var delegate: TileMapDelegate?

        /// Initialize a new entity tile source.
        override public init() {
            super.init()
        }

        /// Initialize a new entity tile source from a decoder.
        ///
        /// - Parameter decoder: The decoder to initialize the entity tile source from.
        /// - Throws: An error if the entity tile source cannot be initialized from the decoder.
        public required init(from _: any Decoder) throws {
            fatalErrorMethodNotImplemented()
        }

        /// Encode the entity tile source to an encoder.
        ///
        /// - Parameter encoder: The encoder to encode the entity tile source to.
        /// - Throws: An error if the entity tile source cannot be encoded to the encoder.
        override public func encode(to _: any Encoder) throws {
            fatalErrorMethodNotImplemented()
        }

        /// Check if the entity tile source has a tile at the given atlas coordinates.
        ///
        /// - Parameter atlasCoordinates: The atlas coordinates to check.
        /// - Returns: A Boolean value indicating whether the entity tile source has a tile at the given atlas coordinates.
        public func hasTile(at atlasCoordinates: PointInt) -> Bool {
            return self.tiles[atlasCoordinates] != nil
        }

        /// Create a tile for the entity tile source.
        ///
        /// - Parameters:
        ///   - atlasCoordinates: The atlas coordinates to create the tile for.
        ///   - entityInstance: The entity instance to create the tile for.
        public func createTile(
            at atlasCoordinates: PointInt,
            entityInstance: LDtk.EntityInstance
        ) {
            let entity = AdaECS.Entity(name: entityInstance.identifier)

            if let source = self.tileSet?.sources[entityInstance.tile.tilesetUid] as? TextureAtlasTileSource {
                let tileCoordinate = Utils.gridCoordinates(
                    from: [entityInstance.tile.x, entityInstance.tile.y],
                    gridSize: entityInstance.tile.w
                )

                if !source.hasTile(at: tileCoordinate) {
                    source.createTile(for: tileCoordinate)
                }

                let data = source.getTileData(at: tileCoordinate)
                let texture = source.getTexture(at: tileCoordinate)
                entity.components += Sprite(
                    texture: AssetHandle(texture),
                    tintColor: data.modulateColor
                )
            }

            if let ldtkTileMap = self.tileSet?.tileMap as? LDtk.TileMap {
                self.delegate?.tileMap(ldtkTileMap, needsUpdate: entity, from: entityInstance, in: self)
            }

            self.createTile(at: atlasCoordinates, for: entity)
        }
    }
}

/// Delegate that help configure LDtk TileMap.
public protocol TileMapDelegate: AnyObject {
    /// Configure entity from LDtk project. By default entity has ``Transform`` and ``Sprite``
    ///
    /// - Parameter tileMap: Instance of TileMap.
    /// - Parameter entity: AdaEngine entity which will store in TileSource.
    /// - Parameter instance: Entity Instance from LDtk project. Use this object to get info about entity
    /// - Parameter tileSource: Instance of TileSource where entity will store.
    func tileMap(
        _ tileMap: LDtk.TileMap,
        needsUpdate entity: AdaECS.Entity,
        from instance: LDtk.EntityInstance,
        in tileSource: LDtk.EntityTileSource
    )
}

// MARK: - JSON Data

extension LDtk {
    struct Project: Codable, Equatable {
        let iid: String
        let jsonVersion: Version
        let defs: Definitions
        let levels: [Level]
    }

    struct Definitions: Codable, Equatable {
        let tilesets: [TileSet]
        let entities: [EntitySet]
        let layers: [Layer]
    }

    struct TileSet: Codable, Equatable {
        let uid: Int
        let identifier: String
        let relPath: String?
        let tileGridSize: Int
        let spacing: Int
        let padding: Int
    }

    struct EntitySet: Codable, Equatable {
        let uid: Int
        let identifier: String
        let width: Int
        let height: Int
        let color: String
        let tilesetId: Int
        let tileRenderMode: String
        let fieldDefs: [FieldDefinition]
    }

    struct FieldDefinition: Codable, Equatable {
        let identifier: String
        let uid: Int
        let __type: String
    }

    struct Level: Codable, Equatable {
        let identifier: String
        let iid: String
        let layerInstances: [LayerInstance]
    }

    struct LayerInstance: Codable, Equatable {
        let __identifier: String
        let __type: LayerType
        let __gridSize: Int
        let __cWid: Int
        let __cHei: Int
        let iid: String
        let layerDefUid: Int
        let visible: Bool
        let gridTiles: [GridTileData]
        let autoLayerTiles: [GridTileData]
        let entityInstances: [EntityInstance]?
    }

    enum LayerType: String, Codable, Equatable {
        case autoLayer = "AutoLayer"
        case intGrid = "IntGrid"
        case tiles = "Tiles"
        case entities = "Entities"
    }

    struct GridTileData: Codable, Equatable {
        /// Pixel coordinates of the tile in the layer (array format [x,y]). Don’t forget optional layer offsets, if they exist!
        let position: [Int]

        /// Pixel coordinates of the tile in the tileset ([x,y] format)
        let source: [Int]

        /// “Flip bits”, a 2-bits integer to represent the mirror transformations of the tile.
        /// Bit 0 is X symmetry and bit 1 is Y symmetry.
        /// So you get the following possible values:
        let flipBits: Int

        ///  Alpha/opacity of the tile (0-1, defaults to 1)
        let alpha: Float

        /// The *Tile ID* in the corresponding tileset.
        let tileId: Int

        /// Internal data used by the editor.
        /// - For auto-layer tiles: `[ruleId, coordId]`.
        /// - For tile-layer tiles: `[coordId]`.
        let data: [Int]

        enum CodingKeys: String, CodingKey {
            case position = "px"
            case source = "src"
            case flipBits = "f"
            case alpha = "a"
            case tileId = "t"
            case data = "d"
        }
    }

    struct Layer: Codable, Equatable {
        let identifier: String
        let type: LayerType
        let uid: Int
        let tilesetDefUid: Int?
        let gridSize: Int
    }

    struct Entity: Codable, Equatable {
        let identifier: String
        let uid: Int
        let width: Int
        let height: Int
        let color: String
        let tilesetId: Int
    }

    public struct EntityInstance: Codable, Equatable {
        public let identifier: String
        public let tile: Tile
        public let iid: String
        public let width: Int
        public let height: Int
        public let defUid: Int
        public let px: [Int]
        public let fieldInstances: [FieldInstance]

        enum CodingKeys: String, CodingKey {
            case identifier = "__identifier"
            case tile = "__tile"
            case iid, width, height, defUid, px, fieldInstances
        }
    }

    /// A tile.
    public struct Tile: Codable, Equatable {
        public let tilesetUid: Int
        public let x: Int
        public let y: Int
        public let w: Int
        public let h: Int
    }

    /// A field instance.
    public struct FieldInstance: Codable, Equatable {
        public let identifier: String
        public let type: String
        public let value: Value
        public let defUid: Int
        public let readEditorValues: [EditorValue]?

        enum CodingKeys: String, CodingKey {
            case identifier = "__identifier"
            case type = "__type"
            case value = "__value"
            case defUid, readEditorValues
        }

        public init(from decoder: any Decoder) throws {
            let container: KeyedDecodingContainer<LDtk.FieldInstance.CodingKeys> = try decoder.container(keyedBy: LDtk.FieldInstance.CodingKeys.self)
            self.identifier = try container.decode(String.self, forKey: LDtk.FieldInstance.CodingKeys.identifier)
            self.type = try container.decode(String.self, forKey: LDtk.FieldInstance.CodingKeys.type)

            switch type {
            case "Int":
                self.value = try Value.integer(container.decode(Int.self, forKey: LDtk.FieldInstance.CodingKeys.value))
            case "String":
                self.value = try Value.string(container.decode(String.self, forKey: LDtk.FieldInstance.CodingKeys.value))
            default:
                self.value = .undefined
            }

            self.defUid = try container.decode(Int.self, forKey: LDtk.FieldInstance.CodingKeys.defUid)
            self.readEditorValues = try container.decodeIfPresent([LDtk.EditorValue].self, forKey: LDtk.FieldInstance.CodingKeys.readEditorValues)
        }
    }

    /// Contains information for ``FieldInstance``
    public enum Value: Codable, Equatable {
        case integer(Int)
        case string(String)
        case undefined

        /// Return int value if value was an integer
        public var intValue: Int? {
            guard case let .integer(int) = self else {
                return nil
            }

            return int
        }

        /// Return string value if value was a string.
        public var stringValue: String? {
            guard case let .string(string) = self else {
                return nil
            }

            return string
        }
    }

    public struct EditorValue: Codable, Equatable {
        public let id: String
        public let params: [String]
    }
}

// MARK: - Utils

extension LDtk {
    enum Utils {
        static func pixelCoordsToGridCoords(from coords: [Int], gridSize: Int, gridHeight: Int) -> PointInt {
            return PointInt(x: coords[0] / gridSize, y: gridHeight - (coords[1] / gridSize))
        }

        static func gridCoordinates(from pxCoordinates: [Int], gridSize: Int) -> PointInt {
            let gridX = pxCoordinates[0] / gridSize
            let gridY = pxCoordinates[1] / gridSize

            return PointInt(x: gridX, y: gridY)
        }

        static func gridCoordinates(from coordinateId: Int, gridWidth: Int) -> PointInt {
            let gridY = coordinateId / gridWidth
            let gridX = coordinateId - (gridY * gridWidth)

            return PointInt(x: gridX, y: gridY)
        }
    }
}
