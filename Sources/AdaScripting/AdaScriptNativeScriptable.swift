#if canImport(GravityAOT)
@_spi(Scripting) import AdaECS
import AdaInput
@_spi(Scripting) import AdaScene
import Foundation
import GravityAOT

private enum NativeObjectBinding: Sendable {
    case component(String, ComponentId, [String: ReflectedComponentField], Bool)
    case compiledResource(String, NativeResourceSchema, Bool)
    case resource(String, any Resource.Type, [String: ReflectedComponentField], Bool)
    case input(String, Bool)
    var property: String {
        switch self {
        case .component(let n, _, _, _), .compiledResource(let n, _, _), .resource(let n, _, _, _), .input(let n, _): n
        }
    }
}

private struct NativeObjectDefinition: Sendable {
    let module: NativeModule
    let type: NativeType
    let identifier: String
    let aliases: [String]
    let version: Int
    let fields: [String: ReflectedFieldValue]
    let bindings: [NativeObjectBinding]
    let access: SystemAccessSet
    let required: [ComponentId]
    let recorder: NativeDiagnostics
    let components: [RuntimeComponentDescriptor]
    let assets = NativeAssetStore()
    var asyncRegistry: NativeAsyncRegistry?

    init(module: NativeModule, type: NativeType, metadata: NativeMetadata, world: World, recorder: NativeDiagnostics) throws {
        guard let annotation = type.declaration.attribute("scriptable") else {
            throw AdaScriptError.invalidManifest("Missing native @scriptable metadata")
        }
        identifier = try annotation.requireString("id")
        if let value = annotation.argument("version") {
            guard case .integer(let v) = value, let version = Int(exactly: v), version > 0 else {
                throw AdaScriptError.invalidManifest("Native scriptable version must be a positive integer")
            }
            self.version = version
        } else {
            version = 1
        }
        if let value = annotation.argument("aliases") {
            guard case .list(let values) = value, values.allSatisfy({ if case .string = $0 { true } else { false } }) else {
                throw AdaScriptError.invalidManifest("Native scriptable aliases must be strings")
            }
            aliases = values.compactMap(\.string)
        } else {
            aliases = []
        }
        fields = try nativeExportedFields(type)
        var bindings: [NativeObjectBinding] = []
        var access = SystemAccessSet()
        access.addDeferredWorldAccess()
        access.addResourceRead(ObjectIdentifier(SceneNavigator.self))
        var required: [ComponentId] = []
        for field in type.fields {
            let declaration = field.declaration
            if let a = declaration.attribute("component") {
                let name = try a.bindingType()
                let isRequired = try a.boolean("required", default: true)
                guard let component = AdaScriptPlugin.resolveComponent(named: name, world: world) else {
                    throw AdaScriptError.unknownComponent(system: identifier, queryIndex: 0, component: name)
                }
                access.addComponentWrite(component.identifier)
                if isRequired { required.append(component.identifier) }
                bindings.append(.component(declaration.name, component.identifier, Dictionary(uniqueKeysWithValues: component.fields.map { ($0.key, $0) }), isRequired))
            } else if let a = declaration.attribute("resource") {
                let name = try a.bindingType()
                let optional = try a.boolean("optional")
                if name == "Input" {
                    access.addResourceRead(ObjectIdentifier(Input.self))
                    bindings.append(.input(declaration.name, optional))
                } else if let schema = metadata.resources[name] {
                    access.addResourceWrite(ObjectIdentifier(AdaScriptNativeResources.self))
                    bindings.append(.compiledResource(declaration.name, schema, optional))
                } else if let type = RuntimeTypeRegistry.resourceType(named: name), let descriptor = RuntimeResourceReflectionRegistry.descriptor(for: type) {
                    access.addResourceWrite(ObjectIdentifier(type))
                    bindings.append(.resource(declaration.name, type, Dictionary(uniqueKeysWithValues: descriptor.fields.map { ($0.key, $0) }), optional))
                } else {
                    throw AdaScriptError.unknownResource(system: identifier, resource: name)
                }
            }
        }
        self.components = metadata.components
        self.module = module
        self.type = type
        self.bindings = bindings
        self.access = access
        self.required = required
        self.recorder = recorder
    }

