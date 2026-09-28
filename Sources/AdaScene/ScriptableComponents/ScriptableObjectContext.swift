import AdaECS
import AdaInput
import AdaUtils

/// Values and entity-local operations scoped to one scriptable lifecycle callback.
public struct ScriptableObjectContext: Sendable {
    public let deltaTime: AdaUtils.TimeInterval
    public let entityID: Entity.ID
    public let input: Input

    private let commands: Commands
    private let entity: Entity
    private let world: World

    @_spi(Scripting)
    public var scriptingCommands: Commands { commands }

    @_spi(Scripting)
    public var scriptingEntity: Entity { entity }

    @_spi(Scripting)
    public var scriptingWorld: World { world }

    package init(
        entity: Entity,
        world: World,
        commands: Commands,
        input: Input,
        deltaTime: AdaUtils.TimeInterval
    ) {
        self.commands = commands
        self.deltaTime = deltaTime
        self.entity = entity
        self.entityID = entity.id
        self.input = input
        self.world = world
    }

    /// Reads a component from the attached entity.
    public func component<T: Component>(_ type: T.Type = T.self) -> T? {
        entity.components[type]
    }

    /// Writes a component on the attached entity without exposing the raw world.
    public func setComponent<T: Component>(_ component: T) {
        entity.components[T.self] = component
    }

    /// Reads a native resource through the scoped callback context.
    public func resource<T: Resource>(_ type: T.Type = T.self) -> T? {
        world.getResource(type)
    }

    /// Enqueues a native resource replacement after the callback scope.
    public func setResource<T: Resource>(_ resource: T) {
        commands.insertResource(resource)
    }

    /// Returns entities matching an explicitly constructed native query.
    public func entities(matching query: EntityQuery) -> [Entity] {
        Array(world.performQuery(query))
    }

    /// Enqueues an entity spawn after the current scriptable update scope.
    @discardableResult
    public func spawn(
        _ name: String = "",
        @ComponentsBuilder components: @escaping @Sendable () -> ComponentsBundle
    ) -> Entity.ID {
        let entityID = commands.spawn(name, components: components).entityId
        world.getResource(SceneNavigator.self)?.trackSceneEntity(entityID)
        return entityID
    }
}
