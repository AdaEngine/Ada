import AdaApp
@_spi(Scripting) import AdaECS
import AdaInput
import AdaMultiplayer
import AdaScriptCompilerCore
import Foundation
import Gravity

/// Loads an annotation-driven Ada Script module.
///
/// Systems and queries are discovered from `@system` and `@query`
/// declarations. Ada Script modules do not define a `main()` function.
public final class AdaScriptPlugin: Plugin, @unchecked Sendable {
    public let name: String

    public var pluginIdentifier: String {
        "AdaScripting.Module.\(name)"
    }

    public var diagnostics: [String] {
        runtime.diagnostics
    }

    private let plans: [AnnotatedSystemPlan]
    private let dataSchemas: [AdaScriptDataSchema]
    private let networkCommands: [AdaScriptNetworkCommandSchema]
    private let runtimeComponents: [RuntimeComponentDescriptor]
    private let runtime: AnnotatedGravityRuntime

    public convenience init(contentsOf fileURL: URL) throws {
        try self.init(
            sources: [
                AdaScriptSource(
                    path: fileURL.lastPathComponent,
                    source: String(contentsOf: fileURL, encoding: .utf8)
                )
            ],
            name: fileURL.deletingPathExtension().lastPathComponent
        )
    }

    public convenience init(source: String, name: String = "AdaScript") throws {
        try self.init(
            sources: [AdaScriptSource(path: "Main.ada", source: source)],
            name: name
        )
    }

    /// Creates one Ada Script module from a target-relative source map.
    public init(
        sources: [AdaScriptSource],
        name: String,
        startupSystemIdentifier: String? = nil
    ) throws {
        let componentConstructors = AdaScriptComponentRuntime.linkedConstructors()
        let dataSchemas = try AdaScriptSchemaParser.parse(sources: sources)
        let runtimeComponents = AdaScriptComponentRuntime.runtimeDescriptors(schemas: dataSchemas)
        let networkCommands = try AdaScriptSchemaParser.parseNetworkCommands(sources: sources)
        let module = try GravityScriptModuleResolver.resolve(sources)
        let runtime = try AnnotatedGravityRuntime(
            module: module,
            componentConstructors: componentConstructors,
            runtimeComponents: runtimeComponents,
            networkCommands: networkCommands
        )
        let resourceBindings = try AdaScriptSchemaParser.parseResourceBindings(sources: sources)
        let remoteCommandBindings = try AdaScriptSchemaParser.parseRemoteCommandBindings(sources: sources)
        let rpcMethodBindings = try AdaScriptSchemaParser.parseRPCMethodBindings(sources: sources)
        let networkCommandNames = Set(networkCommands.map(\.name))
        if let unknownBinding = remoteCommandBindings.first(where: { !networkCommandNames.contains($0.commandName) }) {
            throw AdaScriptError.invalidManifest(
                "@remote_commands references unknown command '\(unknownBinding.commandName)'"
            )
        }
        let capabilities = try AdaScriptSchemaParser.parseSystemCapabilities(sources: sources)
        var plans = try AdaScriptSystemPlanBuilder.makePlans(
            from: runtime.annotations,
            remoteCommandBindings: remoteCommandBindings,
            rpcMethodBindings: rpcMethodBindings,
            resourceBindings: resourceBindings,
            systemCapabilities: capabilities
        )
        if let startupSystemIdentifier {
            guard let startupIndex = plans.firstIndex(where: { $0.identifier == startupSystemIdentifier }) else {
                throw AdaScriptError.invalidManifest(
                    "Startup system '\(startupSystemIdentifier)' does not match an @system id."
                )
            }
            guard plans[startupIndex].scheduler == .startup else {
                throw AdaScriptError.invalidManifest(
                    "Startup system '\(startupSystemIdentifier)' must use scheduler: \"startup\"."
                )
            }
            let startupPlan = plans.remove(at: startupIndex)
            plans.insert(startupPlan, at: 0)
        }
        self.name = name
        self.dataSchemas = dataSchemas
        self.networkCommands = networkCommands
        self.runtimeComponents = runtimeComponents
        self.runtime = runtime
        self.plans = plans
        try runtime.instantiateSystems(plans)
    }