    @MainActor
    func bind(context: ScriptableObjectContext, scope: NativeCallbackScope, allowUnavailable: Bool = false) throws -> [String: NativeValue] {
        var values: [String: NativeValue] = [:]
        for binding in bindings {
            switch binding {
            case .input(_, let optional):
                guard let input = context.scriptingWorld.getResource(Input.self) else {
                    if !optional && !allowUnavailable { throw AdaScriptError.invalidManifest("Required Input resource is missing") }
                    values[binding.property] = .null
                    continue
                }
                values[binding.property] = .host(NativeInputHost(input: input, scope: scope))
            case .component(_, let id, let fields, let required):
                guard context.scriptingWorld.has(id, in: context.entityID) else {
                    if required && !allowUnavailable { throw AdaScriptError.invalidManifest("Required native component '\(binding.property)' is missing") }
                    values[binding.property] = .null
                    continue
                }
                values[binding.property] = .host(NativeAttachedComponent(world: context.scriptingWorld, entity: context.entityID, component: id, fields: fields, scope: scope))
            case .compiledResource(_, let schema, let optional):
                if context.scriptingWorld.getResource(AdaScriptNativeResources.self)?.values[schema.identifier] == nil {
                    if optional || allowUnavailable {
                        values[binding.property] = .null
                        continue
                    }
                    throw AdaScriptError.invalidManifest("Required native resource '\(schema.name)' is missing")
                }
                values[binding.property] = .host(NativeAttachedResource(world: context.scriptingWorld, scope: scope, storage: .compiled(schema)))
            case .resource(_, let type, let fields, let optional):
                if context.scriptingWorld.getResource(named: String(reflecting: type)) == nil {
                    if optional || allowUnavailable {
                        values[binding.property] = .null
                        continue
                    }
                    throw AdaScriptError.invalidManifest("Required native resource '\(binding.property)' is missing")
                }
                values[binding.property] = .host(NativeAttachedResource(world: context.scriptingWorld, scope: scope, storage: .reflected(type, fields)))
            }
        }
        return values
    }
}

@MainActor
func validateNativeScriptableBindings(module: NativeModule, metadata: NativeMetadata, world: World, recorder: NativeDiagnostics) throws {
    for type in metadata.scriptables {
        _ = try NativeObjectDefinition(module: module, type: type, metadata: metadata, world: world, recorder: recorder)
        for method in type.methods {
            let expected: Int?
            switch method.name {
            case "ready", "update", "fixedUpdate", "destroy": expected = 1
            case "event": expected = 2
            default: expected = nil
            }
            if let expected, method.parameters.count != expected {
                throw AdaScriptError.invalidManifest("Native scriptable '\(type.name).\(method.name)' has an invalid callback signature")
            }
        }
    }
}

@MainActor
func registerNativeScriptables(module: NativeModule, metadata: NativeMetadata, world: World, recorder: NativeDiagnostics, asyncRegistry: NativeAsyncRegistry) throws {
    for type in metadata.scriptables {
        var definition = try NativeObjectDefinition(module: module, type: type, metadata: metadata, world: world, recorder: recorder)
        definition.asyncRegistry = asyncRegistry
        let registeredDefinition = definition
        let descriptor = ScriptableObjectDescriptor(
            identifier: definition.identifier,
            version: definition.version,
            aliases: definition.aliases,
            declaredAccess: definition.access,
            exportedFields: definition.fields,
            requiredComponents: definition.required,
            make: { NativeScriptableObject(definition: registeredDefinition) },
            decode: { decoder, version in
                let object = NativeScriptableObject(definition: registeredDefinition, payload: try GravityScriptablePayload.decode(from: decoder))
                object.encodedSchemaVersion = version
                return object
            }
        )
        if ScriptableObjectRegistry.descriptor(named: definition.identifier) == nil {
            try ScriptableObjectRegistry.register(descriptor)
        } else {
            try ScriptableObjectRegistry.replaceScriptDescriptors([descriptor])
        }
    }
}

