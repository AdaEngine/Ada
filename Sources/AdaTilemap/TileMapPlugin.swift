//
//  TileMapPlugin.swift
//  AdaEngine
//
//  Created by v.prusakov on 5/4/24.
//

import AdaApp
import AdaECS
import AdaRender
import AdaSprite
import AdaTransform
import Math
import OrderedCollections

public struct TileMapPlugin: Plugin {
    public init() {}

    public func setup(in app: AppWorlds) {
        TileMapComponent.registerComponent()

        TextureAtlasTileSource.registerTileSource()
        TileEntityAtlasSource.registerTileSource()

        app.addSystem(TileMapSystem.self)
        let renderWorld = app.getSubworldBuilder(by: .renderWorld)
        if let world = renderWorld?.main, world.getResource(ExtractedLighting2D.self) == nil {
            world.insertResource(ExtractedLighting2D())
        }
        renderWorld?
            .insertResource(AdditionalExtractedSprites())
            .insertResource(ExtractedTileMapChunks())
            .insertResource(TileMapChunkRenderData())
            .insertResource(TileMapChunkGPUCache())
            .initResource(RenderPipelines<TileMapChunkPipeline>.self)
            .addSystem(ExtractTileMapSpritesSystem.self, on: .extract)
            .addSystem(ExtractLighting2DSystem.self, on: .extract)
            .addSystem(ExtractTileMapOccludersSystem.self, on: .extract)
            .addSystem(PrepareTileMapChunksSystem.self, on: .preUpdate)
    }
}

@PlainSystem
struct ExtractTileMapSpritesSystem {
    @Extract<Query<Entity, TileMapComponent, GlobalTransform, Visibility>>
    private var tileMaps

    @Extract<Query<Entity, NoFrustumCulling>> private var unculled

    @ResMut<AdditionalExtractedSprites>
    private var extractedSprites
    @ResMut<ExtractedTileMapChunks> private var extractedChunks

    init(world: World) {
        if world.getResource(ExtractedTileMapChunks.self) == nil {
            world.insertResource(ExtractedTileMapChunks())
        }
    }

