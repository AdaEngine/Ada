import AdaECS

/// A component that contains a dynamic scene.
///
/// You can attach you scene to a world dynamically using this component.
/// Entities from the scene will be added to the world as children of the entity with this component.
@Component
public struct DynamicScene {
    /// The scene.
    let scene: AssetHandle<Scene>

    /// Initialize a new dynamic scene.
    ///
    /// - Parameter scene: The scene.
    public init(scene: AssetHandle<Scene>) {
        self.scene = scene
    }

    /// Initialize a new dynamic scene.
    ///
    /// - Parameter world: The world.
    public init(world: World) {
        self.scene = unsafe AssetHandle(Scene(from: world))
    }
}

/// A component that contains a dynamic scene instance.
///
/// This component is used to store the identifier of the scene.
/// It is used to check if the scene has changed.
@Component
public struct DynamicSceneInstance {
    /// The identifier.
    let identifier: World.ID
}

/// A system that initializes and reloads a dynamic scene.
@PlainSystem
struct DynamicSceneInitSystem {
    @Query<Entity, DynamicScene, DynamicSceneInstance?>
    private var dynamicScenes

    init(world _: World) {}

    func update(context: UpdateContext) {
        dynamicScenes.forEach { entity, scene, instance in
            guard let instance else {
                insertScene(to: entity, dynamicScene: scene, world: context.world)
                return
            }

            if unsafe instance.identifier != scene.scene.asset.world.id {
                removeChild(from: entity)
                insertScene(to: entity, dynamicScene: scene, world: context.world)
            }
        }
    }

    private func insertScene(to rootEntity: Entity, dynamicScene: DynamicScene, world: World) {
        let sceneWorld = unsafe dynamicScene.scene.asset.world
        for entity in sceneWorld.getEntities() {
            let copy = entity.copy()
            rootEntity.addChild(copy)
            world.addEntity(copy)
        }

        for resource in sceneWorld.getResources() {
            world.insertResource(resource)
        }

        rootEntity.components += DynamicSceneInstance(identifier: sceneWorld.id)
        world.flush()
    }

    private func removeChild(from entity: Entity) {
        for child in entity.children {
            child.removeFromWorld(recursively: true)
        }
    }
}
