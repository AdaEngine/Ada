//
//  SpritePlugin.swift
//  AdaEngine
//
//  Created by v.prusakov on 2/23/23.
//

import AdaApp
import AdaCorePipelines
import AdaECS
import AdaRender
import AdaText

/// Plugin for extracting sprites from scene to RenderWorld.
public struct SpritePlugin: Plugin {
    public init() {}

    public func setup(in app: AppWorlds) {
        Sprite.registerComponent()

        app
            .addSystem(UpdateBoundingsSystem.self, on: .postUpdate)

        guard let renderWorld = app.getSubworldBuilder(by: .renderWorld) else {
            return
        }

        renderWorld
            // Sprite resources
            .insertResource(ExtractedSprites())
            .insertResource(SpriteDrawPass())
            .insertResource(SpriteBatches())
            .initResource(SpriteDrawData.self)
            .initResource(RenderPipelines<SpriteRenderPipeline>.self)
            // Sprite systems
            .addSystem(ExtractSpriteSystem.self, on: .extract)
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
