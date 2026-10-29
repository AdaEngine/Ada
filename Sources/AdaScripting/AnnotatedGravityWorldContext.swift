@_spi(Scripting) import AdaECS
import AdaScene
import Gravity

@GSExportable("AdaWorldContext")
final class AnnotatedGravityWorldContext: @unchecked Sendable, AdaScriptNonSendableBridge {
    let commands: AnnotatedGravityCommandsBridge
    private let navigator: SceneNavigator?
    private let reportDiagnostic: @Sendable (String) -> Void
    private let dynamicAccess: AnnotatedGravityDynamicAccess?
    private let exclusiveAccess: AnnotatedGravityExclusiveAccess?
    private var isActive = true

    @GSExportableIgnore
    static func make(
        world: World,
        commands: AnnotatedGravityCommandsBridge,
        dynamicAccess: AnnotatedGravityDynamicAccess? = nil,
        exclusiveAccess: AnnotatedGravityExclusiveAccess? = nil,
        reportDiagnostic: @escaping @Sendable (String) -> Void
    ) -> AnnotatedGravityWorldContext {
        AnnotatedGravityWorldContext(
            commands: commands,
            navigator: world.getResource(SceneNavigator.self),
            dynamicAccess: dynamicAccess,
            exclusiveAccess: exclusiveAccess,
            reportDiagnostic: reportDiagnostic
        )
    }

    private init(
        commands: AnnotatedGravityCommandsBridge,
        navigator: SceneNavigator?,
        dynamicAccess: AnnotatedGravityDynamicAccess?,
        exclusiveAccess: AnnotatedGravityExclusiveAccess?,
        reportDiagnostic: @escaping @Sendable (String) -> Void
    ) {
        self.commands = commands
        self.navigator = navigator
        self.dynamicAccess = dynamicAccess
        self.exclusiveAccess = exclusiveAccess
        self.reportDiagnostic = reportDiagnostic
    }

    // MARK: @access

    func has(_ entity: Int, _ component: String) -> Bool {
        guard let dynamicAccess = checkedDynamicAccess("has") else { return false }
        return dynamicAccess.has(entity, component)
    }

    func read(_ entity: Int, _ component: String, _ field: String) -> GSValue? {
        guard let dynamicAccess = checkedDynamicAccess("read") else { return nil }
        return dynamicAccess.read(entity, component, field)
    }

    func write(_ entity: Int, _ component: String, _ field: String, _ value: GSValue) -> Bool {
        guard let dynamicAccess = checkedDynamicAccess("write") else { return false }
        return dynamicAccess.write(entity, component, field, value)
    }

    // MARK: @exclusiveWorld

    func spawnImmediate(_ components: GSValue) -> Int {
        guard let exclusiveAccess = checkedExclusiveAccess("spawnImmediate") else { return -1 }
        return exclusiveAccess.spawn(components)
    }

    func insertImmediate(_ entity: Int, _ component: GSValue) -> Bool {
        guard let exclusiveAccess = checkedExclusiveAccess("insertImmediate") else { return false }
        return exclusiveAccess.insert(entity, component)
    }

    func removeImmediate(_ entity: Int, _ component: String) -> Bool {
        guard let exclusiveAccess = checkedExclusiveAccess("removeImmediate") else { return false }
        return exclusiveAccess.remove(entity, component)
    }

    func despawnImmediate(_ entity: Int) -> Bool {
        guard let exclusiveAccess = checkedExclusiveAccess("despawnImmediate") else { return false }
        return exclusiveAccess.despawn(entity)
    }

    private func checkedDynamicAccess(_ operation: String) -> AnnotatedGravityDynamicAccess? {
        guard isActive else {
            reportDiagnostic("World capability is no longer valid")
            return nil
        }
        guard let dynamicAccess else {
            reportDiagnostic("world.\(operation) requires an explicit @access declaration on the system")
            return nil
        }
        return dynamicAccess
    }

    private func checkedExclusiveAccess(_ operation: String) -> AnnotatedGravityExclusiveAccess? {
        guard isActive else {
            reportDiagnostic("World capability is no longer valid")
            return nil
        }
        guard let exclusiveAccess else {
            reportDiagnostic("world.\(operation) requires an @exclusiveWorld system")
            return nil
        }
        return exclusiveAccess
    }

    func spawn(_ components: GSValue) -> Int {
        commands.spawn(components)
    }

    func setTileOrientation(_ entity: Int, _ layer: Int, _ coordinates: GSValue, _ orientation: Int) -> Bool {
        commands.setTileOrientation(entity, layer, coordinates, orientation)
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

    func sceneLoadingProgress() -> Double { navigator?.loadingProgress.fraction ?? 0 }
    func sceneLoadingStage() -> String { navigator?.loadingProgress.stage ?? "idle" }
    func sceneLoadingError() -> String { navigator?.lastError ?? "" }

    func invalidate() {
        isActive = false
        commands.invalidate()
    }
}

@GSExportable("AdaCommands")
final class AnnotatedGravityCommandsBridge: @unchecked Sendable, AdaScriptNonSendableBridge {
    func setTileOrientation(_ entity: Int, _ layer: Int, _ coordinates: GSValue, _ orientation: Int) -> Bool {
        guard validateAccess(), let commands, coordinates.isList else {
            return false
        }
        let values = coordinates.toList
        guard values.count == 2, values.allSatisfy(\.isInteger),
            let x = Int(exactly: values[0].toInteger), let y = Int(exactly: values[1].toInteger) else {
            reportDiagnostic("Tile coordinates must be a pair of integers")
            return false
        }
        return AdaScriptTileOrientationCommand.enqueue(
            commands: commands, entity: entity, layer: layer, x: x, y: y, orientation: orientation, reportDiagnostic: reportDiagnostic
        )
    }

    @GSExportableIgnore
    private var permitCommunitySpawn: (@Sendable () -> Bool)?

    @GSExportableIgnore
    func restrictCommunitySpawns(_ permit: @escaping @Sendable () -> Bool) {
        permitCommunitySpawn = permit
    }
    private var commands: Commands?
    private let navigator: SceneNavigator?
    private let reportDiagnostic: @Sendable (String) -> Void
    private let payloads: AnnotatedGravityComponentPayloads
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
        self.payloads = AnnotatedGravityComponentPayloads(runtimeComponents: self.runtimeComponents, reportDiagnostic: reportDiagnostic)
    }

    func spawn(_ componentValues: GSValue) -> Int {
        guard validateAccess() else {
            return -1
        }
        if let permitCommunitySpawn, !permitCommunitySpawn() {
            reportDiagnostic("Community entity creation limit exceeded")
            return -1
        }
        guard let components = payloads.decodeList(componentValues, operation: "world.spawn") else {
            return -1
        }

        guard let commands else {
            return -1
        }
        let entityID = commands.spawn(detachedComponents: components).entityId
        navigator?.trackSceneEntity(entityID)
        return entityID
    }

    @discardableResult
    func insert(_ entityID: Int, _ componentValue: GSValue) -> Bool {
        guard validateAccess(), let commands else {
            return false
        }
        guard let component = payloads.decodeComponent(componentValue, operation: "world.insert") else {
            return false
        }
        commands.insert(component.value, into: entityID)
        return true
    }

    @discardableResult
    func remove(_ entityID: Int, _ componentName: String) -> Bool {
        guard validateAccess(), let commands else {
            return false
        }
        guard let componentID = payloads.componentID(named: componentName) else {
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
}
