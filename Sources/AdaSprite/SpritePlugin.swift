//
//  SpritePlugin.swift
//  AdaEngine
//
//  Created by v.prusakov on 2/23/23.
//

import AdaApp
import AdaAssets
import AdaCorePipelines
import AdaECS
import AdaRender
import AdaText

/// Plugin for extracting sprites from scene to RenderWorld.
public struct SpritePlugin: Plugin, DeferredRenderSnapshotPlugin {
    public init() {}

    public func setup(in app: AppWorlds) {
        Sprite.registerComponent()
        SpriteAnimator.registerComponent()
        RuntimeTypeRegistry.registerComponent(SpriteAnimator.self, names: ["SpriteAnimator"])
        AssetsManager.registerAssetType(SpriteAnimationSet.self)
        RuntimeTypeRegistry.registerComponent(ParticleEmitter.self, names: ["ParticleEmitter"])
        AssetsManager.registerAssetType(ParticleEffect.self)

        app
            .addSystem(UpdateBoundingsSystem.self, on: .postUpdate)
            .addSystem(ParticleSimulationSystem.self, on: .postUpdate)
            .addSystem(SpriteAnimationSystem.self, on: .update)

        guard let renderWorld = app.getSubworldBuilder(by: .renderWorld) else {
            return
        }

        renderWorld
            // Sprite resources
            .insertResource(ExtractedSprites())
            .insertResource(AdditionalExtractedSprites())
            .insertResource(ExtractedParticleSprites())
            .insertResource(SpriteDrawPass())
            .insertResource(SpriteBatches())
            .initResource(SpriteDrawData.self)
            .initResource(RenderPipelines<SpriteRenderPipeline>.self)
            // Sprite systems
            .addSystem(ExtractSpriteSystem.self, on: .extract)
            .addSystem(ExtractParticleSpritesSystem.self, on: .extract)
            .addSystem(PrepareSpritesSystem.self, on: .preUpdate)
            .addSystem(SpriteRenderSystem.self, on: .update)
            // Text resources
            .insertResource(ExtractedTexts())
            .insertResource(TextDrawPass())
            .insertResource(TextBatches())
            .initResource(TextDrawData.self)
            // Text systems
            .addSystem(ExtractTextSystem.self, on: .extract)
            .addSystem(PrepareTextsSystem.self, on: .preUpdate)
            .addSystem(Text2DRenderSystem.self, on: .update)
    }
}
