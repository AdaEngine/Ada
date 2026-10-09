@_spi(Scripting) import AdaECS
import AdaInput
@_spi(Scripting) import AdaScene
import AdaScriptCompilerCore
import Foundation
import Gravity
import Logging

public struct AdaScriptObjectSchema: Equatable, Sendable {
    public let aliases: [String]
    public let bindings: [AdaScriptObjectBinding]
    public let className: String
    public let fields: [String: ReflectedFieldValue]
    public let identifier: String
    public let version: Int

    public init(
        identifier: String,
        className: String,
        version: Int,
        aliases: [String],
        bindings: [AdaScriptObjectBinding] = [],
        fields: [String: ReflectedFieldValue]
    ) {
        self.aliases = aliases
        self.bindings = bindings
        self.className = className
        self.fields = fields
        self.identifier = identifier
        self.version = version
    }
}

public struct AdaScriptObjectBinding: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case component(required: Bool)
        case resource(optional: Bool)
    }

    public let kind: Kind
    public let propertyName: String
    public let typeName: String

    public init(kind: Kind, propertyName: String, typeName: String) {
        self.kind = kind
        self.propertyName = propertyName
        self.typeName = typeName
    }
}

/// Prepared per-game factories and diagnostics; compilation does not register global aliases.
@MainActor
public final class AdaScriptObjectCatalog {
    public let descriptors: [ScriptableObjectDescriptor]
    private let runtime: GravityScriptableModuleRuntime?

    public var diagnostics: [String] { AdaScriptRuntimeCoordinator.lock.withLock { runtime?.diagnostics ?? [] } }

    public init(schemas: [AdaScriptObjectSchema], sources: [AdaScriptSource], communityPolicy: AdaScriptCommunityPolicy? = nil) throws {
        guard !schemas.isEmpty else { runtime = nil; descriptors = []; return }
        let runtime = try GravityScriptableModuleRuntime(sources: sources, schemas: schemas, communityPolicy: communityPolicy)
        self.runtime = runtime
        descriptors = try schemas.map { schema in
            let definition = try GravityScriptableDefinition(schema: schema, runtime: runtime)
            return ScriptableObjectDescriptor(identifier: schema.identifier, version: schema.version, aliases: schema.aliases,
                declaredAccess: definition.declaredAccess, exportedFields: schema.fields, requiredComponents: definition.requiredComponents,
                make: { GravityScriptableObject(definition: definition) },
                decode: { decoder, version in
                    let object = try GravityScriptableObject(definition: definition, payload: GravityScriptablePayload.decode(from: decoder))
                    object.encodedSchemaVersion = version
                    return object
                })
        }
    }
}

public enum AdaScriptObjectRegistration {
    /// Compiles replacement scriptable objects without touching the running world.
    @MainActor
    public static func prepareReload(
        schemas: [AdaScriptObjectSchema],
        sources: [AdaScriptSource],
        moduleName: String
    ) throws -> AdaScriptObjectReloadCandidate {
        try AdaScriptObjectReloadCandidate(
            schemas: schemas,
            sources: sources,
            moduleName: moduleName
        )
    }

    @MainActor
    public static func register(
        schemas: [AdaScriptObjectSchema],
        sources: [AdaScriptSource],
        moduleName: String
    ) throws {
        _ = moduleName
        guard !schemas.isEmpty else {
            return
        }
        let runtime = try GravityScriptableModuleRuntime(
            sources: sources,
            schemas: schemas
        )
        for schema in schemas {
            let definition = try GravityScriptableDefinition(schema: schema, runtime: runtime)
            try ScriptableObjectRegistry.register(
                ScriptableObjectDescriptor(
                    identifier: schema.identifier,
                    version: schema.version,
                    aliases: schema.aliases,
                    declaredAccess: definition.declaredAccess,
                    exportedFields: schema.fields,
                    requiredComponents: definition.requiredComponents,
                    make: { GravityScriptableObject(definition: definition) },
                    decode: { decoder, encodedVersion in
                        let object = try GravityScriptableObject(
                            definition: definition,
                            payload: GravityScriptablePayload.decode(from: decoder)
                        )
                        object.encodedSchemaVersion = encodedVersion
                        return object
                    }
                )
            )
        }
    }
}