    /// Compiles and validates a plugin while keeping its complete VM lifetime serialized.
    nonisolated public static func validate(
        sources: [AdaScriptSource],
        name: String,
        startupSystemIdentifier: String? = nil
    ) throws {
        try AdaScriptRuntimeCoordinator.lock.withLock {
            _ = try AdaScriptPlugin(
                sources: sources,
                name: name,
                startupSystemIdentifier: startupSystemIdentifier
            )
        }
    }

    @MainActor
    public func setup(in app: borrowing AppWorlds) {
        for descriptor in runtimeComponents {
            app.main.registerRuntimeComponent(descriptor)
        }
        let replicatedSchemas = dataSchemas.filter { $0.replication != nil }
        if !networkCommands.isEmpty || !replicatedSchemas.isEmpty {
            guard app.getResource(MultiplayerRegistry.self) != nil else {
                runtime.appendDiagnostic("Typed AdaScript network declarations require MultiplayerPlugin")
                return
            }
            do {
                for schema in replicatedSchemas where
                    RuntimeTypeRegistry.componentType(named: schema.name) == nil &&
                    RuntimeTypeRegistry.componentType(named: schema.id) == nil {
                    guard let descriptor = runtimeComponents.first(where: { $0.stableID == schema.id }) else {
                        continue
                    }
                    let fieldIndices = Dictionary(uniqueKeysWithValues: schema.fields.enumerated().compactMap { index, field in
                        field.network.map { ($0.tag, index) }
                    })
                    app.registerReplicatedRuntimeComponent(
                        descriptor,
                        schema: try AdaScriptNetworkBridge.descriptor(for: schema),
                        fieldIndices: fieldIndices
                    )
                }
                for command in networkCommands {
                    let fields = Dictionary(
                        uniqueKeysWithValues: command.fields.compactMap { field in
                            field.network.map { ($0.tag, field.name) }
                        }
                    )
                    app.registerAdaScriptNetworkCommand(
                        name: command.name,
                        schema: try AdaScriptNetworkBridge.descriptor(for: command),
                        fieldNames: fields,
                        orderedTags: command.fields.compactMap(\.network?.tag)
                    )
                }
            } catch {
                runtime.appendDiagnostic(String(describing: error))
                return
            }
        }
        for plan in plans {
            do {
                let prepared = try Self.prepare(plan, pluginIdentifier: name, world: app.main)
                app.main.schedulers.addSystem(
                    AnnotatedGravityScriptSystem(
                        pluginIdentifier: name,
                        runtime: runtime,
                        preparedSystem: prepared
                    ),
                    for: prepared.scheduler
                )
            } catch {
                runtime.appendDiagnostic(String(describing: error))
            }
        }
    }

    private static func prepare(
        _ plan: AnnotatedSystemPlan,
        pluginIdentifier: String,
        world: World
    ) throws -> PreparedAnnotatedSystem {
        let queries = try plan.queries.enumerated()
            .map { queryIndex, query in
                try prepareQuery(query, systemIdentifier: plan.identifier, queryIndex: queryIndex, world: world)
            }
        let resources = try plan.resources.map { resource in
            try prepareResource(resource, systemIdentifier: plan.identifier)
        }
        let remoteCommands = plan.remoteCommands.map {
            PreparedAnnotatedRemoteCommands(
                commandName: $0.commandName,
                parameter: Res<AdaScriptNetworkRuntime>(),
                propertyName: $0.propertyName
            )
        }
        let rpcMethods = plan.rpcMethods.map {
            PreparedAnnotatedRPCMethod(commandName: $0.commandName, fieldNames: $0.fieldNames, parameter: Res<AdaScriptNetworkRuntime>())
        }
        return PreparedAnnotatedSystem(
            className: plan.className,
            commands: plan.usesDeferredCommands ? Commands(entities: world.entities, commandsQueue: world.commandQueue) : nil,
            dependencies: plan.dependencies.map { dependency in
                switch dependency {
                case let .before(identifier):
                    .before(AnnotatedGravityScriptSystem.makeIdentifier(plugin: pluginIdentifier, system: identifier))
                case let .after(identifier):
                    .after(AnnotatedGravityScriptSystem.makeIdentifier(plugin: pluginIdentifier, system: identifier))
                }
            },
            identifier: plan.identifier,
            scheduler: plan.scheduler,
            queries: queries,
            remoteCommands: remoteCommands,
            rpcMethods: rpcMethods,
            resources: resources
        )
    }

