#if canImport(GravityAOT)
import AdaAssets
@_spi(Scripting) import AdaECS
import AdaInput
import AdaMultiplayer
import AdaScene
import AdaScriptCompilerCore
import AdaTilemap
import AdaUtils
import Foundation
import GravityAOT

final class NativeInputHost: NativeHostObject {
    private let input: Input
    private let scope: NativeCallbackScope
    init(input: Input, scope: NativeCallbackScope) {
        self.input = input
        self.scope = scope
    }
    func call(_ method: String, arguments: [NativeValue]) throws -> NativeValue? {
        try scope.check()
        if method == "available", arguments.isEmpty {
            return .boolean(true)
        }
        guard arguments.count == 1, case .string(let name) = arguments[0] else {
            return nil
        }
        switch method {
        case "isActionPressed": return .boolean(input.isActionPressed(name))
        case "isActionJustPressed": return .boolean(input.isActionJustPressed(name))
        case "isActionJustReleased": return .boolean(input.isActionJustReleased(name))
        case "getActionStrength": return .double(Double(input.getActionStrength(name)))
        default: return nil
        }
    }
}

/// The scheduler declares Commands access; all structural changes remain deferred.
final class NativeWorldHost: NativeHostObject {
    private let scope: NativeCallbackScope
    private let commands: Commands
    private let navigator: SceneNavigator?
    private let components: [RuntimeComponentDescriptor]
    private let module: NativeModule
    init(scope: NativeCallbackScope, commands: Commands, navigator: SceneNavigator?, components: [RuntimeComponentDescriptor], module: NativeModule) {
        self.scope = scope
        self.commands = commands
        self.navigator = navigator
        self.components = components
        self.module = module
    }
    func read(_ key: String) throws -> NativeValue? {
        try scope.check()
        return key == "commands" ? .host(self) : nil
    }
    func call(_ method: String, arguments: [NativeValue]) throws -> NativeValue? {
        try scope.check()
        switch method {
        case "setTileOrientation":
            guard arguments.count == 4, case let .list(coordinates) = arguments[2], coordinates.count == 2 else {
                return nil
            }
            let rawValues = [arguments[0], arguments[1]] + coordinates + [arguments[3]]
            let integers = rawValues.compactMap { value -> Int? in
                guard case let .integer(raw) = value else {
                return nil
            }
                return Int(exactly: raw)
            }
            guard integers.count == 5 else {
                return nil
            }
            return .boolean(AdaScriptTileOrientationCommand.enqueue(
                commands: commands,
                entity: integers[0],
                layer: integers[1],
                x: integers[2],
                y: integers[3],
                orientation: integers[4],
                reportDiagnostic: { RuntimeLogStore.shared.append(level: "error", label: "AdaScript", message: $0) }
            ))
        case "spawn":
            guard arguments.count == 1, case .list(let values) = arguments[0] else {
                return nil
            }
            var detached: [any Component] = []
            var ids = Set<ComponentId>()
            for value in values {
                let component = try makeComponent(value)
                let id = (component as? RuntimeComponentPayload)?.componentID ?? type(of: component).identifier
                guard ids.insert(id).inserted else { throw AdaScriptError.invalidManifest("Duplicate component in world.spawn") }
                detached.append(component)
            }
            let id = commands.spawn(detachedComponents: detached).entityId
            navigator?.trackSceneEntity(id)
            return .integer(Int64(id))
        case "despawn":
            guard arguments.count == 1, case .integer(let raw) = arguments[0], let id = Int(exactly: raw) else {
                return nil
            }
            commands.entity(id).removeFromWorld()
            return .boolean(true)
        case "insert", "remove":
            guard arguments.count == 2, case .integer(let raw) = arguments[0], let id = Int(exactly: raw) else {
                return nil
            }
            if method == "insert" {
                commands.insert(try makeComponent(arguments[1]), into: id)
            } else {
                guard case .string(let name) = arguments[1] else {
                    return nil
                }
                let componentID =
                    RuntimeTypeRegistry.componentType(named: name)?.identifier
                    ?? components.first(where: { $0.name == name || $0.stableID == name })?.componentID
                guard let componentID else { throw AdaScriptError.invalidManifest("Unknown native component '\(name)'") }
                commands.entity(id).remove(componentID, from: id)
            }
            return .boolean(true)
        case "changeScene":
            guard arguments.count == 1, case .string(let path) = arguments[0], let navigator else {
                return nil
            }
            navigator.requestReplaceScene(with: path)
            return .boolean(true)
        case "reloadScene":
            guard arguments.isEmpty, let navigator else {
                return nil
            }
            return .boolean(navigator.requestReloadScene())
        default: return nil
        }
    }
    private func makeComponent(_ value: NativeValue) throws -> any Component {
        if case .host(let host) = value, let draft = host as? NativeComponentDraft {
            return try draft.take()
        }
        if case .string(let name) = value {
            if let component = RuntimeTypeRegistry.makeDefaultComponent(named: name) {
                return component
            }
            if let descriptor = components.first(where: { $0.name == name || $0.stableID == name }) {
                return descriptor.makeDefault()
            }
        }
        if case .object(let instance) = value, let descriptor = components.first(where: { $0.name == instance.typeName }) {
            let values = try descriptor.fields.map { field in
                guard let value = try module.read(instance, field: field.key).literal?.reflected else {
                    throw AdaScriptError.invalidManifest("Unsupported component field '\(field.key)'")
                }
                return value
            }
            return RuntimeComponentPayload(componentID: descriptor.componentID, stableID: descriptor.stableID, values: values)
        }
        throw AdaScriptError.invalidManifest("world.spawn/insert expects a component name or a native component value")
    }
}