/// A validated VM generation for scriptable objects, activated between frames.
@MainActor
public final class AdaScriptObjectReloadCandidate {
    private let definitions: [String: GravityScriptableDefinition]
    private let descriptors: [ScriptableObjectDescriptor]

    // Shared with the registration factory in this file only.
    // swiftlint:disable:next strict_fileprivate
    fileprivate init(schemas: [AdaScriptObjectSchema], sources: [AdaScriptSource], moduleName _: String) throws {
        let runtime = try GravityScriptableModuleRuntime(sources: sources, schemas: schemas)
        let definitions = try schemas.map { try GravityScriptableDefinition(schema: $0, runtime: runtime) }
        self.definitions = Dictionary(uniqueKeysWithValues: definitions.map { ($0.schema.identifier, $0) })
        self.descriptors = definitions.map { definition in
            let schema = definition.schema
            return ScriptableObjectDescriptor(
                identifier: schema.identifier,
                version: schema.version,
                aliases: schema.aliases,
                declaredAccess: definition.declaredAccess,
                exportedFields: schema.fields,
                requiredComponents: definition.requiredComponents,
                make: { GravityScriptableObject(definition: definition) },
                decode: { decoder, encodedVersion in
                    let object = try GravityScriptableObject(
                        definition: definition,
                        payload: GravityScriptablePayload.decode(from: decoder)
                    )
                    object.encodedSchemaVersion = encodedVersion
                    return object
                }
            )
        }
    }

    /// Publishes new factories and rebinds live objects while retaining exported fields.
    public func activate(in world: World) throws {
        try ScriptableObjectRegistry.replaceScriptDescriptors(descriptors)
        for entity in world.getEntities() {
            guard let scripts = world.get(ScriptableComponents.self, from: entity.id)?.scripts else { continue }
            for script in scripts {
                guard let object = script as? GravityScriptableObject,
                    let definition = definitions[object.definition.schema.identifier]
                else { continue }
                object.replaceDefinition(definition)
            }
        }
    }
}

private final class GravityScriptableDefinition: @unchecked Sendable {
    let bindings: [ResolvedGravityScriptableBinding]
    let declaredAccess: SystemAccessSet
    let requiredComponents: [ComponentId]
    let runtime: GravityScriptableModuleRuntime
    let schema: AdaScriptObjectSchema

    init(schema: AdaScriptObjectSchema, runtime: GravityScriptableModuleRuntime) throws {
        let bindings = try schema.bindings.map {
            try Self.resolve($0, scriptableIdentifier: schema.identifier)
        }
        self.bindings = bindings
        var access = SystemAccessSet()
        var requiredComponents: [ComponentId] = []
        for binding in bindings {
            switch binding {
            case let .component(_, type, _, required):
                access.addComponentWrite(type.identifier)
                if required {
                    requiredComponents.append(type.identifier)
                }
            case let .resource(_, type, _, _):
                access.addResourceWrite(ObjectIdentifier(type))
            case .input:
                access.addResourceRead(Input.self)
            }
        }
        access.addDeferredWorldAccess()
        self.declaredAccess = access
        self.requiredComponents = requiredComponents
        self.runtime = runtime
        self.schema = schema
    }

    private static func resolve(
        _ binding: AdaScriptObjectBinding,
        scriptableIdentifier: String
    ) throws -> ResolvedGravityScriptableBinding {
        switch binding.kind {
        case let .component(required):
            guard let type = RuntimeTypeRegistry.componentType(named: binding.typeName) else {
                throw AdaScriptError.unknownComponent(
                    system: scriptableIdentifier,
                    queryIndex: 0,
                    component: binding.typeName
                )
            }
            return .component(
                propertyName: binding.propertyName,
                type: type,
                descriptor: ComponentReflectionRegistry.descriptor(named: String(reflecting: type)),
                required: required
            )
        case let .resource(optional):
            if binding.typeName == "Input" {
                return .input(propertyName: binding.propertyName, optional: optional)
            }
            guard let type = RuntimeTypeRegistry.resourceType(named: binding.typeName) else {
                throw AdaScriptError.unknownResource(
                    system: scriptableIdentifier,
                    resource: binding.typeName
                )
            }
            let fields = RuntimeResourceReflectionRegistry.descriptor(for: type)?.fields ?? []
            return .resource(
                propertyName: binding.propertyName,
                type: type,
                fields: Dictionary(uniqueKeysWithValues: fields.map { ($0.key, $0) }),
                optional: optional
            )
        }
    }

