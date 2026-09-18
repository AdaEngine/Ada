//
//  Light2DPlugin.swift
//  AdaEngine
//

import AdaApp
import AdaCorePipelines
import AdaECS
import AdaRender

/// Adds Godot-style 2D lighting: ``Light2D``, ``LightOccluder2D``, ``LightModulate2D``, and composite passes on the main 2D subgraph.
public struct Light2DPlugin: Plugin {
    public init() {}

    @MainActor
    public func setup(in app: borrowing AppWorlds) {
        Light2D.registerComponent()
        LightOccluder2D.registerComponent()
        LightModulate2D.registerComponent()

        guard let renderApp = app.getSubworldBuilder(by: .renderWorld) else {
            return
        }
        let world = renderApp.main
        if world.getResource(ExtractedLighting2D.self) == nil {
            world.insertResource(ExtractedLighting2D())
        }
        if let deviceHandler = world.getResource(RenderDeviceHandler.self),
            world.getResource(Light2DRenderPipelines.self) == nil {
            world.insertResource(Light2DRenderPipelines(device: deviceHandler.renderDevice))
        }
        if world.getResource(Lighting2DGPUScratch.self) == nil {
            world.insertResource(Lighting2DGPUScratch())
        }

        world.addSystem(ExtractLighting2DSystem.self, on: .extract)
        world.addSystem(PrepareLighting2DTexturesSystem.self, on: .prepare)

        do {
            try world.getRefResource(RenderGraph.self).wrappedValue
                .updateSubgraph(by: .main2D) { graph in
                    _ = graph.removeNodeEdge(from: Main2DRenderNode.name, to: Light2DCompositeRenderNode.name)
                    _ = graph.removeNodeEdge(from: Light2DCompositeRenderNode.name, to: RenderNodeLabel.Main2D.endPass)
                    _ = graph.removeNodeEdge(from: Main2DRenderNode.name, to: RenderNodeLabel.Main2D.endPass)
                    graph.addNode(Light2DCompositeRenderNode())
                    graph.addNodeEdge(from: Main2DRenderNode.name, to: Light2DCompositeRenderNode.name)
                    graph.addNodeEdge(from: Light2DCompositeRenderNode.name, to: RenderNodeLabel.Main2D.endPass)
                }
        } catch {
            assertionFailure("Light2DPlugin: failed to patch main2D subgraph: \(error)")
        }
    }
}
