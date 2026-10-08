import Foundation

public enum RuntimeTypeRegistry {
    @MainActor
    public static func registerComponent<T: Component>(
        _ type: T.Type,
        names: [String],
        makeDefault: (@Sendable () -> any Component)? = nil
    ) {
        type.registerComponent()
        for name in names {
            ComponentStorage.addComponent(type, named: name)
            if let makeDefault {
                ComponentStorage.addDefaultFactory(makeDefault, named: name)
            }
            if let constructibleType = type as? any RuntimeConstructibleComponent.Type {
                let descriptor = constructibleType.runtimeComponentConstructor
                if makeDefault != nil || !descriptor.requiresDefaultComponent {
                    ComponentStorage.addRuntimeConstructor(
                        descriptor,
                        named: name,
                        makeDefault: makeDefault
                    )
                }
            }
        }
    }

    @MainActor
    public static func registerResource<T: Resource>(_ type: T.Type, names: [String]) {
        type.registerResource()
        for name in names {
            ResourceStorage.addResource(type, named: name)
        }
    }

    public static func componentType(named name: String) -> (any Component.Type)? {
        ComponentStorage.getRegisteredComponent(for: name)
    }

    public static func resourceType(named name: String) -> (any Resource.Type)? {
        ResourceStorage.getRegisteredResource(for: name)
    }

    public static func registeredComponentTypes() -> [String: any Component.Type] {
        ComponentStorage.allRegisteredComponents()
    }

    public static func registeredResourceTypes() -> [String: any Resource.Type] {
        ResourceStorage.allRegisteredResources()
    }

    public static func makeDefaultComponent(named name: String) -> (any Component)? {
        ComponentStorage.makeDefaultComponent(named: name)
    }

    public static func registeredRuntimeComponentConstructors() -> [RegisteredRuntimeComponentConstructor] {
        ComponentStorage.allRuntimeConstructors().values.sorted { $0.name < $1.name }
    }
}