    func validateRequiredBindings(context: ScriptableObjectContext) throws {
        for binding in bindings {
            guard
                case let .component(propertyName, type, _, required) = binding,
                required,
                !context.scriptingWorld.has(type.identifier, in: context.entityID)
            else {
                continue
            }
            throw AdaScriptError.invalidManifest(
                "Required component '\(String(describing: type))' for '\(propertyName)' is missing"
            )
        }
    }
}

private enum ResolvedGravityScriptableBinding: @unchecked Sendable {
    case input(propertyName: String, optional: Bool)
    case component(
        propertyName: String,
        type: any Component.Type,
        descriptor: ReflectedComponentDescriptor?,
        required: Bool
    )
    case resource(
        propertyName: String,
        type: any Resource.Type,
        fields: [String: ReflectedComponentField],
        optional: Bool
    )
}

private final class GravityScriptableObject: ScriptableObject, @unchecked Sendable {
    override var explicitTypeIdentifier: String? { definition.schema.identifier }

    // The reload candidate is the only other type allowed to inspect this definition.
    // swiftlint:disable:next strict_fileprivate
    fileprivate var definition: GravityScriptableDefinition
    private var instanceID: Foundation.UUID?
    private var payload: [String: ReflectedFieldValue]

    @MainActor
    override func readExportedField(_ name: String) -> ReflectedFieldValue? {
        guard definition.schema.fields[name] != nil else {
            return nil
        }
        return payload[name]
    }

    @MainActor
    override func writeExportedField(_ name: String, value: ReflectedFieldValue) -> Bool {
        guard
            let current = payload[name], definition.schema.fields[name] != nil,
            let converted = Self.compatible(value, with: current)
        else {
            return false
        }
        if let instanceID, !definition.runtime.write(instanceID: instanceID, field: name, value: converted) {
            return false
        }
        payload[name] = converted
        return true
    }

    private static func compatible(_ value: ReflectedFieldValue, with current: ReflectedFieldValue) -> ReflectedFieldValue? {
        switch (current, value) {
        case let (.int, .double(number)):
            return Int(exactly: number).map(ReflectedFieldValue.int)
        case let (.double, .int(number)): return .double(Double(number))
        case (.string, .string),
            (.bool, .bool),
            (.int, .int),
            (.array, .array),
            (.object, .object),
            (.null, _):
            return value
        case let (.double, .double(number)): return number.isFinite ? value : nil
        default: return nil
        }
    }

    // A module definition is required and cannot be recovered by the base initializer.
    // swiftlint:disable:next unavailable_function
    required init() {
        fatalError("GravityScriptableObject must be created from a registered descriptor")
    }

    init(
        definition: GravityScriptableDefinition,
        payload: [String: ReflectedFieldValue]? = nil
    ) {
        self.definition = definition
        self.payload = definition.schema.fields.merging(payload ?? [:]) { _, decoded in decoded }
        super.init()
    }

    deinit {
        if let instanceID {
            definition.runtime.remove(instanceID: instanceID)
        }
    }

    required init(from _: Decoder) throws {
        throw ScriptableObjectCodingError.unregisteredRuntimeType("GravityScriptableObject")
    }

    override func encode(to encoder: Encoder) throws {
        if let instanceID {
            payload = definition.runtime.snapshot(instanceID: instanceID, fields: definition.schema.fields.keys)
        }
        try GravityScriptablePayload.encode(payload, to: encoder)
    }

    override func ready(context: ScriptableObjectContext) {
        do {
            try definition.validateRequiredBindings(context: context)
            let instanceID = try definition.runtime.instantiate(
                className: definition.schema.className,
                payload: payload
            )
            self.instanceID = instanceID
            definition.runtime.call(
                instanceID: instanceID,
                method: "ready",
                context: context,
                bindings: definition.bindings
            )
            refreshPayload()
        } catch {
            definition.runtime.report("Unable to start \(definition.schema.identifier): \(error)")
        }
    }