    private static func prepareResource(
        _ plan: AnnotatedResourcePlan,
        systemIdentifier: String
    ) throws -> PreparedAnnotatedResource {
        if plan.resourceName == "Input" {
            return .input(propertyName: plan.propertyName, parameter: Res<Input?>(), optional: plan.isOptional)
        }
        if plan.resourceName == "Multiplayer" {
            return .multiplayer(
                parameter: ResMut<AdaScriptNetworkRuntime>(),
                propertyName: plan.propertyName
            )
        }
        guard let resourceType = RuntimeTypeRegistry.resourceType(named: plan.resourceName) else {
            throw AdaScriptError.unknownResource(system: systemIdentifier, resource: plan.resourceName)
        }
        let descriptor = RuntimeResourceReflectionRegistry.descriptor(for: resourceType)
        return .reflected(
            fields: Dictionary(uniqueKeysWithValues: descriptor?.fields.map { ($0.key, $0) } ?? []),
            parameter: DynamicResource(resourceType: resourceType, isOptional: plan.isOptional, writable: true),
            propertyName: plan.propertyName,
            resourceName: plan.resourceName
        )
    }

    private static func prepareQuery(
        _ plan: AnnotatedQueryPlan,
        systemIdentifier: String,
        queryIndex: Int,
        world: World
    ) throws -> PreparedAnnotatedQuery {
        var resolved: [String: ResolvedAnnotatedComponent] = [:]
        let allNames = plan.components + plan.withComponents + plan.withoutComponents
        for name in allNames where resolved[name] == nil {
            guard let component = resolveComponent(named: name, world: world) else {
                throw AdaScriptError.unknownComponent(
                    system: systemIdentifier,
                    queryIndex: queryIndex,
                    component: name
                )
            }
            resolved[name] = component
        }

        var predicate = QueryPredicate.all
        for name in plan.components + plan.withComponents {
            if let component = resolved[name] {
                predicate = predicate && .has(component.identifier)
            }
        }
        for name in plan.withoutComponents {
            if let component = resolved[name] {
                predicate = predicate && .without(component.identifier)
            }
        }

        var access = SystemAccessSet()
        let componentAccesses = plan.components.enumerated()
            .compactMap { index, name -> AnnotatedComponentAccess? in
                guard let component = resolved[name] else {
                    return nil
                }
                // The first vertical slice conservatively grants write access to
                // fetched components. Static access inference will narrow this set.
                access.addComponentWrite(component.identifier)
                return AnnotatedComponentAccess(
                    alias: defaultAlias(for: name),
                    componentIndex: index,
                    fields: Dictionary(uniqueKeysWithValues: component.fields.map { ($0.key, $0) })
                )
            }

        let componentIDs = plan.components.compactMap { resolved[$0]?.identifier }
        return PreparedAnnotatedQuery(
            propertyName: plan.propertyName,
            query: DynamicQuery(where: predicate, components: componentIDs, access: access),
            componentAccesses: componentAccesses
        )
    }

    private static func resolveComponent(named name: String, world: World) -> ResolvedAnnotatedComponent? {
        if let exact = RuntimeTypeRegistry.componentType(named: name) {
            return resolvedNativeComponent(exact)
        }
        let matches = RuntimeTypeRegistry.registeredComponentTypes()
            .filter { registeredName, _ in
                registeredName == name || registeredName.hasSuffix(".\(name)")
            }
        if matches.count == 1, let component = matches.first?.value {
            return resolvedNativeComponent(component)
        }
        guard let descriptor = world.runtimeComponentDescriptor(named: name) else { return nil }
        return ResolvedAnnotatedComponent(identifier: descriptor.componentID, fields: descriptor.fields)
    }

    private static func resolvedNativeComponent(_ component: any Component.Type) -> ResolvedAnnotatedComponent {
        let typeName = String(reflecting: component)
        return ResolvedAnnotatedComponent(
            identifier: component.identifier,
            fields: ComponentReflectionRegistry.descriptor(named: typeName)?.fields ?? []
        )
    }

