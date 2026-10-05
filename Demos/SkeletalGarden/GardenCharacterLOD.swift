import AdaEngine
import Foundation

@MainActor
func installGardenCharacterLOD(root: Entity, model: ModelAsset3D, alternatives: [ModelAsset3D], world: World) {
    var assignments: [(Entity, Int)] = []
    Query<Entity, ModelNode3DComponent>(from: world).forEach { entity, binding in
        if binding.modelRoot == root.id, model.nodes.indices.contains(binding.nodeIndex), let mesh = model.nodes[binding.nodeIndex].meshIndex {
            assignments.append((entity, mesh))
        }
    }
    // Add components after completing the query iteration.
    for (entity, index) in assignments {
        guard alternatives.allSatisfy({ $0.meshes.indices.contains(index) }) else { continue }
        var lod = MeshLOD3DComponent(alternatives: alternatives.map { $0.meshes[index] }, screenThresholds: [0.18, 0.07])
        lod.skeletonCompatible = true
        entity.components[MeshLOD3DComponent.self] = lod
    }
    if var animation = root.components[ModelAnimation3DComponent.self] {
        var settings = AnimationLOD3DSettings()
        settings.center = [0, 1.5, 0]
        animation.evaluationLOD = settings
        root.components[ModelAnimation3DComponent.self] = animation
    }
}

@MainActor
func makeGardenCrowd(model: ModelAsset3D, alternatives: [ModelAsset3D], world: World) throws {
    let terrain = GardenTerrain()
    for row in 0..<8 {
        for column in 0..<8 {
            let x = Float(column) * 4 - 14
            let z = Float(row) * 3 + 8
            let actor = model.instantiate(in: world)
            actor.components[Transform.self] = Transform(scale: [0.55, 0.55, 0.55], position: [x, terrain.surfaceHeight(x: x, z: z), z])
            var animation = actor.components[ModelAnimation3DComponent.self]
            try animation?.player.play("Walk", transitionDuration: 0)
            animation?.player.speed = 0.5 + Double(column) * 0.04
            actor.components[ModelAnimation3DComponent.self] = animation
            if !ProcessInfo.processInfo.arguments.contains("--no-character-lod") {
                installGardenCharacterLOD(root: actor, model: model, alternatives: alternatives, world: world)
            }
        }
    }
    gardenLog("[SkeletalGarden] crowd 64 characters with independent players")
}