/// Typed handles and cache identity belong to AdaAssets. This cache is shared by
/// one plugin's systems, with synchronization independent of the native module.
final class NativeAssetStore: @unchecked Sendable {
    private let lock = NSLock()
    private var handles: [String: any AnyAssetHandleInfo] = [:]
    private var loadingFinished = true
    var isLoaded: Bool { lock.withLock { loadingFinished } }
    var tileMaps: [String: TileMap] {
        lock.withLock {
            Dictionary(
                uniqueKeysWithValues: handles.compactMap { key, handle in
                    guard let map = handle.untypedAsset as? TileMap, let path = key.split(separator: "\u{0}").last else {
                        return nil
                    }
                    return (String(path), map)
                }
            )
        }
    }
    func beginPreloading() { lock.withLock { loadingFinished = false } }
    func finishPreloading() { lock.withLock { loadingFinished = true } }
    func preload(paths: [String]) async throws {
        for path in paths {
            try Task.checkCancellation()
            guard let type = AssetsManager.inferAssetType(at: path) else { continue }
            let handle = try await AssetsManager.loadErased(type, at: path)
            let key = String(reflecting: type) + "\u{0}" + path
            lock.withLock { handles[key] = handle }
        }
    }
    func load(typeName: String?, path: String) throws -> String {
        let resolved = typeName.map { AssetsManager.getAssetType(named: $0) } ?? AssetsManager.inferAssetType(at: path)
        guard let type = resolved else {
            throw AdaScriptError.invalidManifest("Unknown asset type for '\(path)'")
        }
        let key = String(reflecting: type) + "\u{0}" + path
        return try lock.withLock {
            if handles[key] != nil {
                return path
            }
            #if WASM
            throw AdaScriptError.invalidManifest("Synchronous Assets.load requires preloaded assets on WebAssembly")
            #else
            handles[key] = try AssetsManager.loadErasedSync(type, at: path, handleChanges: false)
            return path
            #endif
        }
    }
    func loadAsync(typeName: String?, path: String) async throws -> String {
        let resolved = typeName.map { AssetsManager.getAssetType(named: $0) } ?? AssetsManager.inferAssetType(at: path)
        guard let type = resolved else { throw AdaScriptError.invalidManifest("Unknown asset type for '\(path)'") }
        let key = String(reflecting: type) + "\u{0}" + path
        if lock.withLock({ handles[key] != nil }) { return path }
        let handle = try await AssetsManager.loadErased(type, at: path)
        try Task.checkCancellation()
        lock.withLock { handles[key] = handle }
        return path
    }
    func saveAsync(reference: String, path: String) async throws -> String {
        guard let asset = lock.withLock({ handles.values.first(where: { $0.assetPath == reference })?.untypedAsset }) else {
            throw AdaScriptError.invalidManifest("Cannot save an unloaded asset")
        }
        #if WASM
        throw AdaScriptError.invalidManifest("Assets.save is unavailable in the WebAssembly filesystem")
        #else
        func saveOpened<A: Asset>(_ openedAsset: A) async throws { try await AssetsManager.save(openedAsset, at: path) }
        try Task.checkCancellation()
        try await saveOpened(asset)
        return reference
        #endif
    }
    func save(reference: String, path: String) throws -> String {
        try lock.withLock {
            guard let asset = handles.values.first(where: { $0.assetPath == reference })?.untypedAsset else {
                throw AdaScriptError.invalidManifest("Cannot save an unloaded asset")
            }
            #if WASM
            throw AdaScriptError.invalidManifest("Assets.save is unavailable in the WebAssembly filesystem")
            #else
            try AssetsManager.saveErasedSync(asset, at: path)
            return reference
            #endif
        }
    }
}