    private static func defaultAlias(for componentName: String) -> String {
        let shortName = componentName.split(separator: ".").last.map(String.init) ?? componentName
        guard let first = shortName.first else {
            return shortName
        }
        return first.lowercased() + shortName.dropFirst()
    }
}

private struct ResolvedAnnotatedComponent {
    let identifier: ComponentId
    let fields: [ReflectedComponentField]
}

struct AnnotatedSystemPlan: Sendable {
    let className: String
    let dependencies: [SystemDependency]
    let identifier: String
    let scheduler: SchedulerName
    let queries: [AnnotatedQueryPlan]
    let remoteCommands: [AnnotatedRemoteCommandPlan]
    let rpcMethods: [AnnotatedRPCMethodPlan]
    let resources: [AnnotatedResourcePlan]
    let usesDeferredCommands: Bool
}

struct AnnotatedRemoteCommandPlan: Sendable {
    let commandName: String
    let propertyName: String
}

struct AnnotatedRPCMethodPlan: Sendable {
    let commandName: String
    let fieldNames: [String]
}

struct AnnotatedResourcePlan: Sendable {
    let isOptional: Bool
    let propertyName: String
    let resourceName: String
}

struct AnnotatedQueryPlan: Sendable {
    let propertyName: String
    let components: [String]
    let withComponents: [String]
    let withoutComponents: [String]
}

private struct PreparedAnnotatedSystem: Sendable {
    let className: String
    let commands: Commands?
    let dependencies: [SystemDependency]
    let identifier: String
    let scheduler: SchedulerName
    let queries: [PreparedAnnotatedQuery]
    let remoteCommands: [PreparedAnnotatedRemoteCommands]
    let rpcMethods: [PreparedAnnotatedRPCMethod]
    let resources: [PreparedAnnotatedResource]
}

private struct PreparedAnnotatedRemoteCommands: Sendable {
    let commandName: String
    let parameter: Res<AdaScriptNetworkRuntime>
    let propertyName: String
}

private struct PreparedAnnotatedRPCMethod: Sendable {
    let commandName: String
    let fieldNames: [String]
    let parameter: Res<AdaScriptNetworkRuntime>
}

private enum PreparedAnnotatedResource: Sendable {
    case reflected(
        fields: [String: ReflectedComponentField],
        parameter: DynamicResource,
        propertyName: String,
        resourceName: String
    )
    case input(propertyName: String, parameter: Res<Input?>, optional: Bool)
    case multiplayer(parameter: ResMut<AdaScriptNetworkRuntime>, propertyName: String)

    var parameter: any SystemParameter {
        switch self {
        case let .reflected(_, parameter, _, _): parameter
        case let .input(_, parameter, _): parameter
        case let .multiplayer(parameter, _): parameter
        }
    }

    var propertyName: String {
        switch self {
        case let .reflected(_, _, name, _),
            let .input(name, _, _),
            let .multiplayer(_, name):
            name
        }
    }
}

private enum AnnotatedResourceBridge {
    case reflected(AnnotatedGravityResourceView)
    case input(AdaScriptInputBridge)
    case multiplayer(AdaScriptMultiplayerAPI)

    var object: AnyObject {
        switch self {
        case let .reflected(bridge): bridge
        case let .input(bridge): bridge
        case let .multiplayer(bridge): bridge
        }
    }

    func invalidate() {
        if case let .input(bridge) = self {
            bridge.invalidate()
        } else if case let .multiplayer(bridge) = self {
            bridge.invalidate()
        }
    }
}

private struct PreparedAnnotatedQuery: Sendable {
    let propertyName: String
    let query: DynamicQuery
    let componentAccesses: [AnnotatedComponentAccess]
}

struct AnnotatedComponentAccess: Sendable {
    let alias: String
    let componentIndex: Int
    let fields: [String: ReflectedComponentField]
}

private struct AnnotatedGravityScriptSystem: System {
    private let deltaTime = Res<DeltaTime?>()
    private let pluginIdentifier: String
    private let preparedSystem: PreparedAnnotatedSystem?
    private let runtime: AnnotatedGravityRuntime?

