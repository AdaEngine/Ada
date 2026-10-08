import AdaAudio
import AdaCorePipelines
import AdaECS
import AdaRender

/// Supplies transient camera components required by rendering for scene imports.
/// Editor and native-export loaders use the same camera preparation.
@MainActor
public enum SceneRuntimeBootstrap {
    public static func prepareCamera(on entity: Entity, in world: World) {
        guard let camera = world.get(Camera.self, from: entity.id) else {
            return
        }
        if world.get(Visibility.self, from: entity.id) == nil {
            world.insert(Visibility.visible, for: entity.id)
        }
        if world.get(VisibleEntities.self, from: entity.id) == nil {
            world.insert(VisibleEntities(), for: entity.id)
        }
        if world.get(GlobalViewUniform.self, from: entity.id) == nil {
            world.insert(GlobalViewUniform(), for: entity.id)
        }
        if world.get(AudioReceiver.self, from: entity.id) == nil {
            world.insert(AudioReceiver(), for: entity.id)
        }
        if world.get(CameraRenderGraph.self, from: entity.id) == nil {
            let renderGraph: CameraRenderGraph
            switch camera.projection {
            case .perspective:
                renderGraph = CameraRenderGraph(subgraphLabel: .main3D, inputSlot: Core3DPlugin.InputNode.view)
            case .orthographic,
                .custom:
                renderGraph = CameraRenderGraph(subgraphLabel: .main2D, inputSlot: Main2DRenderNode.InputNode.view)
            }
            world.insert(renderGraph, for: entity.id)
        }
        if case .perspective = camera.projection,
            world.get(Environment3D.self, from: entity.id) == nil {
            world.insert(Environment3D(), for: entity.id)
        }
    }
}