final class NativeAssetsHost: NativeHostObject {
    private let store: NativeAssetStore
    private let scope: NativeCallbackScope
    private let asyncRuntime: NativeAsyncRuntime?
    init(store: NativeAssetStore, scope: NativeCallbackScope, asyncRuntime: NativeAsyncRuntime? = nil) {
        self.store = store
        self.scope = scope
        self.asyncRuntime = asyncRuntime
    }
    func call(_ method: String, arguments: [NativeValue]) throws -> NativeValue? {
        try scope.check()
        if method == "perform", arguments.count == 1, case .list(let values) = arguments[0], let operation = values.first, case .string(let name) = operation {
            return try call(name, arguments: Array(values.dropFirst()))
        }
        if method == "begin", arguments.count == 1, case .list(let values) = arguments[0] {
            let strings = values.compactMap { if case .string(let value) = $0 { value } else { nil } }
            guard strings.count == values.count, let name = strings.first else { return nil }
            let operation = AdaScriptAsyncOperation()
            operation.cancellationIsAdvisory = name == "saveAsync"
            let store = self.store
            let worker = Task {
                do {
                    let result: String
                    switch name {
                    case "loadAsync" where strings.count == 2: result = try await store.loadAsync(typeName: nil, path: strings[1])
                    case "loadTypedAsync" where strings.count == 3: result = try await store.loadAsync(typeName: strings[1], path: strings[2])
                    case "saveAsync" where strings.count == 3: result = try await store.saveAsync(reference: strings[1], path: strings[2])
                    default: throw AdaScriptError.invalidManifest("Unknown native async asset operation")
                    }
                    operation.complete(.success(result, committed: name == "saveAsync"))
                } catch is CancellationError {
                    operation.complete(.failure("cancelled", message: "Asset operation was cancelled"))
                } catch { operation.complete(.failure("assetError", message: String(describing: error))) }
            }
            operation.installCancellationAction { worker.cancel() }
            let host = NativeOperationHost(operation)
            asyncRuntime?.track(host)
            return .host(host)
        }
        let strings = arguments.compactMap { if case .string(let v) = $0 { v } else { nil } }
        guard strings.count == arguments.count else {
            return nil
        }
        switch method {
        case "load" where strings.count == 1: return .string(try store.load(typeName: nil, path: strings[0]))
        case "loadTyped" where strings.count == 2: return .string(try store.load(typeName: strings[0], path: strings[1]))
        case "save" where strings.count == 2: return .string(try store.save(reference: strings[0], path: strings[1]))
        default: return nil
        }
    }
}