    override func update(context: ScriptableObjectContext) {
        if instanceID == nil { ready(context: context) }
        call(method: "update", context: context)
    }

    override func fixedUpdate(context: ScriptableObjectContext) {
        call(method: "fixedUpdate", context: context)
    }

    override func event(_ events: [any InputEvent], context: ScriptableObjectContext) {
        if instanceID == nil { ready(context: context) }
        guard let instanceID else {
            return
        }
        definition.runtime.callEvent(
            instanceID: instanceID,
            events: events.map { String(reflecting: type(of: $0)) },
            context: context,
            bindings: definition.bindings
        )
        refreshPayload()
    }

    override func destroy(context: ScriptableObjectContext) {
        guard let instanceID else {
            return
        }
        definition.runtime.call(
            instanceID: instanceID,
            method: "destroy",
            context: context,
            bindings: definition.bindings
        )
        refreshPayload()
        definition.runtime.remove(instanceID: instanceID)
        self.instanceID = nil
    }

    private func call(method: String, context: ScriptableObjectContext) {
        guard let instanceID else {
            return
        }
        definition.runtime.call(
            instanceID: instanceID,
            method: method,
            context: context,
            bindings: definition.bindings
        )
        refreshPayload()
    }

    private func refreshPayload() {
        guard let instanceID else {
            return
        }
        payload = definition.runtime.snapshot(instanceID: instanceID, fields: definition.schema.fields.keys)
    }

    @MainActor
    // swiftlint:disable:next strict_fileprivate
    fileprivate func replaceDefinition(_ next: GravityScriptableDefinition) {
        if let instanceID {
            refreshPayload()
            definition.runtime.remove(instanceID: instanceID)
            self.instanceID = nil
        }
        definition = next
    }
}

@GSExportable("AdaScriptableContext")
private final class GravityScriptableLifecycleContext: @unchecked Sendable, AdaScriptNonSendableBridge {
    let deltaTime: Double
    let entityID: Int
    /// Stable world identity for module state scoped to one running scene.
    let worldID: String
    let world: AnnotatedGravityWorldContext

    @GSExportableIgnore
    static func make(
        _ context: ScriptableObjectContext,
        reportDiagnostic: @escaping @Sendable (String) -> Void
    ) -> GravityScriptableLifecycleContext {
        GravityScriptableLifecycleContext(
            deltaTime: Double(context.deltaTime),
            entityID: context.entityID,
            worldID: String(describing: context.scriptingWorld.id),
            world: AnnotatedGravityWorldContext.make(
                world: context.scriptingWorld,
                commands: AnnotatedGravityCommandsBridge.make(
                    commands: context.scriptingCommands,
                    navigator: context.scriptingWorld.getResource(SceneNavigator.self),
                    reportDiagnostic: reportDiagnostic
                ),
                reportDiagnostic: reportDiagnostic
            )
        )
    }

    private init(deltaTime: Double, entityID: Int, worldID: String, world: AnnotatedGravityWorldContext) {
        self.deltaTime = deltaTime
        self.entityID = entityID
        self.worldID = worldID
        self.world = world
    }
}

private final class GravityScriptableModuleRuntime: @unchecked Sendable {
    private enum LifecycleCallback: String, CaseIterable {
        case ready
        case update
        case fixedUpdate
        case event
        case destroy
    }

    private let factoryNamesByClass: [String: String]
    private let getterNamesByClass: [String: [String: String]]
    // The runtime owns its delegate for exactly the VM lifetime; this is not a callback back-reference.
    // swiftlint:disable:next weak_delegate
    private let delegate: AnnotatedGravityRuntimeDelegate
    private let virtualMachine: GravityVirtualMachine
    private var classNamesByInstance: [Foundation.UUID: String] = [:]
    private var instances: [Foundation.UUID: GSValue] = [:]

    private let communityBudget: AdaScriptCommunityBudget?
    var diagnostics: [String] { delegate.errors }