/// Instance/payload are protected by a state lock. C storage is independently
/// protected by NativeModule; callbacks borrow world access only within their scope.
private final class NativeScriptableObject: ScriptableObject, @unchecked Sendable {
    override var explicitTypeIdentifier: String? { definition?.identifier }
    private let definition: NativeObjectDefinition?
    private let lock = NSRecursiveLock()
    private var payload: [String: ReflectedFieldValue]
    private var instance: NativeInstance?
    private let asyncRuntime: NativeAsyncRuntime?
    required init() {
        definition = nil
        payload = [:]
        asyncRuntime = nil
        super.init()
    }
    init(definition: NativeObjectDefinition, payload: [String: ReflectedFieldValue]? = nil) {
        self.definition = definition
        asyncRuntime = NativeAsyncRuntime(module: definition.module, registry: definition.asyncRegistry)
        self.payload = definition.fields.merging(payload ?? [:]) { _, decoded in decoded }
        super.init()
    }
    required init(from _: Decoder) throws { throw ScriptableObjectCodingError.unregisteredRuntimeType("NativeScriptableObject") }
    override func encode(to encoder: Encoder) throws {
        try lock.withLock {
            refresh()
            try GravityScriptablePayload.encode(payload, to: encoder)
        }
    }
    @MainActor
    override func readExportedField(_ name: String) -> ReflectedFieldValue? {
        lock.withLock {
            refresh()
            return payload[name]
        }
    }
    @MainActor
    override func writeExportedField(_ name: String, value: ReflectedFieldValue) -> Bool {
        lock.withLock {
            guard let current = payload[name], nativeFieldCompatible(current, value) else {
                return false
            }
            do {
                if let instance, let definition { try definition.module.write(instance, field: name, value: value.nativeValue) }
                payload[name] = value
                return true
            } catch {
                definition?.recorder.append("Unable to write native script field '\(name)': \(error)")
                return false
            }
        }
    }
    @MainActor override func ready(context: ScriptableObjectContext) { call("ready", context: context) }
    @MainActor override func update(context: ScriptableObjectContext) { call("update", context: context) }
    @MainActor override func fixedUpdate(context: ScriptableObjectContext) { call("fixedUpdate", context: context) }
    @MainActor override func event(_ events: [any InputEvent], context: ScriptableObjectContext) {
        call("event", context: context, events: events.map { .string(String(reflecting: type(of: $0))) })
    }
    @MainActor override func destroy(context: ScriptableObjectContext) {
        call("destroy", context: context)
        asyncRuntime?.cancelAll()
        lock.withLock { instance = nil }
    }
    @MainActor
    private func call(_ method: String, context: ScriptableObjectContext, events: [NativeValue]? = nil) {
        lock.withLock {
            guard let definition, definition.recorder.isActive || method == "destroy" else {
                return
            }
            let scope = NativeCallbackScope()
            defer { scope.isActive = false }
            do {
                if instance == nil {
                    instance = try definition.module.makeInstance(type: definition.type.name, globals: asyncRuntime?.globals ?? [:])
                    if let instance { for (name, value) in payload { try definition.module.write(instance, field: name, value: value.nativeValue) } }
                }
                guard let instance else {
                    return
                }
                let world = context.scriptingWorld
                let worldHost = NativeWorldHost(
                    scope: scope,
                    commands: Commands(entities: world.entities, commandsQueue: world.commandQueue),
                    navigator: world.getResource(SceneNavigator.self),
                    components: definition.components,
                    module: definition.module
                )
                let assets = NativeAssetsHost(store: definition.assets, scope: scope, asyncRuntime: asyncRuntime)
                let contextValue = NativeValue.host(NativeSystemContext(scope: scope, deltaTime: Double(context.deltaTime), entityID: context.entityID, world: worldHost, assets: assets))
                let args = events.map { [NativeValue.list($0), contextValue] } ?? [contextValue]
                let bindings = try definition.bind(context: context, scope: scope, allowUnavailable: method == "destroy")
                let globals = (asyncRuntime?.globals ?? [:]).merging(["Assets": .host(assets), "__adaAssets": .host(assets), "__adaComponentFactory": .host(NativeComponentFactory(scope: scope, components: definition.components))]) { _, host in host }
                if method == "update" {
                    asyncRuntime?.advance(deltaTime: Double(context.deltaTime))
                    asyncRuntime?.resume(receiver: instance, bindings: bindings, globals: globals, recorder: definition.recorder)
                }
                guard definition.type.methods.contains(where: { $0.name == method }) else { refresh(); return }
                let value = try definition.module.invoke(
                    instance,
                    method: method,
                    arguments: args,
                    bindings: bindings,
                    globals: globals
                )
                try asyncRuntime?.adopt(value)
                refresh()
            } catch { definition.recorder.append("Native scriptable '\(definition.identifier)' \(method) failed: \(error)") }
        }
    }
    private func refresh() {
        guard let instance, let definition else {
            return
        }
        for name in definition.fields.keys {
            do {
                if let value = try definition.module.read(instance, field: name).literal?.reflected { payload[name] = value }
            } catch { definition.recorder.append("Unable to read native exported field '\(name)': \(error)") }
        }
    }
}

