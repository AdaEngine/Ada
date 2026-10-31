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
    private let pathTracingPresentation: Bool

    /// Enables depth-tested 2D content in the 3D graph. Requires `Core2DPlugin`.
    public init(includes2D: Bool = false) {
        self.includes2D = includes2D
        self.pathTracingPresentation = false
    }

    /// Uses a presentation shader that consumes already traced surface HDR without another reflection pass.
    public init(includes2D: Bool = false, pathTracingPresentation: Bool) {
        self.includes2D = includes2D
        self.pathTracingPresentation = pathTracingPresentation
    }

    /// Input slots of render graph.
    public enum InputNode {
        public static let view: RenderSlot.Label = "view"
    }

    public func setup(in app: AppWorlds) {
        GLTFLoaderResolver.shared.setLoader(NativeGLTFLoader())
        OBJLoaderResolver.shared.setLoader(NativeOBJLoader())
        Environment3D.registerComponent()
        AssetsManager.registerAssetType(ImageBasedLighting3D.self)
        AssetsManager.registerAssetType(LightmapSet3D.self)
        AssetsManager.registerAssetType(IrradianceProbeGrid3D.self)
        AssetsManager.registerAssetType(ProbeTransport3D.self)
        AssetsManager.registerAssetType(DistanceField3D.self)

        app.insertResource(DebugDraw3D())

        guard let app = app.getSubworldBuilder(by: .renderWorld) else {
            return
        }

        let renderDevice = app.getResource(RenderDeviceHandler.self)
            .unwrap(message: "Failed to fetch RenderDevice from world")
            .renderDevice

        var graph = RenderGraph(label: .main3D)
        let entryNode = graph.addEntryNode(inputs: [
            RenderSlot(name: InputNode.view, kind: .entity),
        ])

        graph.addNode(EmptyNode(), by: .Main3D.beginPass)
        graph.addNode(DirectionalShadow3DRenderNode())
        graph.addNode(LocalShadow3DRenderNode())
        graph.addNode(DynamicIrradiance3DRenderNode())
        graph.addNode(Main3DRenderNode())
        graph.addNode(PathTracing3DRenderNode())
        graph.addNode(PathTracingOverlays3DRenderNode())
        graph.addNode(Particles3DRenderNode())
        graph.addNode(ScreenSpaceGI3DRenderNode())
        graph.addNode(ScreenSpaceAO3DRenderNode())
        graph.addNode(AutoExposure3DRenderNode())
        graph.addNode(Bloom3DRenderNode())
        graph.addNode(AntiAliasing3DRenderNode(notifiesCompletion: !includes2D))
        graph.addNode(VolumetricFog3DRenderNode())
        graph.addNode(ScreenSpaceReflectionRenderNode(notifiesCompletion: !includes2D))
        graph.addNode(Temporal3DRenderNode())
        graph.addNode(DepthOfField3DRenderNode(notifiesCompletion: !includes2D))
        graph.addNode(CameraEffects3DRenderNode(notifiesCompletion: !includes2D))
        graph.addNode(DebugView3DRenderNode(notifiesCompletion: !includes2D))
        graph.addNode(DebugDraw3DRenderNode(notifiesCompletion: !includes2D))
        graph.addNode(EmptyNode(), by: .Main3D.endPass)
        graph.addNode(UpscaleNode())

        graph.addSlotEdge(
            fromNode: entryNode,
            outputSlot: InputNode.view,
            toNode: Main3DRenderNode.name,
            inputSlot: Main3DRenderNode.InputNode.view
        )

        graph.addNodeEdge(from: RenderNodeLabel.Main3D.beginPass, to: DirectionalShadow3DRenderNode.name)
        graph.addNodeEdge(from: DirectionalShadow3DRenderNode.name, to: LocalShadow3DRenderNode.name)
        graph.addNodeEdge(from: LocalShadow3DRenderNode.name, to: DynamicIrradiance3DRenderNode.name)
        graph.addNodeEdge(from: DynamicIrradiance3DRenderNode.name, to: Main3DRenderNode.name)
        graph.addNodeEdge(from: Main3DRenderNode.name, to: PathTracing3DRenderNode.name)
        graph.addNodeEdge(from: PathTracing3DRenderNode.name, to: PathTracingOverlays3DRenderNode.name)
        graph.addNodeEdge(from: PathTracingOverlays3DRenderNode.name, to: ScreenSpaceGI3DRenderNode.name)
        graph.addNodeEdge(from: PathTracingOverlays3DRenderNode.name, to: Particles3DRenderNode.name)
        graph.addNodeEdge(from: PathTracingOverlays3DRenderNode.name, to: ScreenSpaceAO3DRenderNode.name)
        graph.addNodeEdge(from: PathTracingOverlays3DRenderNode.name, to: VolumetricFog3DRenderNode.name)
        graph.addNodeEdge(from: DirectionalShadow3DRenderNode.name, to: Main3DRenderNode.name)
        graph.addNodeEdge(from: Main3DRenderNode.name, to: ScreenSpaceReflectionRenderNode.name)
        graph.addNodeEdge(from: Main3DRenderNode.name, to: ScreenSpaceAO3DRenderNode.name)
        graph.addNodeEdge(from: Main3DRenderNode.name, to: VolumetricFog3DRenderNode.name)
        graph.addNodeEdge(from: Main3DRenderNode.name, to: Particles3DRenderNode.name)
        graph.addNodeEdge(from: Main3DRenderNode.name, to: ScreenSpaceGI3DRenderNode.name)
        graph.addNodeEdge(from: ScreenSpaceGI3DRenderNode.name, to: Particles3DRenderNode.name)
        graph.addNodeEdge(from: Particles3DRenderNode.name, to: ScreenSpaceAO3DRenderNode.name)
        graph.addNodeEdge(from: Particles3DRenderNode.name, to: VolumetricFog3DRenderNode.name)
        graph.addNodeEdge(from: VolumetricFog3DRenderNode.name, to: ScreenSpaceReflectionRenderNode.name)
        graph.addNodeEdge(from: ScreenSpaceAO3DRenderNode.name, to: AutoExposure3DRenderNode.name)
        graph.addNodeEdge(from: AutoExposure3DRenderNode.name, to: Bloom3DRenderNode.name)
        graph.addNodeEdge(from: Bloom3DRenderNode.name, to: ScreenSpaceReflectionRenderNode.name)
        graph.addNodeEdge(from: ScreenSpaceReflectionRenderNode.name, to: AntiAliasing3DRenderNode.name)
        graph.addNodeEdge(from: AntiAliasing3DRenderNode.name, to: Temporal3DRenderNode.name)
        graph.addNodeEdge(from: Temporal3DRenderNode.name, to: DepthOfField3DRenderNode.name)
        graph.addNodeEdge(from: DepthOfField3DRenderNode.name, to: CameraEffects3DRenderNode.name)
        graph.addNodeEdge(from: CameraEffects3DRenderNode.name, to: DebugView3DRenderNode.name)
        graph.addNodeEdge(from: DebugView3DRenderNode.name, to: DebugDraw3DRenderNode.name)
        if includes2D {
            app.insertResource(Scene2DPipelines())
            graph.addNode(Scene2DRenderNode())
            graph.addNodeEdge(from: DebugDraw3DRenderNode.name, to: Scene2DRenderNode.name)
            graph.addNodeEdge(from: Scene2DRenderNode.name, to: RenderNodeLabel.Main3D.endPass)
        } else {
            graph.addNodeEdge(from: DebugDraw3DRenderNode.name, to: RenderNodeLabel.Main3D.endPass)
        }
        graph.addNodeEdge(from: RenderNodeLabel.Main3D.endPass, to: UpscaleNode.name)

        app
            .insertResource(Render3DTemporalStatistics())
            .insertResource(Temporal3DViews())
            .insertResource(Temporal3DPipelines(device: renderDevice))
            .insertResource(ActiveMotion3DPass())
            .insertResource(RenderPipelines(configurator: Motion3DPipeline()))
            .insertResource(ExtractedEnvironment3D())
            .insertResource(ColorCorrection3DViews())
            .insertResource(ExtractedParticles3D())
            .insertResource(Particles3DResources())
            .insertResource(ExtractedLighting3D())
            .insertResource(LocalShadow3DViews())
            .insertResource(Render3DLightStatistics())
            .insertResource(LocalShadow3DScratch())
            .insertResource(LocalShadow3DClear(device: renderDevice))
            .insertResource(LocalLighting3DGPUScratch())
            .insertResource(LightTiles3DScratch())
            .insertResource(RenderPipelines(configurator: LocalShadow3DPipeline()))
            .insertResource(ExtractedMesh3DSources())
            .insertResource(VisibleMesh3DLists())
            .insertResource(GPUVisibility3DState())
            .insertResource(Active3DInstanceBuffers())
            .insertResource(Render3DVisibilityStatistics())
            .insertResource(Lighting3DGPUScratch())
            .insertResource(View3DGPUScratch())
            .insertResource(IBL3DScratch())
            .insertResource(Skinning3DUniforms())
            .insertResource(DirectionalShadow3D())
            .insertResource(DirectionalShadow3DScratch())
            .insertResource(RenderPipelines(configurator: DirectionalShadow3DPipeline()))
            .insertResource(ScreenSpaceReflectionPipeline(device: renderDevice, pathTracingPresentation: pathTracingPresentation))
            .insertResource(ScreenSpaceReflectionScratch())
            .insertResource(ScreenQuality3DPipelines(device: renderDevice))
            .insertResource(ScreenQuality3DScratch())
            .insertResource(DebugView3DPipelines(device: renderDevice))
            .insertResource(Bloom3DViews(device: renderDevice))
            .insertResource(AutoExposure3DViews(device: renderDevice))
            .insertResource(DepthOfField3DViews(device: renderDevice))
            .insertResource(CameraEffects3DViews(device: renderDevice))
            .insertResource(VolumetricFog3DViews(device: renderDevice))
            .insertResource(ScreenSpaceGI3DViews())
            .insertResource(PathTracing3DViews())
            .insertResource(Render3DPathTracingStatistics())
            .insertResource(DynamicIrradiance3DViews())
            .insertResource(Render3DDynamicGIStatistics())
            .insertResource(SurfaceLighting3DViews())
            .insertResource(ActiveContactDepth3DPass())
            .insertResource(RenderPipelines(configurator: ContactDepth3DPipeline()))
            .insertResource(ExtractedDebugLines3D())
            .insertResource(DebugDraw3DResources())
            .addSystem(ExtractDebugDraw3DSystem.self, on: .extract)
            .addSystem(ExtractEnvironment3DSystem.self, on: .extract)
            .addSystem(PrepareEnvironment3DTexturesSystem.self, on: .prepare)
            .addSystem(PrepareTemporal3DSystem.self, on: .prepare)
            .getRefResource(RenderGraph.self)
            .wrappedValue
            .addSubgraph(graph, name: .main3D)
    }
}

public extension RenderGraph.Label {
    /// Render graph name.
    static let main3D: RenderGraph.Label = "Scene 3D Render Graph"
}

public extension RenderNodeLabel {
    enum Main3D {
        public static let beginPass: RenderNodeLabel = "Main3D.BeginPass"
        public static let endPass: RenderNodeLabel = "Main3D.EndPass"
    }
}

public extension RenderNodeLabel {
    static let screenSpaceReflection: RenderNodeLabel = "Main3D.ScreenSpaceReflection"
}