    init(sources: [AdaScriptSource], schemas: [AdaScriptObjectSchema], communityPolicy: AdaScriptCommunityPolicy? = nil) throws {
        AdaScriptRuntimeCoordinator.lock.lock()
        defer { AdaScriptRuntimeCoordinator.lock.unlock() }
        if communityPolicy != nil { for source in sources { try AdaScriptCommunityLowerer.validate(source: source.source) } }
        let componentConstructors = AdaScriptComponentRuntime.linkedConstructors()
        let module = try GravityScriptModuleResolver.resolve(sources)
        for schema in schemas {
            for callback in LifecycleCallback.allCases {
                try module.requireSynchronousCallback(
                    className: schema.className,
                    method: callback.rawValue,
                    annotation: "@scriptable"
                )
            }
        }
        let factoryNamesByClass = Dictionary(
            uniqueKeysWithValues: schemas.enumerated()
                .map { index, schema in
                    (schema.className, "__ada_make_scriptable_\(index)")
                }
        )
        self.factoryNamesByClass = factoryNamesByClass
        let getterNamesByClass = Dictionary(
            uniqueKeysWithValues: schemas.enumerated()
                .map { schemaIndex, schema in
                    let names = Dictionary(
                        uniqueKeysWithValues: schema.fields.keys.sorted().enumerated()
                            .map { fieldIndex, field in
                                (field, "__ada_get_scriptable_\(schemaIndex)_\(fieldIndex)")
                            }
                    )
                    return (schema.className, names)
                }
        )
        self.getterNamesByClass = getterNamesByClass
        let guarded = try module.sourcesByPath.mapValues { source in
            ResolvedGravityScriptModule.Source(fileID: source.fileID, source: communityPolicy == nil ? source.source : try AdaScriptCommunityLowerer.instrument(source: source.source))
        }
        let delegate = AnnotatedGravityRuntimeDelegate(module: module, sourcesByPath: guarded)
        self.delegate = delegate
        let virtualMachine = GravityVirtualMachine(settings: .init(), delegate: delegate)
        self.virtualMachine = virtualMachine
        self.communityBudget = try communityPolicy.map { try AdaScriptCommunityBudget.install(in: virtualMachine, policy: $0) }

        try virtualMachine.bindClass(with: GravityScriptableLifecycleContext.self)
        try virtualMachine.bindClass(with: AnnotatedGravitySystemContext.self)
        try virtualMachine.bindClass(with: AdaScriptInputBridge.self)
        try virtualMachine.bindClass(with: AnnotatedGravityWorldContext.self)
        try virtualMachine.bindClass(with: AnnotatedGravityCommandsBridge.self)
        try virtualMachine.bindClass(with: AnnotatedGravityQueryBridge.self)
        try virtualMachine.bindClass(with: AnnotatedGravityQueryRow.self)
        try virtualMachine.bindClass(with: AnnotatedGravityComponentView.self)
        try virtualMachine.bindClass(with: AnnotatedGravityResourceView.self)
        try virtualMachine.bindClass(with: GravityAttachedComponentView.self)
        try virtualMachine.bindClass(with: GravityAttachedResourceView.self)
        try AdaScriptComponentRuntime.bind(
            to: virtualMachine,
            constructors: componentConstructors,
            reportDiagnostic: delegate.append
        )
        try AdaScriptAssetRuntime.bind(to: virtualMachine, reportDiagnostic: delegate.append)
        let networkCommands = try AdaScriptSchemaParser.parseNetworkCommands(sources: sources)
        try virtualMachine.bindClass(with: AdaScriptMultiplayerAPI.self)
        try virtualMachine.bindClass(with: AdaScriptNetworkCommandFactory.self)
        try virtualMachine.bindClass(with: AdaScriptNetworkCommandValue.self)
        try virtualMachine.bindClass(with: AdaScriptNetworkValueBridge.self)
        try virtualMachine.bindClass(with: AdaScriptRemoteCommandBridge.self)
        virtualMachine.setValue(AdaScriptNetworkCommandFactory.make(schemas: networkCommands, reportDiagnostic: delegate.append), forKey: "__adaNetworkFactory")
        let factories =
            factoryNamesByClass
            .map { className, factoryName in
                "func \(factoryName)() { return \(className)(); }"
            }
            .sorted()
        let getters =
            schemas
            .flatMap { schema in
                getterNamesByClass[schema.className, default: [:]]
                    .map { field, getterName in
                        "func \(getterName)(instance) { return instance.\(field); }"
                    }
            }
            .sorted()
        let generatedSource = (factories + getters).joined(separator: "\n")
        let runtimeSource = (communityPolicy == nil ? "" : "extern var __adaUGCBudget;\n") + (communityPolicy == nil ? AdaScriptStandardLibrary.source : AdaScriptStandardLibrary.communitySource) + "\n"
                + AdaScriptComponentRuntime.prelude(constructors: componentConstructors)
                + AdaScriptNetworkBridge.prelude(commands: networkCommands)
                + module.entrySource
                + "\n"
                + generatedSource
        let binary = virtualMachine.loadGravityFile(from: communityPolicy == nil ? runtimeSource : try AdaScriptCommunityLowerer.instrument(source: runtimeSource))
        guard delegate.errors.isEmpty else {
            throw AdaScriptError.compilation(delegate.errors)
        }
        communityBudget?.reset()
        virtualMachine.load(binary)
        guard delegate.errors.isEmpty else {
            throw AdaScriptError.compilation(delegate.errors)
        }
    }