    func update(context _: UpdateContext) {
        extractedSprites.sprites.removeAll(keepingCapacity: true)
        extractedChunks.chunks.removeAll(keepingCapacity: true)
        var renderID = Int.min
        var unculledIDs: Set<Entity.ID> = []
        unculled.wrappedValue.forEach { entity, _ in unculledIDs.insert(entity.id) }

        tileMaps.wrappedValue.forEach { entity, component, globalTransform, visibility in
            if visibility == .hidden {
                return
            }

            for layer in component.tileMap.layers {
                guard layer.isEnabled, let chunks = component.renderedChunks[layer.id] else {
                    continue
                }

                // A tilted XY plane gives individual cells different world-Z painter keys.
                // Retain the per-tile reference path rather than grouping those keys into one chunk.
                let useChunks = component.renderMode == .chunks && globalTransform.matrix.x.z == 0 && globalTransform.matrix.y.z == 0
                for chunk in chunks.values {
                    if useChunks, !chunk.atlasTiles.isEmpty {
                        extractedChunks.chunks.append(ExtractedTileMapChunk(
                            ownerID: entity.id,
                            chunk: chunk,
                            model: globalTransform.matrix,
                            ignoresFrustum: unculledIDs.contains(entity.id)
                        ))
                    }
                    let tiles = useChunks ? chunk.dynamicTiles : chunk.atlasTiles + chunk.dynamicTiles
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
}

@PlainSystem
public struct TileMapSystem: Sendable {
    @Query<Entity, Ref<TileMapComponent>, Transform, Ref<BoundingComponent>>
    private var tileMap

    @Commands
    private var commands

    public init(world _: World) {}

    public func update(context _: UpdateContext) {
        tileMap.forEach { entity, tileMapComponent, _, bounds in
            let tileMap = tileMapComponent.tileMap

            let displaySizeChanged = tileMapComponent.lastRenderedTileDisplaySize != tileMapComponent.tileDisplaySize
            let renderModeChanged = tileMapComponent.lastRenderedRenderMode != tileMapComponent.renderMode
            let mapIdentityChanged = tileMapComponent.lastRenderedTileMapID != ObjectIdentifier(tileMap)
            let mapRevisionChanged = tileMapComponent.lastRenderedTileMapRevision != tileMap.updateRevision
            let layerRevisionChanged = tileMap.layers.contains {
                tileMapComponent.lastRenderedLayerRevisions[$0.id] != $0.updateRevision
            }
            guard tileMap.needsUpdate || displaySizeChanged || renderModeChanged || mapIdentityChanged || mapRevisionChanged || layerRevisionChanged else {
                return
            }

            if mapIdentityChanged {
                for rootID in tileMapComponent.tileLayers.values {
                    self.removeTileRoot(rootID)
                }
                tileMapComponent.tileLayers.removeAll()
                tileMapComponent.renderedChunks.removeAll()
                tileMapComponent.lastRenderedLayerRevisions.removeAll()
                tileMapComponent.lastRenderedLayerFullRevisions.removeAll()
            }

            let layerIDs = Set(tileMap.layers.map(\.id))
            let removedLayers = tileMapComponent.tileLayers.filter { !layerIDs.contains($0.key) }
            for (layerID, rootID) in removedLayers {
                self.removeTileRoot(rootID)
                tileMapComponent.tileLayers[layerID] = nil
                tileMapComponent.renderedChunks[layerID] = nil
                tileMapComponent.lastRenderedLayerRevisions[layerID] = nil
                tileMapComponent.lastRenderedLayerFullRevisions[layerID] = nil
            }
            for layerID in tileMapComponent.renderedChunks.keys where !layerIDs.contains(layerID) {
                tileMapComponent.renderedChunks[layerID] = nil
                tileMapComponent.lastRenderedLayerRevisions[layerID] = nil
                tileMapComponent.lastRenderedLayerFullRevisions[layerID] = nil
            }

            for layer in tileMap.layers {
                self.updateChunks(
                    for: layer,
                    tileMapComponent: tileMapComponent,
                    entity: entity,
                    forceUpdate: displaySizeChanged
                        || mapIdentityChanged
                        || mapRevisionChanged
                        || tileMapComponent.lastRenderedLayerFullRevisions[layer.id] != layer.fullUpdateRevision
                )
                tileMapComponent.lastRenderedLayerRevisions[layer.id] = layer.updateRevision
                tileMapComponent.lastRenderedLayerFullRevisions[layer.id] = layer.fullUpdateRevision
            }
            tileMap.updateDidFinish()
            tileMapComponent.lastRenderedTileMapID = ObjectIdentifier(tileMap)
            tileMapComponent.lastRenderedTileMapRevision = tileMap.updateRevision
            tileMapComponent.lastRenderedTileDisplaySize = tileMapComponent.tileDisplaySize
            tileMapComponent.lastRenderedRenderMode = tileMapComponent.renderMode
            bounds.bounds = .aabb(Self.bounds(for: tileMapComponent.renderedChunks))
        }
    }

    private static func bounds(for layers: [TileMapLayer.ID: [TileMapChunkCoordinate: TileMapRenderedChunk]]) -> AABB {
        var minimum: Vector3?
        var maximum: Vector3?
        for chunks in layers.values {
            for chunk in chunks.values where !chunk.bounds.isEmpty {
                minimum = minimum.map { min($0, chunk.bounds.min) } ?? chunk.bounds.min
                maximum = maximum.map { max($0, chunk.bounds.max) } ?? chunk.bounds.max
            }
        }
        guard let minimum, let maximum else {
            return .empty
        }
        return AABB(min: minimum, max: maximum)
    }

    private func removeTileRoot(_ entityID: Entity.ID) {
        commands.queue.push { world in
            world.getEntityByID(entityID)?.removeFromParent()
        }
        commands.entity(entityID).removeFromWorld(recursively: true)
    }

    private func updateChunks(
        for layer: TileMapLayer,
        tileMapComponent: Ref<TileMapComponent>,
        entity: Entity,
        forceUpdate: Bool
    ) {
        guard forceUpdate || tileMapComponent.lastRenderedLayerRevisions[layer.id] != layer.updateRevision else {
            return
        }
        var chunks = tileMapComponent.renderedChunks[layer.id] ?? [:]
        var rebuildEntities = forceUpdate
        for coordinate in Array(chunks.keys) where layer.chunkCells[coordinate] == nil {
            rebuildEntities = rebuildEntities || chunks[coordinate]?.entityCells.isEmpty == false
            chunks[coordinate] = nil
        }
        for (coordinate, cells) in layer.chunkCells {
            let revision = layer.chunkRevisions[coordinate] ?? layer.updateRevision
            guard forceUpdate || chunks[coordinate]?.revision != revision else {
                continue
            }
            rebuildEntities = rebuildEntities || chunks[coordinate]?.entityCells.isEmpty == false
            let chunk = TileMapChunkBuilder.build(cells: cells, layer: layer, tileSize: tileMapComponent.tileDisplaySize, revision: revision)
            rebuildEntities = rebuildEntities || !chunk.entityCells.isEmpty
            chunks[coordinate] = chunk
        }
        tileMapComponent.renderedChunks[layer.id] = chunks
        if rebuildEntities {
            rebuildEntityTiles(for: layer, chunks: chunks, tileMapComponent: tileMapComponent, entity: entity)
        }
        layer.updateDidFinish()
    }

    private func rebuildEntityTiles(
        for layer: TileMapLayer,
        chunks: [TileMapChunkCoordinate: TileMapRenderedChunk],
        tileMapComponent: Ref<TileMapComponent>,
        entity: Entity
    ) {
        if let rootID = tileMapComponent.tileLayers[layer.id] {
            removeTileRoot(rootID)
            tileMapComponent.tileLayers[layer.id] = nil
        }
        let tileSize = tileMapComponent.tileDisplaySize
        var entityTiles: [Entity] = []
        for chunk in chunks.values {
            for cell in chunk.entityCells {
                guard let source = layer.tileSet?.sources[cell.data.sourceId] else {
                    continue
                }
                let data = source.getTileData(at: cell.data.atlasCoordinates)
                let position = Vector3(Float(cell.position.x) * tileSize.width, Float(cell.position.y) * tileSize.height, Float(layer.zIndex))
                let transform = cell.data.orientation.transform(at: position, tileSize: tileSize)
                let tile: Entity
                if let source = source as? TextureAtlasTileSource {
                    tile = Entity {
                        Sprite(texture: source.getTexture(at: cell.data.atlasCoordinates), tintColor: data.modulateColor, size: tileSize)
                        transform
                    }
                } else if let source = source as? TileEntityAtlasSource {
                    tile = source.getEntity(at: cell.data.atlasCoordinates)
                    tile.components += transform
                    tile.components[Sprite.self]?.size = tileSize
                } else {
                    continue
                }
                if let override = cell.data.occlusion {
                    if override.mode == .disabled {
                        tile.components[LightOccluder2D.self] = nil
                    } else if let ring = override.points {
                        let scale = override.referenceSize.map { Vector2(tileSize.width / $0.width, tileSize.height / $0.height) } ?? Vector2(1, 1)
                        tile.components += LightOccluder2D(points: ring.map { $0 * scale })
                    }
                } else if let ring = data.occluderPolygon, ring.count >= 3 {
                    tile.components += LightOccluder2D(points: ring)
                }
                tile.isActive = layer.isEnabled
                entityTiles.append(tile)
            }
        }
        guard !entityTiles.isEmpty else {
            return
        }
        let parent = Entity(name: "TileRoot<\((layer.id, layer.name))>") { RelationshipComponent(); Transform() }
        parent.isActive = layer.isEnabled
        _ = commands.insertEntity(parent)
        let parentID = parent.id
        let ownerID = entity.id
        commands.queue.push { world in
            guard let owner = world.getEntityByID(ownerID), let parent = world.getEntityByID(parentID) else {
                return
            }
            owner.addChild(parent)
        }
        for tile in entityTiles {
            _ = commands.insertEntity(tile)
            let tileID = tile.id
            commands.queue.push { world in
                guard let parent = world.getEntityByID(parentID), let child = world.getEntityByID(tileID) else {
                    return
                }
                parent.addChild(child)
            }
        }
        tileMapComponent.tileLayers[layer.id] = parentID
    }
}
