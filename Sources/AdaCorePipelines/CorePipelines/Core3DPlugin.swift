//
//  Core3DPlugin.swift
//  AdaEngine
//
//  Created by v.prusakov on 04/21/26.
//

import AdaApp
import AdaAssets
import AdaECS
import AdaRender
import AdaUtils
import Math

/// Plugin for RenderWorld added 3D render capatibilites.
public struct Core3DPlugin: Plugin {
    private let includes2D: Bool

    /// Enables depth-tested 2D content in the 3D graph. Requires `Core2DPlugin`.
    public init(includes2D: Bool = false) {
        self.includes2D = includes2D
    }

    /// Input slots of render graph.
    public enum InputNode {
        public static let view: RenderSlot.Label = "view"
    }

    public func setup(in app: AppWorlds) {
        GLTFLoaderResolver.shared.setLoader(NativeGLTFLoader())
        OBJLoaderResolver.shared.setLoader(NativeOBJLoader())
        Environment3D.registerComponent()

        guard let app = app.getSubworldBuilder(by: .renderWorld) else {
            return
        }

        let renderDevice = app.getResource(RenderDeviceHandler.self)
            .unwrap(message: "Failed to fetch RenderDevice from world")
            .renderDevice

        var graph = RenderGraph(label: .main3D)
        let entryNode = graph.addEntryNode(inputs: [
            RenderSlot(name: InputNode.view, kind: .entity)
        ])

        graph.addNode(EmptyNode(), by: .Main3D.beginPass)
        graph.addNode(DirectionalShadow3DRenderNode())
        graph.addNode(Main3DRenderNode())
        graph.addNode(ScreenSpaceReflectionRenderNode(notifiesCompletion: !includes2D))
        graph.addNode(EmptyNode(), by: .Main3D.endPass)
        graph.addNode(UpscaleNode())

        graph.addSlotEdge(
            fromNode: entryNode,
            outputSlot: InputNode.view,
            toNode: Main3DRenderNode.name,
            inputSlot: Main3DRenderNode.InputNode.view
        )

        graph.addNodeEdge(from: RenderNodeLabel.Main3D.beginPass, to: DirectionalShadow3DRenderNode.name)
        graph.addNodeEdge(from: DirectionalShadow3DRenderNode.name, to: Main3DRenderNode.name)
        graph.addNodeEdge(from: Main3DRenderNode.name, to: ScreenSpaceReflectionRenderNode.name)
        if includes2D {
            app.insertResource(Scene2DPipelines())
            graph.addNode(Scene2DRenderNode())
            graph.addNodeEdge(from: ScreenSpaceReflectionRenderNode.name, to: Scene2DRenderNode.name)
            graph.addNodeEdge(from: Scene2DRenderNode.name, to: RenderNodeLabel.Main3D.endPass)
        } else {
            graph.addNodeEdge(from: ScreenSpaceReflectionRenderNode.name, to: RenderNodeLabel.Main3D.endPass)
        }
        graph.addNodeEdge(from: RenderNodeLabel.Main3D.endPass, to: UpscaleNode.name)

        app
            .insertResource(ExtractedEnvironment3D())
            .insertResource(ExtractedLighting3D())
            .insertResource(Lighting3DGPUScratch())
            .insertResource(DirectionalShadow3D())
            .insertResource(DirectionalShadow3DScratch())
            .insertResource(RenderPipelines(configurator: DirectionalShadow3DPipeline()))
            .insertResource(ScreenSpaceReflectionPipeline(device: renderDevice))
            .insertResource(ScreenSpaceReflectionScratch())
            .addSystem(ExtractEnvironment3DSystem.self, on: .extract)
            .addSystem(PrepareEnvironment3DTexturesSystem.self, on: .prepare)
            .getRefResource(RenderGraph.self)
            .wrappedValue
            .addSubgraph(graph, name: .main3D)
    }
}

extension RenderGraph.Label {
    /// Render graph name.
    public static let main3D: RenderGraph.Label = "Scene 3D Render Graph"
}

extension RenderNodeLabel {
    public enum Main3D {
        public static let beginPass: RenderNodeLabel = "Main3D.BeginPass"
        public static let endPass: RenderNodeLabel = "Main3D.EndPass"
    }
}

extension RenderNodeLabel {
    public static let screenSpaceReflection: RenderNodeLabel = "Main3D.ScreenSpaceReflection"
}