private final class NativeAttachedComponent: NativeHostObject {
    private weak var world: World?
    private let entity: Entity.ID
    private let component: ComponentId
    private let fields: [String: ReflectedComponentField]
    private let scope: NativeCallbackScope
    init(world: World, entity: Entity.ID, component: ComponentId, fields: [String: ReflectedComponentField], scope: NativeCallbackScope) {
        self.world = world
        self.entity = entity
        self.component = component
        self.fields = fields
        self.scope = scope
    }
    func read(_ key: String) throws -> NativeValue? {
        try scope.check()
        guard let world, let field = fields[key] else {
            return nil
        }
        return world.readComponentField(component: component, entity: entity, field: field)?.nativeValue
    }
    func write(_ key: String, value: NativeValue) throws -> Bool {
        try scope.check()
        guard let world, let field = fields[key], let value = value.literal?.reflected else {
            return false
        }
        return world.writeComponentField(component: component, entity: entity, field: field, value: value)
    }
}

private final class NativeAttachedResource: NativeHostObject {
    enum Storage {
        case compiled(NativeResourceSchema)
        case reflected(any Resource.Type, [String: ReflectedComponentField])
    }
    private weak var world: World?
    private let scope: NativeCallbackScope
    private let storage: Storage
    init(world: World, scope: NativeCallbackScope, storage: Storage) {
        self.world = world
        self.scope = scope
        self.storage = storage
    }
    func read(_ key: String) throws -> NativeValue? {
        try scope.check()
        guard let world else {
            return nil
        }
        switch storage {
        case .compiled(let schema): return world.getResource(AdaScriptNativeResources.self)?.values[schema.identifier]?[key]?.nativeValue
        case .reflected(let type, let fields):
            guard let field = fields[key] else {
                return nil
            }
            return world.readResourceField(type: type, field: field)?.nativeValue
        }
    }
    func write(_ key: String, value: NativeValue) throws -> Bool {
        try scope.check()
        guard let world, let value = value.literal?.reflected else {
            return false
        }
        switch storage {
        case .compiled(let schema):
            guard var resources = world.getResource(AdaScriptNativeResources.self), let current = schema.defaults[key], nativeFieldCompatible(current, value) else {
                return false
            }
            resources.values[schema.identifier]?[key] = value
            world.insertResource(resources)
            return true
        case .reflected(let type, let fields):
            guard let field = fields[key] else {
                return false
            }
            return world.writeResourceField(type: type, field: field, value: value)
        }
    }
}
#endif