    var systemIdentifier: String {
        guard let preparedSystem else {
            return "AdaScripting.System.Unconfigured"
        }
        return Self.makeIdentifier(plugin: pluginIdentifier, system: preparedSystem.identifier)
    }

    var systemDependencies: [SystemDependency] {
        preparedSystem?.dependencies ?? []
    }

    var queries: SystemQueries {
        var parameters: [any SystemParameter] = preparedSystem?.queries.map { $0.query as any SystemParameter } ?? []
        parameters += preparedSystem?.resources.map { $0.parameter as any SystemParameter } ?? []
        parameters += preparedSystem?.remoteCommands.map { $0.parameter as any SystemParameter } ?? []
        parameters += preparedSystem?.rpcMethods.map { $0.parameter as any SystemParameter } ?? []
        if let commands = preparedSystem?.commands {
            parameters.append(commands)
        }
        parameters.append(deltaTime)
        return SystemQueries(queries: parameters)
    }

    init(world _: World) {
        self.pluginIdentifier = "Unconfigured"
        self.preparedSystem = nil
        self.runtime = nil
    }

    init(
        pluginIdentifier: String,
        runtime: AnnotatedGravityRuntime,
        preparedSystem: PreparedAnnotatedSystem
    ) {
        self.pluginIdentifier = pluginIdentifier
        self.runtime = runtime
        self.preparedSystem = preparedSystem
    }

    static func makeIdentifier(plugin: String, system: String) -> String {
        "AdaScripting.System.\(plugin.utf8.count):\(plugin)\(system.utf8.count):\(system)"
    }

    func update(context _: UpdateContext) async {
        guard let preparedSystem, let runtime else {
            return
        }
        let queries = preparedSystem.queries.map { query in
            runtime.makeQueryBridge(
                cursor: query.query.wrappedValue.makeCursor(),
                componentAccesses: query.componentAccesses,
            )
        }
        let resources = preparedSystem.resources.map { resource in
            (
                propertyName: resource.propertyName,
                resource: runtime.makeResourceBridge(resource)
            )
        }
        let remoteCommands = preparedSystem.remoteCommands.map { commands in
            (
                propertyName: commands.propertyName,
                value: runtime.makeRemoteCommands(
                    named: commands.commandName,
                    runtime: commands.parameter.wrappedValue
                )
            )
        }
        let rpcCalls = preparedSystem.rpcMethods.map { method in
            (
                commandName: method.commandName,
                fieldNames: method.fieldNames,
                payloads: method.parameter.wrappedValue.commands(named: method.commandName)
            )
        }
        let world = runtime.makeWorldBridge(commands: preparedSystem.commands)
        runtime.update(
            className: preparedSystem.className,
            systemIdentifier: preparedSystem.identifier,
            deltaTime: Double(deltaTime.wrappedValue?.deltaTime ?? 0),
            queries: zip(preparedSystem.queries, queries).map { ($0.propertyName, $1) },
            remoteCommands: remoteCommands,
            rpcCalls: rpcCalls,
            resources: resources,
            world: world
        )
    }
}

private final class AnnotatedGravityRuntime: @unchecked Sendable {
    let annotations: [GravityAnnotation]

    // The runtime owns its delegate for exactly the VM lifetime; this is not a callback back-reference.
    // swiftlint:disable:next weak_delegate
    private let delegate: AnnotatedGravityRuntimeDelegate
    private let runtimeComponents: [RuntimeComponentDescriptor]
    private let virtualMachine: GravityVirtualMachine
    private var instances: [String: GSValue] = [:]