/// Incoming commands are iterated as borrowed records, avoiding a permanent
/// native list allocation on every frame (the standalone runtime has no GC).
final class NativeRemoteCommandsHost: NativeHostObject {
    private let payloads: [AdaScriptRemoteCommandPayload]
    private let scope: NativeCallbackScope
    init(payloads: [AdaScriptRemoteCommandPayload], scope: NativeCallbackScope) {
        self.payloads = payloads
        self.scope = scope
    }
    func read(_ key: String) throws -> NativeValue? {
        try scope.check()
        return key == "count" ? .integer(Int64(payloads.count)) : nil
    }
    func next(state: inout UInt64) throws -> NativeValue? {
        try scope.check()
        guard let index = Int(exactly: state), index < payloads.count else {
            return nil
        }
        let payload = payloads[index]
        state += 1
        return .host(NativeReadOnlyFields(["source": .string(payload.source), "value": .object(payload.values)]))
    }
}

final class NativeNetworkHost: NativeHostObject {
    private var runtime: ResMut<AdaScriptNetworkRuntime>?
    private let schemas: [AdaScriptNetworkCommandSchema]
    private let module: NativeModule
    private let scope: NativeCallbackScope
    init(runtime: ResMut<AdaScriptNetworkRuntime>?, schemas: [AdaScriptNetworkCommandSchema], module: NativeModule, scope: NativeCallbackScope) {
        self.runtime = runtime
        self.schemas = schemas
        self.module = module
        self.scope = scope
    }
    func call(_ method: String, arguments: [NativeValue]) throws -> NativeValue? {
        try scope.check()
        guard method == "send", arguments.count == 1 else {
            return nil
        }
        if case .host(let host) = arguments[0], let draft = host as? NativeNetworkDraft {
            guard let runtime else { throw AdaScriptError.invalidManifest("MultiplayerPlugin is required") }
            return .boolean(runtime.wrappedValue.send(commandNamed: draft.schema.name, values: draft.values))
        }
        guard case .object(let command) = arguments[0], let schema = schemas.first(where: { $0.name == command.typeName }) else {
            return nil
        }
        let values = try schema.fields.map { field in
            guard let value = try module.read(command, field: field.name).literal?.reflected else {
                throw AdaScriptError.invalidManifest("Invalid native network command field '\(field.name)'")
            }
            return value
        }
        guard let runtime else { throw AdaScriptError.invalidManifest("MultiplayerPlugin is required") }
        return .boolean(runtime.wrappedValue.send(commandNamed: schema.name, values: values))
    }
}
final class NativeComponentDraft: NativeHostObject {
    private var component: (any Component)?
    private let fields: [String: ReflectedComponentField]
    private let scope: NativeCallbackScope
    init(component: any Component, fields: [ReflectedComponentField], scope: NativeCallbackScope) {
        self.component = component
        self.fields = Dictionary(uniqueKeysWithValues: fields.map { ($0.key, $0) })
        self.scope = scope
    }
    func read(_ key: String) throws -> NativeValue? {
        try scope.check()
        guard let component else {
            return nil
        }
        return fields[key]?.read(component)?.nativeValue
    }
    func write(_ key: String, value: NativeValue) throws -> Bool {
        try scope.check()
        guard let component, let field = fields[key], let value = value.literal?.reflected, let changed = field.write(component, value) else {
            return false
        }
        self.component = changed
        return true
    }
    func take() throws -> any Component {
        try scope.check()
        guard let component else { throw AdaScriptError.invalidManifest("Native component draft has already been consumed") }
        self.component = nil
        return component
    }
}