    func report(_ message: String) {
        delegate.append(message)
        Logger(label: "org.adaengine.AdaScript").error("\(message)")
    }

    func instantiate(className: String, payload: [String: ReflectedFieldValue]) throws -> Foundation.UUID {
        try AdaScriptRuntimeCoordinator.lock.withLock {
            if communityBudget != nil, !delegate.errors.isEmpty { throw AdaScriptError.compilation(delegate.errors) }
            communityBudget?.reset()
            guard let factoryName = factoryNamesByClass[className] else {
                throw AdaScriptError.invalidManifest("Missing @scriptable factory for '\(className)'")
            }
            // Each construction starts a fresh synchronous call stack; live instances remain rooted in globals.
            virtualMachine.reset()
            let factory = virtualMachine.getValue(forKey: factoryName)
            guard
                factory.isClosure,
                let instance = factory.callConstructor(with: []),
                instance.isInstance
            else {
                throw AdaScriptError.invalidManifest("Unable to instantiate @scriptable class '\(className)': \(delegate.errors.last ?? "no VM diagnostic")")
            }
            let identifier = Foundation.UUID()
            // A Swift GSValue is not a VM GC root. Keep live script instances in the
            // VM global table until detach; otherwise allocation-heavy UI bindings
            // can collect an instance while its Swift handle remains alive.
            virtualMachine.setValue(instance, forKey: "__ada_live_script_" + identifier.uuidString)
            for (name, value) in payload {
                _ = instance.setStoredProperty(
                    named: name,
                    to: AnnotatedGravityValueBridge.makeGravityValue(value, virtualMachine: virtualMachine)
                )
            }
            instances[identifier] = instance
            classNamesByInstance[identifier] = className
            return identifier
        }
    }

    func call(
        instanceID: Foundation.UUID,
        method: String,
        context: ScriptableObjectContext,
        bindings: [ResolvedGravityScriptableBinding]
    ) {
        AdaScriptRuntimeCoordinator.lock.withLock {
            if communityBudget != nil, !delegate.errors.isEmpty { return }
            communityBudget?.reset()
            guard let instance = instances[instanceID], instance.hasMethod(named: method) else {
                return
            }
            let inputBindings = bind(bindings, to: instance, context: context)
            defer { for input in inputBindings { input.invalidate() } }
            let lifecycleContext = GravityScriptableLifecycleContext.make(
                context,
                reportDiagnostic: delegate.append
            )
            if let communityBudget { lifecycleContext.world.commands.restrictCommunitySpawns { communityBudget.permitSpawn() } }
            defer { lifecycleContext.world.invalidate() }
            _ = instance.callMethod(
                named: method,
                with: [lifecycleContext]
            )
        }
    }

