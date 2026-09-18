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
    }
}

@PlainSystem
public struct TileMapSystem: Sendable {
    private let logger = Logger(label: "org.adaengine.tilemap")

    @Query<Entity, Ref<TileMapComponent>, Transform>
    private var tileMap

    @Res<Physics2DWorldHolder?>
    private var physicsWorld

    @Commands
    private var commands

    public init(world _: World) {}

    public func update(context _: UpdateContext) {
        tileMap.forEach { entity, tileMapComponent, transform in
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
                tileMapComponent.lastRenderedLayerRevisions.removeAll()
            }

            let layerIDs = Set(tileMap.layers.map(\.id))
            let removedLayers = tileMapComponent.tileLayers.filter { !layerIDs.contains($0.key) }
            for (layerID, rootID) in removedLayers {
                self.removeTileRoot(rootID)
                tileMapComponent.tileLayers[layerID] = nil
                tileMapComponent.lastRenderedLayerRevisions[layerID] = nil
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
        }
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
            if let entity = tileMapComponent.tileLayers[layer.id] {
                self.removeTileRoot(entity)
            }

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

                    tileEntity = Entity {
                        Sprite(
                            texture: AssetHandle(texture),
                            tintColor: tileData.modulateColor,
                            size: tileSize
                        )
                        Transform(position: position)
                    }
                    if let ring = tileData.occluderPolygon, ring.count >= 3 {
                        tileEntity.components += LightOccluder2D(points: ring)
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

                //                if tileData.useCollisition {
                //                    tileEntity.components += Collision2DComponent(
                //                        shapes: [.generateBox()],
                //                        filter: CollisionFilter(
                //                            categoryBitMask: tileData.physicLayer.collisionLayer,
                //                            collisionBitMask: tileData.physicLayer.collisionMask
                //                        )
                //                    )
                //                }

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
            layer.updateDidFinish()
        }
    }
}
