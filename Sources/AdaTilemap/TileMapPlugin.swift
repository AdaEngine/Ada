//
//  TileMapPlugin.swift
//  AdaEngine
//
//  Created by v.prusakov on 5/4/24.
//

import AdaApp
import AdaAssets
import AdaECS
import AdaPhysics
import AdaRender
import AdaSprite
import AdaTransform
import Logging
import Math
import OrderedCollections

public struct TileMapPlugin: Plugin {
    public init() {}

    public func setup(in app: AppWorlds) {
        TileMapComponent.registerComponent()

        TextureAtlasTileSource.registerTileSource()
        TileEntityAtlasSource.registerTileSource()

        app.addSystem(TileMapSystem.self)
        app.getSubworldBuilder(by: .renderWorld)?
            .insertResource(AdditionalExtractedSprites())
            .addSystem(ExtractTileMapSpritesSystem.self, on: .extract)
    }
}

@PlainSystem
struct ExtractTileMapSpritesSystem {
    @Extract<Query<Entity, TileMapComponent, GlobalTransform>>
    private var tileMaps

    @ResMut<AdditionalExtractedSprites>
    private var extractedSprites

    init(world _: World) {}

    func update(context _: UpdateContext) {
        extractedSprites.sprites.removeAll(keepingCapacity: true)
        var renderID = Int.min

        tileMaps.wrappedValue.forEach { entity, component, globalTransform in
            if case .some(.hidden) = entity.components[Visibility.self] {
                return
            }

            for layer in component.tileMap.layers {
                guard layer.isEnabled, let tiles = component.renderedAtlasTiles[layer.id] else {
                    continue
                }

                for tile in tiles {
                    let entityID = renderID
                    renderID &+= 1
                    extractedSprites.sprites[entityID] = ExtractedSprite(
                        entityId: entityID,
                        texture: tile.texture,
                        size: component.tileDisplaySize,
                        flipX: false,
                        flipY: false,
                        tintColor: tile.tintColor,
                        transform: tile.transform,
                        worldTransform: globalTransform.matrix * tile.transform.matrix,
                        visibilityEntityId: entity.id
                    )
                }
            }
        }
    }
}

@PlainSystem
public struct TileMapSystem: Sendable {
    private let logger = Logger(label: "org.adaengine.tilemap")

    @Query<Entity, Ref<TileMapComponent>, Transform, Ref<BoundingComponent>>
    private var tileMap

    @Res<Physics2DWorldHolder?>
    private var physicsWorld

    @Commands
    private var commands

    public init(world _: World) {}

    public func update(context _: UpdateContext) {
        tileMap.forEach { entity, tileMapComponent, transform, bounds in
            let tileMap = tileMapComponent.tileMap

            let displaySizeChanged = tileMapComponent.lastRenderedTileDisplaySize != tileMapComponent.tileDisplaySize
            let mapIdentityChanged = tileMapComponent.lastRenderedTileMapID != ObjectIdentifier(tileMap)
            let mapRevisionChanged = tileMapComponent.lastRenderedTileMapRevision != tileMap.updateRevision
            let layerRevisionChanged = tileMap.layers.contains {
                tileMapComponent.lastRenderedLayerRevisions[$0.id] != $0.updateRevision
            }
            guard tileMap.needsUpdate || displaySizeChanged || mapIdentityChanged || mapRevisionChanged || layerRevisionChanged else {
                return
            }

            if mapIdentityChanged {
                for rootID in tileMapComponent.tileLayers.values {
                    self.removeTileRoot(rootID)
                }
                tileMapComponent.tileLayers.removeAll()
                tileMapComponent.renderedAtlasTiles.removeAll()
                tileMapComponent.lastRenderedLayerRevisions.removeAll()
            }

            let layerIDs = Set(tileMap.layers.map(\.id))
            let removedLayers = tileMapComponent.tileLayers.filter { !layerIDs.contains($0.key) }
            for (layerID, rootID) in removedLayers {
                self.removeTileRoot(rootID)
                tileMapComponent.tileLayers[layerID] = nil
                tileMapComponent.renderedAtlasTiles[layerID] = nil
                tileMapComponent.lastRenderedLayerRevisions[layerID] = nil
            }
            for layerID in tileMapComponent.renderedAtlasTiles.keys where !layerIDs.contains(layerID) {
                tileMapComponent.renderedAtlasTiles[layerID] = nil
            }

            for layer in tileMap.layers {
                self.addTiles(
                    for: layer,
                    tileMapComponent: tileMapComponent,
                    transform: transform,
                    entity: entity,
                    forceUpdate: displaySizeChanged
                        || mapIdentityChanged
                        || mapRevisionChanged
                        || tileMapComponent.lastRenderedLayerRevisions[layer.id] != layer.updateRevision
                )
                tileMapComponent.lastRenderedLayerRevisions[layer.id] = layer.updateRevision
            }
            tileMap.updateDidFinish()
            tileMapComponent.lastRenderedTileMapID = ObjectIdentifier(tileMap)
            tileMapComponent.lastRenderedTileMapRevision = tileMap.updateRevision
            tileMapComponent.lastRenderedTileDisplaySize = tileMapComponent.tileDisplaySize
            bounds.bounds = .aabb(Self.bounds(for: tileMap, tileSize: tileMapComponent.tileDisplaySize))
        }
    }