final class NativeComponentFactory: NativeHostObject {
    private let scope: NativeCallbackScope
    private let components: [RuntimeComponentDescriptor]
    init(scope: NativeCallbackScope, components: [RuntimeComponentDescriptor]) {
        self.scope = scope
        self.components = components
    }
    func call(_ method: String, arguments: [NativeValue]) throws -> NativeValue? {
        try scope.check()
        guard method == "makeNamed", arguments.count == 2, case .string(let name) = arguments[0], case .list(let args) = arguments[1] else {
            return nil
        }
        let values = try args.map { value -> ReflectedFieldValue? in
            if case .null = value {
                return nil
            }
            guard let value = value.literal?.reflected else { throw AdaScriptError.invalidManifest("Invalid component constructor value") }
            return value
        }
        if let descriptor = components.first(where: { $0.name == name || $0.stableID == name }) {
            guard values.count == descriptor.fields.count else { throw AdaScriptError.invalidManifest("Invalid native component constructor arity") }
            let payload = RuntimeComponentPayload(componentID: descriptor.componentID, stableID: descriptor.stableID, values: zip(values, descriptor.defaultValues).map { $0 ?? $1 })
            return .host(NativeComponentDraft(component: payload, fields: descriptor.fields, scope: scope))
        }
        guard let constructor = RuntimeTypeRegistry.registeredRuntimeComponentConstructors().first(where: { $0.name == name }) else {
            return nil
        }
        let value = try constructor.construct(arguments: values)
        let fields = ComponentReflectionRegistry.descriptor(named: constructor.typeName)?.fields ?? []
        return .host(NativeComponentDraft(component: value, fields: fields, scope: scope))
    }
}

final class NativeNetworkDraft: NativeHostObject {
    let schema: AdaScriptNetworkCommandSchema
    private(set) var values: [ReflectedFieldValue]
    private let scope: NativeCallbackScope
    init(schema: AdaScriptNetworkCommandSchema, values: [ReflectedFieldValue], scope: NativeCallbackScope) {
        self.schema = schema
        self.values = values
        self.scope = scope
    }
    func read(_ key: String) throws -> NativeValue? {
        try scope.check()
        return schema.fields.firstIndex(where: { $0.name == key }).map { values[$0].nativeValue }
    }
    func write(_ key: String, value: NativeValue) throws -> Bool {
        try scope.check()
        guard let index = schema.fields.firstIndex(where: { $0.name == key }), let value = value.literal?.reflected, nativeFieldCompatible(values[index], value) else {
            return false
        }
        values[index] = value
        return true
    }
}

final class NativeNetworkFactory: NativeHostObject {
    private let schemas: [AdaScriptNetworkCommandSchema]
    private let scope: NativeCallbackScope
    init(schemas: [AdaScriptNetworkCommandSchema], scope: NativeCallbackScope) {
        self.schemas = schemas
        self.scope = scope
    }
    func call(_ method: String, arguments: [NativeValue]) throws -> NativeValue? {
        try scope.check()
        guard method == "makeNamed", arguments.count == 2, case .string(let name) = arguments[0], case .list(let args) = arguments[1],
            let schema = schemas.first(where: { $0.name == name }), args.count == schema.fields.count
        else { return nil }
        let values = try zip(args, schema.fields).map { value, field -> ReflectedFieldValue in
            let fallback: ReflectedFieldValue =
                switch field.defaultValue {
                case .bool(let v): .bool(v)
                case .double(let v): .double(v)
                case .int(let v): .int(Int(v))
                case .string(let v): .string(v)
                }
            if case .null = value {
                return fallback
            }
            guard let value = value.literal?.reflected, nativeFieldCompatible(fallback, value) else {
                throw AdaScriptError.invalidManifest("Invalid network constructor field '\(field.name)'")
            }
            return value
        }
        return .host(NativeNetworkDraft(schema: schema, values: values, scope: scope))
    }
}
#endif