    init(
        module: ResolvedGravityScriptModule,
        componentConstructors: [AdaScriptLinkedComponentConstructor],
        runtimeComponents: [RuntimeComponentDescriptor],
        networkCommands: [AdaScriptNetworkCommandSchema]
    ) throws {
        let delegate = AnnotatedGravityRuntimeDelegate(module: module)
        self.delegate = delegate
        self.runtimeComponents = runtimeComponents

        AdaScriptRuntimeCoordinator.lock.lock()
        defer { AdaScriptRuntimeCoordinator.lock.unlock() }

        let virtualMachine = GravityVirtualMachine(settings: .init(), delegate: delegate)
        self.virtualMachine = virtualMachine
        try virtualMachine.bindClass(with: AnnotatedGravitySystemContext.self)
        try virtualMachine.bindClass(with: AdaScriptInputBridge.self)
        try virtualMachine.bindClass(with: AnnotatedGravityWorldContext.self)
        try virtualMachine.bindClass(with: AnnotatedGravityCommandsBridge.self)
        try virtualMachine.bindClass(with: AnnotatedGravityQueryBridge.self)
        try virtualMachine.bindClass(with: AnnotatedGravityQueryRow.self)
        try virtualMachine.bindClass(with: AnnotatedGravityComponentView.self)
        try virtualMachine.bindClass(with: AnnotatedGravityResourceView.self)
        try virtualMachine.bindClass(with: AdaScriptMultiplayerAPI.self)
        try virtualMachine.bindClass(with: AdaScriptNetworkCommandFactory.self)
        try virtualMachine.bindClass(with: AdaScriptNetworkCommandValue.self)
        try virtualMachine.bindClass(with: AdaScriptNetworkValueBridge.self)
        try virtualMachine.bindClass(with: AdaScriptRemoteCommandBridge.self)
        try virtualMachine.bindClass(with: AdaScriptViewBridge.self)
        try AdaScriptComponentRuntime.bind(
            to: virtualMachine,
            constructors: componentConstructors,
            runtimeDescriptors: runtimeComponents,
            reportDiagnostic: delegate.append
        )
        try AdaScriptAssetRuntime.bind(to: virtualMachine, reportDiagnostic: delegate.append)
        virtualMachine.setValue(
            AdaScriptNetworkCommandFactory.make(
                schemas: networkCommands,
                reportDiagnostic: delegate.append
            ),
            forKey: "__adaNetworkFactory"
        )
        virtualMachine.setValue(AdaScriptViewBridge(), forKey: "adaUIBuilder")

        let binary = virtualMachine.loadGravityFile(
            from: AdaScriptComponentRuntime.prelude(constructors: componentConstructors)
                + AdaScriptNetworkBridge.prelude(commands: networkCommands)
                + module.entrySource
        )
        guard delegate.errors.isEmpty else {
            throw AdaScriptError.compilation(delegate.errors)
        }
        self.annotations = binary.annotations
        virtualMachine.load(binary)
        guard delegate.errors.isEmpty else {
            throw AdaScriptError.compilation(delegate.errors)
        }
        if virtualMachine.getValue(forKey: "main").isClosure {
            throw AdaScriptError.invalidManifest("Ada Script modules must not declare main()")
        }
    }

    func instantiateSystems(_ plans: [AnnotatedSystemPlan]) throws {
        AdaScriptRuntimeCoordinator.lock.lock()
        defer { AdaScriptRuntimeCoordinator.lock.unlock() }
        for plan in plans {
            let systemClass = virtualMachine.getValue(forKey: plan.className)
            guard systemClass.isClass, let instance = systemClass.callAsFunction(), instance.isInstance else {
                throw AdaScriptError.invalidManifest("Unable to instantiate @system class '\(plan.className)'")
            }
            guard instance.hasMethod(named: "update") else {
                throw AdaScriptError.invalidManifest("@system class '\(plan.className)' must define update(context)")
            }
            // The VM's collector cannot see Swift's GSValue dictionary. Publish a
            // private VM global so the system instance remains a live GC root for
            // the complete plugin lifetime, matching scriptable-object instances.
            virtualMachine.setValue(
                instance,
                forKey: "__ada_live_system_" + plan.identifier
            )
            instances[plan.className] = instance
        }
    }