    func callEvent(
        instanceID: Foundation.UUID,
        events: [String],
        context: ScriptableObjectContext,
        bindings: [ResolvedGravityScriptableBinding]
    ) {
        AdaScriptRuntimeCoordinator.lock.withLock {
            if communityBudget != nil, !delegate.errors.isEmpty { return }
            communityBudget?.reset()
            guard let instance = instances[instanceID], instance.hasMethod(named: "event") else {
                return
            }
            let inputBindings = bind(bindings, to: instance, context: context)
            defer { for input in inputBindings { input.invalidate() } }
            let lifecycleContext = GravityScriptableLifecycleContext.make(
                context,
                reportDiagnostic: delegate.append
            )
            if let communityBudget { lifecycleContext.world.commands.restrictCommunitySpawns { communityBudget.permitSpawn() } }
            defer { lifecycleContext.world.invalidate() }
            _ = instance.callMethod(
                named: "event",
                with: [events, lifecycleContext]
            )
        }
    }

    func snapshot(
        instanceID: Foundation.UUID,
        fields: [String: ReflectedFieldValue].Keys
    ) -> [String: ReflectedFieldValue] {
        AdaScriptRuntimeCoordinator.lock.withLock {
            if communityBudget != nil, !delegate.errors.isEmpty { return [:] }
            communityBudget?.reset()
            guard let instance = instances[instanceID] else {
                return [:]
            }
            guard
                let className = classNamesByInstance[instanceID],
                let getterNames = getterNamesByClass[className]
            else {
                return [:]
            }
            return fields.reduce(into: [:]) { result, field in
                guard let getterName = getterNames[field] else {
                    return
                }
                let getter = virtualMachine.getValue(forKey: getterName)
                guard
                    getter.isClosure,
                    let value = getter.callConstructor(with: [instance]),
                    let converted = AnnotatedGravityValueBridge.makeReflectedFieldValue(value)
                else {
                    return
                }
                result[field] = converted
            }
        }
    }

    func remove(instanceID: Foundation.UUID) {
        AdaScriptRuntimeCoordinator.lock.withLock {
            virtualMachine.setValue(GSValue(nullIn: virtualMachine), forKey: "__ada_live_script_" + instanceID.uuidString)
            instances[instanceID] = nil
            classNamesByInstance[instanceID] = nil
        }
    }

    func write(instanceID: Foundation.UUID, field: String, value: ReflectedFieldValue) -> Bool {
        AdaScriptRuntimeCoordinator.lock.withLock {
            guard let instance = instances[instanceID] else {
                return false
            }
            return instance.setStoredProperty(
                named: field,
                to: AnnotatedGravityValueBridge.makeGravityValue(value, virtualMachine: virtualMachine)
            )
        }
    }

    private func bind(
        _ bindings: [ResolvedGravityScriptableBinding],
        to instance: GSValue,
        context: ScriptableObjectContext
    ) -> [AdaScriptInputBridge] {
        var inputBindings: [AdaScriptInputBridge] = []
        for binding in bindings {
            let propertyName: String
            let bridge: AnyObject
            switch binding {
            case let .input(name, optional):
                propertyName = name
                let input = context.resource(Input.self)
                if input == nil && !optional {
                    delegate.append("Required resource 'Input' is not available")
                }
                let inputBridge = AdaScriptInputBridge.make(input)
                inputBindings.append(inputBridge)
                bridge = inputBridge
            case let .component(name, type, descriptor, _):
                propertyName = name
                bridge = GravityAttachedComponentView.make(
                    world: context.scriptingWorld,
                    entityID: context.entityID,
                    componentType: type,
                    descriptor: descriptor,
                    reportDiagnostic: delegate.append,
                    virtualMachine: virtualMachine
                )
            case let .resource(name, type, fields, optional):
                propertyName = name
                bridge = GravityAttachedResourceView.make(
                    world: context.scriptingWorld,
                    resourceType: type,
                    fields: fields,
                    optional: optional,
                    reportDiagnostic: delegate.append,
                    virtualMachine: virtualMachine
                )
            }
            _ = instance.setStoredProperty(
                named: propertyName,
                to: GSValue(object: bridge, in: virtualMachine)
            )
        }
        return inputBindings
    }
}
