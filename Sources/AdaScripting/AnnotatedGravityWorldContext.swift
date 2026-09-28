@_spi(Scripting) import AdaECS
import AdaScene
import Gravity

@GSExportable("AdaWorldContext")
final class AnnotatedGravityWorldContext: @unchecked Sendable, AdaScriptNonSendableBridge {
    let commands: AnnotatedGravityCommandsBridge
    private let navigator: SceneNavigator?
    private let reportDiagnostic: @Sendable (String) -> Void
    private var isActive = true

    @GSExportableIgnore
    static func make(
        world: World,
        commands: AnnotatedGravityCommandsBridge,
        reportDiagnostic: @escaping @Sendable (String) -> Void
    ) -> AnnotatedGravityWorldContext {
        AnnotatedGravityWorldContext(
            commands: commands,
            navigator: world.getResource(SceneNavigator.self),
            reportDiagnostic: reportDiagnostic
        )
    }

    private init(
        commands: AnnotatedGravityCommandsBridge,
        navigator: SceneNavigator?,
        reportDiagnostic: @escaping @Sendable (String) -> Void
    ) {
        self.commands = commands
        self.navigator = navigator
        self.reportDiagnostic = reportDiagnostic
    }

    func spawn(_ components: GSValue) -> Int {
        commands.spawn(components)
    }

    @discardableResult
    func changeScene(_ path: String) -> Bool {
        guard isActive else {
            reportDiagnostic("World capability is no longer valid")
            return false
        }
        guard let navigator else {
            reportDiagnostic("Scene navigation requires ScenePlugin")
            return false
        }
        navigator.requestReplaceScene(with: path, onFailure: reportDiagnostic)
        return true
    }

    @discardableResult
    func reloadScene() -> Bool {
        guard isActive else {
            reportDiagnostic("World capability is no longer valid")
            return false
        }
        guard let navigator else {
            reportDiagnostic("Scene navigation requires ScenePlugin")
            return false
        }
        guard navigator.requestReloadScene(onFailure: reportDiagnostic) else {
            reportDiagnostic("There is no active scene to reload")
            return false
        }
        return true
    }

    func invalidate() {
        isActive = false
        commands.invalidate()
    }
}

@GSExportable("AdaCommands")
final class AnnotatedGravityCommandsBridge: @unchecked Sendable, AdaScriptNonSendableBridge {
    private var commands: Commands?
    private let navigator: SceneNavigator?
    private let reportDiagnostic: @Sendable (String) -> Void
    private let runtimeComponents: [String: RuntimeComponentDescriptor]
    private var isActive = true

    @GSExportableIgnore
    static func make(
        commands: Commands?,
        navigator: SceneNavigator? = nil,
        runtimeComponents: [RuntimeComponentDescriptor] = [],
        reportDiagnostic: @escaping @Sendable (String) -> Void
    ) -> AnnotatedGravityCommandsBridge {
        AnnotatedGravityCommandsBridge(
            commands: commands,
            navigator: navigator,
            runtimeComponents: runtimeComponents,
            reportDiagnostic: reportDiagnostic
        )
    }

    private init(
        commands: Commands?,
        navigator: SceneNavigator?,
        runtimeComponents: [RuntimeComponentDescriptor],
        reportDiagnostic: @escaping @Sendable (String) -> Void
    ) {
        self.commands = commands
        self.navigator = navigator
        self.runtimeComponents = runtimeComponents.reduce(into: [:]) { result, descriptor in
            result[descriptor.name] = descriptor
            result[descriptor.stableID] = descriptor
        }
        self.reportDiagnostic = reportDiagnostic
    }

    func spawn(_ componentValues: GSValue) -> Int {
        guard validateAccess() else {
            return -1
        }
        guard componentValues.isList else {
            reportDiagnostic("world.spawn expects a list of components")
            return -1
        }

        var componentIDs = Set<ComponentId>()
        var components: [any Component] = []
        for componentValue in componentValues.toList {
            let component: any Component
            let diagnosticName: String
            if componentValue.isString {
                let name = componentValue.toString
                guard let defaultComponent = makeDefaultComponent(named: name) else {
                    reportDiagnostic("Component '\(name)' does not have a registered default")
                    return -1
                }
                component = defaultComponent
                diagnosticName = name
            } else if let componentValue = componentValue.toObjectOf(AnnotatedGravityComponentValue.self) {
                guard let draftedComponent = componentValue.takeComponent() else {
                    reportDiagnostic("world.spawn received an invalid or already consumed component")
                    return -1
                }
                component = draftedComponent
                diagnosticName = String(describing: type(of: draftedComponent))
            } else {
                reportDiagnostic("world.spawn values must be component constructors")
                return -1
            }
            let componentID = (component as? RuntimeComponentPayload)?.componentID ?? type(of: component).identifier
            guard componentIDs.insert(componentID).inserted else {
                reportDiagnostic("world.spawn contains duplicate component '\(diagnosticName)'")
                return -1
            }
            components.append(component)
        }

        guard let commands else {
            return -1
        }
        let entityID = commands.spawn(detachedComponents: components).entityId
        navigator?.trackSceneEntity(entityID)
        return entityID
    }

    @discardableResult
    func insert(_ entityID: Int, _ componentName: String) -> Bool {
        guard validateAccess(), let commands else {
            return false
        }
        guard let component = makeDefaultComponent(named: componentName) else {
            reportDiagnostic("Component '\(componentName)' does not have a registered default")
            return false
        }
        commands.insert(component, into: entityID)
        return true
    }

    @discardableResult
    func remove(_ entityID: Int, _ componentName: String) -> Bool {
        guard validateAccess(), let commands else {
            return false
        }
        let componentID: ComponentId
        if let componentType = RuntimeTypeRegistry.componentType(named: componentName) {
            componentID = componentType.identifier
        } else if let descriptor = runtimeComponents[componentName] {
            componentID = descriptor.componentID
        } else {
            reportDiagnostic("Unknown component '\(componentName)'")
            return false
        }
        commands.entity(entityID).remove(componentID, from: entityID)
        return true
    }

    @discardableResult
    func despawn(_ entityID: Int) -> Bool {
        guard validateAccess(), let commands else {
            return false
        }
        commands.entity(entityID).removeFromWorld()
        return true
    }

    func invalidate() {
        isActive = false
        commands = nil
    }

    private func validateAccess() -> Bool {
        guard isActive else {
            reportDiagnostic("World commands capability is no longer valid")
            return false
        }
        guard commands != nil else {
            reportDiagnostic("System did not declare deferred world command access")
            return false
        }
        return true
    }

    private func makeDefaultComponent(named name: String) -> (any Component)? {
        RuntimeTypeRegistry.makeDefaultComponent(named: name) ?? runtimeComponents[name]?.makeDefault()
    }
}