    func update(
        className: String,
        systemIdentifier: String,
        deltaTime: Double,
        queries: [(propertyName: String, query: AnnotatedGravityQueryBridge)],
        remoteCommands: [(propertyName: String, value: GSValue)],
        rpcCalls: [(commandName: String, fieldNames: [String], payloads: [AdaScriptRemoteCommandPayload])],
        resources: [(propertyName: String, resource: AnnotatedResourceBridge)],
        world: AnnotatedGravityWorldContext
    ) {
        AdaScriptRuntimeCoordinator.lock.lock()
        defer { AdaScriptRuntimeCoordinator.lock.unlock() }
        defer {
            world.invalidate()
            for (_, resource) in resources { resource.invalidate() }
        }

        guard let instance = instances[className] else {
            return
        }

        for (propertyName, query) in queries {
            let queryValue = GSValue(object: query, in: virtualMachine)
            guard instance.setStoredProperty(named: propertyName, to: queryValue) else {
                delegate.append("Unable to bind @query property '\(propertyName)' in system '\(systemIdentifier)'")
                return
            }
        }
        for (propertyName, resource) in resources {
            let resourceValue = GSValue(object: resource.object, in: virtualMachine)
            guard instance.setStoredProperty(named: propertyName, to: resourceValue) else {
                delegate.append("Unable to bind @res property '\(propertyName)' in system '\(systemIdentifier)'")
                return
            }
        }
        for (propertyName, value) in remoteCommands {
            guard instance.setStoredProperty(named: propertyName, to: value) else {
                delegate.append("Unable to bind @remote_commands property '\(propertyName)' in system '\(systemIdentifier)'")
                return
            }
        }
        let context = AnnotatedGravitySystemContext.make(deltaTime: deltaTime, world: world)
        for rpc in rpcCalls {
            for payload in rpc.payloads {
                let arguments: [GSValue] = [GSValue(string: payload.source, in: virtualMachine)] + rpc.fieldNames.compactMap { name in
                    payload.values[name].map { AnnotatedGravityValueBridge.makeGravityValue($0, virtualMachine: virtualMachine) }
                }
                guard arguments.count == rpc.fieldNames.count + 1 else {
                    delegate.append("Missing @rpc field in '\(rpc.commandName)' for system '\(systemIdentifier)'")
                    continue
                }
                _ = instance.callMethod(named: "__ada_rpc_handler_\(rpc.commandName)", with: arguments)
            }
        }
        _ = instance.callMethod(named: "update", with: [context])
    }

    func makeQueryBridge(
        cursor: DynamicQueryCursor,
        componentAccesses: [AnnotatedComponentAccess]
    ) -> AnnotatedGravityQueryBridge {
        AnnotatedGravityQueryBridge.make(
            cursor: cursor,
            componentAccesses: componentAccesses,
            reportDiagnostic: appendDiagnostic,
            virtualMachine: virtualMachine
        )
    }

    func makeResourceBridge(_ resource: PreparedAnnotatedResource) -> AnnotatedResourceBridge {
        switch resource {
        case let .input(_, parameter, optional):
            let input = parameter.wrappedValue
            if input == nil && !optional {
                appendDiagnostic("Required resource 'Input' is not available")
            }
            return .input(AdaScriptInputBridge.make(input))
        case let .reflected(fields, parameter, _, resourceName):
            if !parameter.isAvailable && !parameter.isOptional {
                appendDiagnostic("Required resource '\(resourceName)' is not available")
            }
            return .reflected(
                AnnotatedGravityResourceView.make(
                    parameter: parameter,
                    fields: fields,
                    reportDiagnostic: appendDiagnostic,
                    virtualMachine: virtualMachine
                )
            )
        case let .multiplayer(parameter, _):
            return .multiplayer(
                AdaScriptMultiplayerAPI.make(
                    runtime: parameter.projectedValue,
                    reportDiagnostic: appendDiagnostic
                )
            )
        }
    }

    func makeRemoteCommands(
        named name: String,
        runtime: AdaScriptNetworkRuntime
    ) -> GSValue {
        let values = runtime.commands(named: name).map {
            GSValue(
                object: AdaScriptRemoteCommandBridge(payload: $0, virtualMachine: virtualMachine),
                in: virtualMachine
            ) as Any
        }
        return GSValue(newArrayIn: virtualMachine, items: values)
    }

    func makeWorldBridge(commands: Commands?) -> AnnotatedGravityWorldContext {
        AnnotatedGravityWorldContext.make(
            commands: AnnotatedGravityCommandsBridge.make(
                commands: commands,
                runtimeComponents: runtimeComponents,
                reportDiagnostic: appendDiagnostic
            )
        )
    }

    var diagnostics: [String] {
        AdaScriptRuntimeCoordinator.lock.withLock { delegate.errors }
    }

    func appendDiagnostic(_ message: String) {
        AdaScriptRuntimeCoordinator.lock.withLock { delegate.append(message) }
    }
}