    private static func bounds(for tileMap: TileMap, tileSize: Size) -> AABB {
        guard let firstCell = tileMap.layers.lazy.compactMap({ layer in
            layer.tileCells.keys.first.map { (layer, $0) }
        }).first else {
            return .empty
        }

        let halfWidth = tileSize.width * 0.5
        let halfHeight = tileSize.height * 0.5
        let firstCenter = Vector3(
            Float(firstCell.1.x) * tileSize.width,
            Float(firstCell.1.y) * tileSize.height,
            Float(firstCell.0.zIndex)
        )
        var minimum = firstCenter - Vector3(halfWidth, halfHeight, 0)
        var maximum = firstCenter + Vector3(halfWidth, halfHeight, 0)

        for layer in tileMap.layers {
            for position in layer.tileCells.keys {
                let center = Vector3(
                    Float(position.x) * tileSize.width,
                    Float(position.y) * tileSize.height,
                    Float(layer.zIndex)
                )
                minimum = min(minimum, center - Vector3(halfWidth, halfHeight, 0))
                maximum = max(maximum, center + Vector3(halfWidth, halfHeight, 0))
            }
        }
        return AABB(min: minimum, max: maximum)
    }

    private func removeTileRoot(_ entityID: Entity.ID) {
        commands.queue.push { world in
            world.getEntityByID(entityID)?.removeFromParent()
        }
        commands.entity(entityID).removeFromWorld(recursively: true)
    }

    private func addTiles(
        for layer: TileMapLayer,
        tileMapComponent: Ref<TileMapComponent>,
        transform _: Transform,
        entity: Entity,
        forceUpdate: Bool
    ) {
        let tileSize = tileMapComponent.wrappedValue.tileDisplaySize
        guard let tileSet = layer.tileSet else {
            logger.error(
                "TileSet not found for tiles",
                metadata: [
                    "layer": .string(layer.id.description)
                ]
            )
            return
        }

        if layer.needUpdates || forceUpdate {
            if let rootID = tileMapComponent.tileLayers[layer.id] {
                self.removeTileRoot(rootID)
                tileMapComponent.tileLayers[layer.id] = nil
            }

            var atlasTiles: [TileMapRenderedAtlasTile] = []
            var entityTiles: [Entity] = []

            for (position, tile) in layer.tileCells {
                guard let source = tileSet.sources[tile.sourceId] else {
                    logger.critical(
                        "TileSource not found for id: \(tile.sourceId)",
                        metadata: [
                            "layer": .string(layer.id.description),
                            "tileSourceId": .string(tile.sourceId.description),
                        ]
                    )
                    continue
                }

                let tileData = source.getTileData(at: tile.atlasCoordinates)
                let position = Vector3(
                    x: Float(position.x) * tileSize.width,
                    y: Float(position.y) * tileSize.height,
                    z: Float(layer.zIndex)
                )

                let tileEntity: Entity
                switch source {
                case let atlasSource as TextureAtlasTileSource:
                    let texture = atlasSource.getTexture(at: tile.atlasCoordinates)
                    if let ring = tileData.occluderPolygon, ring.count >= 3 {
                        tileEntity = Entity {
                            Sprite(
                                texture: AssetHandle(texture),
                                tintColor: tileData.modulateColor,
                                size: tileSize
                            )
                            Transform(position: position)
                            LightOccluder2D(points: ring)
                        }
                    } else {
                        atlasTiles.append(
                            TileMapRenderedAtlasTile(
                                texture: texture,
                                tintColor: tileData.modulateColor,
                                transform: Transform(position: position)
                            )
                        )
                        continue
                    }
                case let entitySource as TileEntityAtlasSource:
                    tileEntity = entitySource.getEntity(at: tile.atlasCoordinates)
                    tileEntity.components += Transform(position: position)
                    tileEntity.components[Sprite.self]?.size = tileSize
                    if let ring = tileData.occluderPolygon, ring.count >= 3 {
                        tileEntity.components += LightOccluder2D(points: ring)
                    }
                default:
                    logger.warning("TileSource isn't supported for id: \(tile.sourceId)")
                    continue
                }

                tileEntity.isActive = layer.isEnabled
                entityTiles.append(tileEntity)
            }

            tileMapComponent.renderedAtlasTiles[layer.id] = atlasTiles

            if !entityTiles.isEmpty {
                let tileParent = Entity(name: "TileRoot<\((layer.id, layer.name))>") {
                    RelationshipComponent()
                    Transform()
                }
                tileParent.isActive = layer.isEnabled
                _ = commands.insertEntity(tileParent)
                let tileParentID = tileParent.id
                let ownerID = entity.id
                commands.queue.push { world in
                    guard
                        let owner = world.getEntityByID(ownerID),
                        let parent = world.getEntityByID(tileParentID)
                    else {
                        return
                    }
                    owner.addChild(parent)
                }

                for tileEntity in entityTiles {
                    _ = commands.insertEntity(tileEntity)
                    let tileEntityID = tileEntity.id
                    commands.queue.push { world in
                        guard
                            let parent = world.getEntityByID(tileParentID),
                            let child = world.getEntityByID(tileEntityID)
                        else {
                            return
                        }
                        parent.addChild(child)
                    }
                }
                tileMapComponent.tileLayers[layer.id] = tileParentID
            }
            layer.updateDidFinish()
        }
    }
}
