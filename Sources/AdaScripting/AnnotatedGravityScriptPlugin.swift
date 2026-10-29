@_spi(Internal) import AdaApp
@_spi(Scripting) import AdaECS
import AdaInput
import AdaMultiplayer
import AdaScene
import AdaScriptCompilerCore
import AdaTransform
import Foundation
import Gravity

/// Builds a world-local Swift implementation for an authored `@system` identifier.
/// The plugin retains the authored scheduler, ordering and access declarations.
public typealias AdaScriptNativeSystemFactory = @Sendable (World) throws -> any System

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
        AdaScriptRuntimeCoordinator.lock.withLock { runtime.diagnostics }
    }

    /// Number of suspended or ready AdaScript tasks owned by this module.
    public var activeAsyncTaskCount: Int {
        AdaScriptRuntimeCoordinator.lock.withLock { runtime.activeAsyncTaskCount }
    }

    /// Runtime component schemas used when loading exported scene data.
    @MainActor public var componentDescriptors: [RuntimeComponentDescriptor] { runtimeComponents }

    /// The `@test` functions loaded with `includeTests: true`; empty otherwise.
    public let tests: [AdaScriptTestCase]

    private(set) var plans: [AnnotatedSystemPlan]
    private var dataSchemas: [AdaScriptDataSchema]
    private var networkCommands: [AdaScriptNetworkCommandSchema]
    private var runtimeComponents: [RuntimeComponentDescriptor]
    /// Script `@resource` structs. Nothing in a script-hosted game can insert them later, so every one is
    /// present from setup regardless of `autoInsert`.
    private var runtimeResources: [RuntimeResourceLayout] {
        AdaScriptComponentRuntime.runtimeResourceLayouts(schemas: dataSchemas)
    }
    private var runtime: AnnotatedGravityRuntime
    private let nativeSystemFactories: [String: AdaScriptNativeSystemFactory]

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
        startupSystemIdentifier: String? = nil,
        communityPolicy: AdaScriptCommunityPolicy? = nil,
        includeTests: Bool = false,
        testTimeout: Duration? = nil,
        nativeSystemFactories: [String: AdaScriptNativeSystemFactory] = [:]
    ) throws {
        if communityPolicy != nil {
            for source in sources { try AdaScriptCommunityLowerer.validate(source: source.source) }
        }
        let componentConstructors = AdaScriptComponentRuntime.linkedConstructors()
        let dataSchemas = try AdaScriptSchemaParser.parse(sources: sources)
        let runtimeComponents = AdaScriptComponentRuntime.runtimeDescriptors(schemas: dataSchemas)
        let networkCommands = try AdaScriptSchemaParser.parseNetworkCommands(sources: sources)
        let module = try GravityScriptModuleResolver.resolve(sources, includeTests: includeTests)
        let runtime: AnnotatedGravityRuntime
        do {
            runtime = try AnnotatedGravityRuntime(
                module: module,
                componentConstructors: componentConstructors,
                runtimeComponents: runtimeComponents,
                networkCommands: networkCommands,
                communityPolicy: communityPolicy,
                testTimeout: includeTests ? testTimeout : nil
            )
        } catch AdaScriptError.compilation(let diagnostics) where !module.importDiagnostics.isEmpty {
            // The compiler's own errors come first; import findings explain a missing name they report.
            throw AdaScriptError.compilation(diagnostics + module.importDiagnostics)
        }
        let resourceBindings = try AdaScriptSchemaParser.parseResourceBindings(sources: sources)
        let remoteCommandBindings = try AdaScriptSchemaParser.parseRemoteCommandBindings(sources: sources)
        let rpcMethodBindings = try AdaScriptSchemaParser.parseRPCMethodBindings(sources: sources)
        let networkCommandNames = Set(networkCommands.map(\.name))
        if let unknownBinding = remoteCommandBindings.first(where: { !networkCommandNames.contains($0.commandName) }) {
            throw AdaScriptError.invalidManifest(
                "@remote_commands references unknown command '\(unknownBinding.commandName)'"
            )
        }
        if !module.importDiagnostics.isEmpty {
            throw AdaScriptError.compilation(module.importDiagnostics)
        }
        let capabilities = try AdaScriptSchemaParser.parseSystemCapabilities(sources: sources)
        var plans = try AdaScriptSystemPlanBuilder.makePlans(
            from: runtime.annotations,
            pathsByFileID: module.pathsByFileID,
            remoteCommandBindings: remoteCommandBindings,
            rpcMethodBindings: rpcMethodBindings,
            resourceBindings: resourceBindings,
            systemCapabilities: capabilities
        )
        for plan in plans {
            try module.requireSynchronousCallback(className: plan.className, method: "update", annotation: "@system")
        }
        if let unknown = nativeSystemFactories.keys.sorted().first(where: { identifier in !plans.contains { $0.identifier == identifier } }) {
            throw AdaScriptError.invalidManifest("Native system '\(unknown)' does not match an @system id.")
        }
        for binding in rpcMethodBindings {
            try module.requireSynchronousCallback(className: binding.systemName, method: binding.commandName, annotation: "@rpc")
        }
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
        self.tests = module.tests
        self.dataSchemas = dataSchemas
        self.networkCommands = networkCommands
        self.runtimeComponents = runtimeComponents
        self.runtime = runtime
        self.plans = plans
        self.nativeSystemFactories = nativeSystemFactories
        try runtime.instantiateSystems(plans)
        runtime.testWorldFactory?.build = { [unowned self, runtime] in
            let world = World(name: "Ada Script test")
            self.registerComponentsForTesting(in: world)
            let startupSystems = Set(self.plans.filter { $0.scheduler == .startup }.map(\.className))
            return runtime.makeTestWorld(world: world, startupSystems: startupSystems) { [unowned self] className, installed in
                self.installSystemsForTesting(into: world, className: className, alreadyInstalled: installed)
            }
        }
    }

    /// Runs the loaded `@test` functions, optionally only those whose name or display name contains `filter`.
    ///
    /// `onResult` is called after each test, so a caller can stream progress.
    /// When supplied, `exactName` selects a single function name instead of substring matching.
    public func runTests(matching filter: String? = nil, exactName: String? = nil, onResult: ((AdaScriptTestResult) -> Void)? = nil) -> [AdaScriptTestResult] {
        let selected = tests.filter { test in
            if let exactName { return test.name == exactName }
            guard let filter, !filter.isEmpty else {
                return true
            }
            return test.name.contains(filter) || test.displayName.contains(filter)
        }
        let clock = ContinuousClock()
        return selected.map { test in
            let start = clock.now
            let execution = AdaScriptRuntimeCoordinator.lock.withLock { runtime }.runTest(named: test.name)
            let result = AdaScriptTestResult(test: test, execution: execution, duration: start.duration(to: clock.now))
            onResult?(result)
            return result
        }
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

    /// Replaces the module's systems in a running world after the current frame finishes.
    /// A failed candidate leaves the previous VM and scheduler registrations active.
    @MainActor
    public func reload(
        sources: [AdaScriptSource],
        in app: AppWorlds,
        startupSystemIdentifier: String? = nil,
        scriptableObjects: AdaScriptObjectReloadCandidate? = nil
    ) async throws {
        let candidate = try AdaScriptPlugin(
            sources: sources,
            name: name,
            startupSystemIdentifier: startupSystemIdentifier,
            nativeSystemFactories: nativeSystemFactories
        )
        guard candidate.dataSchemas == dataSchemas, candidate.networkCommands == networkCommands else {
            throw AdaScriptError.invalidManifest("AdaScript component, resource, and network schemas require a game restart.")
        }
        try await app.withExclusiveWorldAccess {
            let prepared = try candidate.plans.map { plan in
                try (plan, Self.prepare(plan, pluginIdentifier: name, world: app.main), candidate.nativeSystemFactories[plan.identifier]?(app.main))
            }
            try app.withExecutionContext { try scriptableObjects?.activate(in: app.main) }
            for scheduler in Set(plans.map(\.scheduler)) {
                app.main.schedulers.removeSystem(AnnotatedGravityScriptSystem.self, for: scheduler)
            }
            app.main.schedulers.removeSystem(AdaScriptTaskPumpSystem.self, for: .update)
            let worldID = "world:\(ObjectIdentifier(app.main).hashValue)"
            runtime.cancelTasks(forWorld: worldID)
            app.main.schedulers.addSystem(AdaScriptTaskPumpSystem(pluginIdentifier: name, runtime: candidate.runtime), for: .update)
            for (plan, preparedSystem, nativeSystem) in prepared {
                app.main.schedulers.addSystem(
                    AnnotatedGravityScriptSystem(
                        pluginIdentifier: name,
                        runtime: candidate.runtime,
                        preparedSystem: preparedSystem,
                        nativeSystem: nativeSystem
                    ),
                    for: plan.scheduler
                )
            }
            plans = candidate.plans
            dataSchemas = candidate.dataSchemas
            networkCommands = candidate.networkCommands
            runtimeComponents = candidate.runtimeComponents
            AdaScriptRuntimeCoordinator.lock.withLock {
                runtime = candidate.runtime
            }
            let startupSystems = prepared.filter { $0.0.scheduler == .startup }
            if !startupSystems.isEmpty {
                let reloadScheduler = SchedulerName(rawValue: "AdaScripting.ReloadStartup.\(name)")
                for (_, preparedSystem, nativeSystem) in startupSystems {
                    app.main.schedulers.addSystem(
                        AnnotatedGravityScriptSystem(
                            pluginIdentifier: name,
                            runtime: runtime,
                            preparedSystem: preparedSystem,
                            nativeSystem: nativeSystem
                        ),
                        for: reloadScheduler
                    )
                }
                await app.main.runScheduler(reloadScheduler)
                app.main.schedulers.removeSystem(AnnotatedGravityScriptSystem.self, for: reloadScheduler)
            }
        }
    }

    @MainActor
    public func setup(in app: borrowing AppWorlds) {
        for descriptor in runtimeComponents {
            app.main.registerRuntimeComponent(descriptor)
        }
        app.main.registerRuntimeResources(runtimeResources)
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
        app.main.schedulers.addSystem(AdaScriptTaskPumpSystem(pluginIdentifier: name, runtime: runtime), for: .update)
        for plan in plans {
            do {
                let prepared = try Self.prepare(plan, pluginIdentifier: name, world: app.main)
                app.main.schedulers.addSystem(
                    AnnotatedGravityScriptSystem(
                        pluginIdentifier: name,
                        runtime: runtime,
                        preparedSystem: prepared,
                        nativeSystem: try nativeSystemFactories[plan.identifier]?(app.main)
                    ),
                    for: prepared.scheduler
                )
            } catch {
                runtime.appendDiagnostic(String(describing: error))
            }
        }
        let worldID = "world:\(ObjectIdentifier(app.main).hashValue)"
        app.main.getResource(SceneNavigator.self)?.onSceneWillReplace { [weak self] in
            guard let self else {
                return
            }
            self.runtime.resetForSceneChange(plans: self.plans, worldID: worldID)
        }
    }

    /// Decodes authored AdaScript component fields without exposing the module's mutable runtime.
    @MainActor
    public func decodeSceneComponent(named name: String, data: Data) throws -> (any Component)? {
        guard let descriptor = runtimeComponents.first(where: { $0.name == name || $0.stableID == name || $0.aliases.contains(name) }) else { return nil }
        guard let fields = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AdaScriptError.invalidManifest("Scene component must be an object: \(name)")
        }
        return try AdaScriptSceneComponentDecoder.decode(fields, as: descriptor)
    }
    /// Installs authored data in an editor world without starting gameplay systems.
    @MainActor
    public func registerSceneComponents(in world: World) {
        for descriptor in runtimeComponents { world.registerRuntimeComponent(descriptor) }
        world.registerRuntimeResources(runtimeResources)
    }

    /// Registers the module's runtime components in a bare world for a `TestWorld`, so a test can spawn them
    /// before any system is installed.
    ///
    /// `setup(in:)` is main-actor isolated because it also wires multiplayer and scene navigation, which a test
    /// world does not have. A test runs on whichever thread the runner was called from, so these take the plain world.
    func registerComponentsForTesting(in world: World) {
        for descriptor in runtimeComponents {
            world.registerRuntimeComponent(descriptor)
        }
        world.registerRuntimeResources(runtimeResources)
    }

    /// Installs systems into a `TestWorld`: the one named by `className`, or every system when it is nil.
    /// Returns the class names installed by this call; systems in `alreadyInstalled` are skipped.
    func installSystemsForTesting(into world: World, className: String?, alreadyInstalled: Set<String>) -> Set<String> {
        let selected = plans.filter { plan in
            (className == nil || plan.className == className) && !alreadyInstalled.contains(plan.className)
        }
        if let className, !plans.contains(where: { $0.className == className }) {
            runtime.appendDiagnostic("TestWorld cannot run unknown system '\(className)'")
        }
        if alreadyInstalled.isEmpty {
            world.schedulers.addSystem(AdaScriptTaskPumpSystem(pluginIdentifier: name, runtime: runtime), for: .update)
        }
        var installed = Set<String>()
        for plan in selected {
            do {
                let prepared = try Self.prepare(plan, pluginIdentifier: name, world: world)
                world.schedulers.addSystem(
                    AnnotatedGravityScriptSystem(
                        pluginIdentifier: name, runtime: runtime, preparedSystem: prepared,
                        nativeSystem: try nativeSystemFactories[plan.identifier]?(world)
                    ),
                    for: prepared.scheduler
                )
                installed.insert(plan.className)
            } catch {
                runtime.appendDiagnostic(String(describing: error))
            }
        }
        return installed
    }

    @MainActor
    public func destroy(for app: borrowing AppWorlds) {
        runtime.cancelTasks(forWorld: "world:\(ObjectIdentifier(app.main).hashValue)")
    }

    private static func prepare(
        _ plan: AnnotatedSystemPlan,
        pluginIdentifier: String,
        world: World
    ) throws -> PreparedAnnotatedSystem {
        let dynamicComponents = try prepareDynamicAccess(plan.access, systemIdentifier: plan.identifier, world: world)
        var declaredLevels: [ComponentId: QueryAccessLevel] = [:]
        for component in dynamicComponents.values {
            declaredLevels[component.identifier] = max(declaredLevels[component.identifier] ?? .read, component.isWritable ? .write : .read)
        }
        let queries = try plan.queries.enumerated()
            .map { queryIndex, query in
                try prepareQuery(
                    query,
                    systemIdentifier: plan.identifier,
                    queryIndex: queryIndex,
                    world: world,
                    declaredAccess: declaredLevels
                )
            }
        let resources = try plan.resources.map { resource in
            try prepareResource(resource, systemIdentifier: plan.identifier, world: world)
        }
        if !(plan.eventReaders + plan.eventWriters).isEmpty, !world.supportsEventDelivery {
            throw AdaScriptError.invalidManifest("System '\(plan.identifier)' uses @events or @eventWriter, which requires EventsPlugin")
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
            resources: resources,
            eventReader: plan.eventReaders.isEmpty ? nil : Events<AdaScriptRuntimeEvent>(),
            eventReaders: plan.eventReaders,
            eventSender: plan.eventWriters.isEmpty ? nil : EventsSender<AdaScriptRuntimeEvent>(),
            eventWriters: plan.eventWriters,
            declaredAccess: dynamicComponents.isEmpty ? nil : AnnotatedDeclaredAccess(
                reads: Set(dynamicComponents.values.map(\.identifier)),
                writes: Set(dynamicComponents.values.filter(\.isWritable).map(\.identifier))
            ),
            dynamicComponents: dynamicComponents,
            isExclusiveWorld: plan.isExclusiveWorld
        )
    }

    /// Shared by native AOT validation/setup so explicit access declarations
    /// retain the same meaning as the VM's borrowed component capabilities.
    static func declaredQueryAccess(for plan: AnnotatedSystemPlan, world: World) throws -> [ComponentId: QueryAccessLevel] {
        let components = try prepareDynamicAccess(plan.access, systemIdentifier: plan.identifier, world: world)
        return components.values.reduce(into: [:]) { result, component in
            result[component.identifier] = max(result[component.identifier] ?? .read, component.isWritable ? .write : .read)
        }
    }

    private static func prepareDynamicAccess(
        _ plan: AnnotatedAccessPlan?,
        systemIdentifier: String,
        world: World
    ) throws -> [String: PreparedDynamicComponent] {
        guard let plan else {
            return [:]
        }
        var result: [String: PreparedDynamicComponent] = [:]
        for name in plan.read + plan.write where result[name] == nil {
            guard let component = resolveComponent(named: name, world: world) else {
                throw AdaScriptError.unknownComponent(system: systemIdentifier, queryIndex: -1, component: name)
            }
            result[name] = PreparedDynamicComponent(
                identifier: component.identifier,
                fields: Dictionary(uniqueKeysWithValues: component.fields.map { ($0.key, $0) }),
                isWritable: plan.write.contains(name)
            )
        }
        return result
    }

    private static func prepareResource(
        _ plan: AnnotatedResourcePlan,
        systemIdentifier: String,
        world: World
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
            // A script-declared `@resource` has no Swift type; it lives in the shared runtime store.
            if let layout = world.getResource(RuntimeResourceStore.self)?.layout(named: plan.resourceName) {
                return .reflected(
                    fields: Dictionary(uniqueKeysWithValues: layout.fields.map { ($0.key, $0) }),
                    parameter: DynamicResource(resourceType: RuntimeResourceStore.self, isOptional: plan.isOptional, writable: plan.access == .write),
                    propertyName: plan.propertyName,
                    resourceName: plan.resourceName
                )
            }
            throw AdaScriptError.unknownResource(system: systemIdentifier, resource: plan.resourceName)
        }
        let descriptor = RuntimeResourceReflectionRegistry.descriptor(for: resourceType)
        return .reflected(
            fields: Dictionary(uniqueKeysWithValues: descriptor?.fields.map { ($0.key, $0) } ?? []),
            parameter: DynamicResource(resourceType: resourceType, isOptional: plan.isOptional, writable: plan.access == .write),
            propertyName: plan.propertyName,
            resourceName: plan.resourceName
        )
    }

    enum QueryAccessLevel: Int, Comparable {
        case read = 0
        case write = 1

        static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// - Parameter declaredAccess: Levels the system's `@access` declares, by resolved component.
    static func prepareQuery(
        _ plan: AnnotatedQueryPlan,
        systemIdentifier: String,
        queryIndex: Int,
        world: World,
        declaredAccess: [ComponentId: QueryAccessLevel] = [:]
    ) throws -> PreparedAnnotatedQuery {
        func fail(_ message: String) -> AdaScriptError {
            let prefix = plan.source.flatMap { source in source.path.map { "\($0):\(source.line):\(source.column): " } } ?? ""
            return .invalidManifest(prefix + message)
        }
        var resolved: [String: ResolvedAnnotatedComponent] = [:]
        let allNames = plan.components.map(\.name) + plan.withComponents + plan.withoutComponents + plan.changedComponents + plan.addedComponents
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

        // Row properties: the alias, else the lower-camel short name. They must be distinct and not shadow `id`.
        var aliases: [String: String] = [:]
        for component in plan.components {
            let alias = component.alias ?? defaultAlias(for: component.name)
            guard alias != "id" else {
                throw fail("query '\(plan.propertyName)' in system '\(systemIdentifier)' cannot name a component 'id'; row.id is the entity")
            }
            if let existing = aliases[alias] {
                throw fail(
                    "query '\(plan.propertyName)' in system '\(systemIdentifier)' fetches '\(existing)' and '\(component.name)' as '\(alias)'; "
                        + "give one an alias, for example \(component.name) as other\(alias.prefix(1).uppercased())\(alias.dropFirst())"
                )
            }
            aliases[alias] = component.name
        }

        var predicate = QueryPredicate.all
        for component in plan.components where !component.isOptional {
            if let resolvedComponent = resolved[component.name] {
                predicate = predicate && .has(resolvedComponent.identifier)
            }
        }
        for name in plan.withComponents {
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
        var componentAccesses: [AnnotatedComponentAccess] = []
        for (index, component) in plan.components.enumerated() {
            guard let resolvedComponent = resolved[component.name] else { continue }
            let alias = component.alias ?? defaultAlias(for: component.name)
            let level = try accessLevel(
                of: alias,
                componentName: component.name,
                identifier: resolvedComponent.identifier,
                plan: plan,
                systemIdentifier: systemIdentifier,
                declaredAccess: declaredAccess,
                fail: fail
            )
            if level == .write {
                access.addComponentWrite(resolvedComponent.identifier)
            } else {
                access.addComponentRead(resolvedComponent.identifier)
            }
            componentAccesses.append(
                AnnotatedComponentAccess(
                    alias: alias,
                    componentIndex: index,
                    fields: Dictionary(uniqueKeysWithValues: resolvedComponent.fields.map { ($0.key, $0) }),
                    isWritable: level == .write
                )
            )
        }
        // Tick filters read component metadata, so the scheduler must see a read even when the component is not fetched.
        for name in plan.changedComponents + plan.addedComponents {
            if let component = resolved[name] { access.addComponentRead(component.identifier) }
        }

        let componentIDs = plan.components.compactMap { resolved[$0.name]?.identifier }
        let optionalIDs = Set(plan.components.filter(\.isOptional).compactMap { resolved[$0.name]?.identifier })
        return PreparedAnnotatedQuery(
            propertyName: plan.propertyName,
            query: DynamicQuery(
                where: predicate,
                components: componentIDs,
                optionalComponents: optionalIDs,
                changedComponents: plan.changedComponents.compactMap { resolved[$0]?.identifier },
                addedComponents: plan.addedComponents.compactMap { resolved[$0]?.identifier },
                access: access
            ),
            componentAccesses: componentAccesses
        )
    }

    /// Chooses the scheduler access a fetched component needs from how the script uses its row and from
    /// the system's `@access`. Analysed code gets exactly what it touches; code the analysis cannot follow
    /// must declare access, and a declaration may not claim less than the code does.
    private static func accessLevel(
        of alias: String,
        componentName: String,
        identifier: ComponentId,
        plan: AnnotatedQueryPlan,
        systemIdentifier: String,
        declaredAccess: [ComponentId: QueryAccessLevel],
        fail: (String) -> AdaScriptError
    ) throws -> QueryAccessLevel {
        let declared = declaredAccess[identifier]
        guard let usage = plan.usage else {
            // No source to analyse (precompiled module): keep the conservative write access.
            return declared ?? .write
        }
        if usage.isOpaque {
            guard let declared else {
                throw fail(
                    "query '\(plan.propertyName)' in system '\(systemIdentifier)' passes its rows or the query to code the compiler cannot analyse, "
                        + "so access to '\(componentName)' is unknown; declare @access(read: [...], write: [...]) on the system"
                )
            }
            return declared
        }
        let inferred: QueryAccessLevel = usage.writes.contains(alias) ? .write : .read
        if let declared, declared < inferred {
            throw fail(
                "system '\(systemIdentifier)' writes '\(componentName)' through query '\(plan.propertyName)' but @access declares it read-only"
            )
        }
        return max(declared ?? inferred, inferred)
    }

    static func resolveComponent(named name: String, world: World) -> ResolvedAnnotatedComponent? {
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
        guard let descriptor = world.runtimeComponentDescriptor(named: name) else {
            return nil
        }
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

struct ResolvedAnnotatedComponent: Sendable {
    let identifier: ComponentId
    let fields: [ReflectedComponentField]
}

/// Where an annotation was written, in target-relative coordinates.
struct AnnotatedSourceLocation: Sendable, Equatable {
    let column: Int
    let line: Int
    let path: String?
}

struct AnnotatedSystemPlan: Sendable {
    let source: AnnotatedSourceLocation
    let className: String

    /// The declaration's identity across the module: its file and class, e.g. `Systems/Move.ada#MoveSystem`.
    var qualifiedIdentity: String {
        (source.path.map { "\($0)#" } ?? "") + className
    }
    let dependencies: [SystemDependency]
    let identifier: String
    let scheduler: SchedulerName
    let queries: [AnnotatedQueryPlan]
    let remoteCommands: [AnnotatedRemoteCommandPlan]
    let rpcMethods: [AnnotatedRPCMethodPlan]
    let resources: [AnnotatedResourcePlan]
    let usesDeferredCommands: Bool
    let isExclusiveWorld: Bool
    let access: AnnotatedAccessPlan?
    let eventReaders: [AnnotatedEventPlan]
    let eventWriters: [AnnotatedEventPlan]
}

/// Component names an `@access` system may read or write through the dynamic world API.
struct AnnotatedAccessPlan: Sendable, Equatable {
    let read: [String]
    let write: [String]
}

struct AnnotatedEventPlan: Sendable, Equatable {
    let eventName: String
    let propertyName: String
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
    let access: AdaScriptResourceBinding.Access
    let isOptional: Bool
    let propertyName: String
    let resourceName: String
}

/// A component a query fetches, optionally renamed and optionally absent from some rows.
struct AnnotatedQueryComponent: Sendable, Equatable {
    let name: String
    let alias: String?
    let isOptional: Bool
}

struct AnnotatedQueryPlan: Sendable {
    let propertyName: String
    /// Required components first, then optional ones: the slot order scripts address rows by.
    let components: [AnnotatedQueryComponent]
    let withComponents: [String]
    let withoutComponents: [String]
    let changedComponents: [String]
    let addedComponents: [String]
    /// What the system's code does with the rows; `nil` when the source is not available to analyse
    /// (precompiled modules), which keeps the conservative write access.
    let usage: AdaScriptQueryUsage?
    let source: AnnotatedSourceLocation?

    init(
        propertyName: String,
        components: [AnnotatedQueryComponent],
        withComponents: [String] = [],
        withoutComponents: [String] = [],
        changedComponents: [String] = [],
        addedComponents: [String] = [],
        usage: AdaScriptQueryUsage? = nil,
        source: AnnotatedSourceLocation? = nil
    ) {
        self.propertyName = propertyName
        self.components = components
        self.withComponents = withComponents
        self.withoutComponents = withoutComponents
        self.changedComponents = changedComponents
        self.addedComponents = addedComponents
        self.usage = usage
        self.source = source
    }
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
    let eventReader: Events<AdaScriptRuntimeEvent>?
    let eventReaders: [AnnotatedEventPlan]
    let eventSender: EventsSender<AdaScriptRuntimeEvent>?
    let eventWriters: [AnnotatedEventPlan]
    let declaredAccess: AnnotatedDeclaredAccess?
    let dynamicComponents: [String: PreparedDynamicComponent]
    let isExclusiveWorld: Bool
}

private struct AnnotatedEventBindings {
    let readers: [(propertyName: String, value: GSValue)]
    let writers: [(propertyName: String, writer: AnnotatedGravityEventWriter)]
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
        if case let .reflected(bridge) = self {
            bridge.invalidate()
        } else if case let .input(bridge) = self {
            bridge.invalidate()
        } else if case let .multiplayer(bridge) = self {
            bridge.invalidate()
        }
    }
}

struct PreparedAnnotatedQuery: Sendable {
    let propertyName: String
    let query: DynamicQuery
    let componentAccesses: [AnnotatedComponentAccess]
}

struct AnnotatedComponentAccess: Sendable {
    let alias: String
    let componentIndex: Int
    let fields: [String: ReflectedComponentField]
    /// Whether the scheduler reserved write access; a read-only slot rejects field assignment.
    var isWritable = true
}

// All callbacks below share AdaScriptRuntimeCoordinator.lock. Declare that
// serialization to the ECS planner instead of blocking competing worker tasks.
private struct AdaScriptVMExecution: Resource {}

private struct AdaScriptTaskPumpSystem: System {
    private let deltaTime = Res<DeltaTime?>()
    private let vmAccess = ResMut<AdaScriptVMExecution?>()
    private let pluginIdentifier: String
    private let runtime: AnnotatedGravityRuntime?

    var systemIdentifier: String { Self.makeIdentifier(plugin: pluginIdentifier) }
    var queries: SystemQueries { SystemQueries(queries: [deltaTime, vmAccess]) }

    init(world _: World) {
        pluginIdentifier = "Unconfigured"
        runtime = nil
    }

    init(pluginIdentifier: String, runtime: AnnotatedGravityRuntime) {
        self.pluginIdentifier = pluginIdentifier
        self.runtime = runtime
    }

    static func makeIdentifier(plugin: String) -> String { "AdaScripting.TaskPump.\(plugin)" }

    func update(context: UpdateContext) async {
        runtime?.pumpTasks(
            deltaTime: Double(deltaTime.wrappedValue?.deltaTime ?? 0),
            worldID: "world:\(ObjectIdentifier(context.world).hashValue)"
        )
    }
}

private struct AnnotatedGravityScriptSystem: System {
    private let deltaTime = Res<DeltaTime?>()
    private let vmAccess = ResMut<AdaScriptVMExecution?>()
    private let pluginIdentifier: String
    private let preparedSystem: PreparedAnnotatedSystem?
    private let runtime: AnnotatedGravityRuntime?
    private let nativeSystem: (any System)?

    var systemIdentifier: String {
        guard let preparedSystem else {
            return "AdaScripting.System.Unconfigured"
        }
        return Self.makeIdentifier(plugin: pluginIdentifier, system: preparedSystem.identifier)
    }

    var systemDependencies: [SystemDependency] {
        guard let preparedSystem else {
            return []
        }
        let pumpDependency: [SystemDependency] = preparedSystem.scheduler == .update
            ? [.after(AdaScriptTaskPumpSystem.makeIdentifier(plugin: pluginIdentifier))]
            : []
        // Authored presentation writes must finish before local transforms are published for
        // extraction. Otherwise camera/weapon entities can alternate between two frame poses.
        let transformDependency: [SystemDependency] = preparedSystem.scheduler == .postUpdate
            ? [.before(TransformSystem.self)] : []
        return pumpDependency + transformDependency + preparedSystem.dependencies + (nativeSystem?.systemDependencies ?? [])
    }

    var queries: SystemQueries {
        var parameters: [any SystemParameter] = preparedSystem?.queries.map { $0.query as any SystemParameter } ?? []
        parameters += preparedSystem?.resources.map { $0.parameter as any SystemParameter } ?? []
        parameters += preparedSystem?.remoteCommands.map { $0.parameter as any SystemParameter } ?? []
        parameters += preparedSystem?.rpcMethods.map { $0.parameter as any SystemParameter } ?? []
        if let commands = preparedSystem?.commands {
            parameters.append(commands)
        }
        if let eventReader = preparedSystem?.eventReader {
            parameters.append(eventReader)
        }
        if let eventSender = preparedSystem?.eventSender {
            parameters.append(eventSender)
        }
        if let declaredAccess = preparedSystem?.declaredAccess {
            parameters.append(declaredAccess)
        }
        if preparedSystem?.isExclusiveWorld == true {
            parameters.append(ExclusiveWorldAccess())
        }
        parameters.append(deltaTime)
        if let nativeSystem {
            parameters += nativeSystem.queries.queries
        } else {
            parameters.append(vmAccess)
        }
        return SystemQueries(queries: parameters)
    }

    init(world _: World) {
        self.pluginIdentifier = "Unconfigured"
        self.preparedSystem = nil
        self.runtime = nil
        self.nativeSystem = nil
    }

    init(
        pluginIdentifier: String,
        runtime: AnnotatedGravityRuntime,
        preparedSystem: PreparedAnnotatedSystem,
        nativeSystem: (any System)? = nil
    ) {
        self.pluginIdentifier = pluginIdentifier
        self.runtime = runtime
        self.nativeSystem = nativeSystem
        self.preparedSystem = preparedSystem
    }

    static func makeIdentifier(plugin: String, system: String) -> String {
        "AdaScripting.System.\(plugin.utf8.count):\(plugin)\(system.utf8.count):\(system)"
    }

    func update(context: UpdateContext) async {
        if let nativeSystem {
            await nativeSystem.update(context: context)
            return
        }
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
        let events = runtime.makeEventBindings(for: preparedSystem)
        let world = runtime.makeWorldBridge(
            commands: preparedSystem.commands,
            world: context.world,
            dynamicComponents: preparedSystem.dynamicComponents,
            isExclusiveWorld: preparedSystem.isExclusiveWorld,
            iterators: queries
        )
        runtime.update(
            className: preparedSystem.className,
            systemIdentifier: preparedSystem.identifier,
            deltaTime: Double(deltaTime.wrappedValue?.deltaTime ?? 0),
            queries: zip(preparedSystem.queries, queries).map { ($0.propertyName, $1) },
            remoteCommands: remoteCommands,
            rpcCalls: rpcCalls,
            resources: resources,
            events: events,
            world: world,
            ownerID: "world:\(ObjectIdentifier(context.world).hashValue):system:\(preparedSystem.identifier)"
        )
    }
}

private enum GlobalScalar {
    case bool(Bool)
    case double(Double)
    case integer(Int64)
    case null
    case string(String)
}

private final class AnnotatedGravityRuntime: @unchecked Sendable {
    let annotations: [GravityAnnotation]

    // The runtime owns its delegate for exactly the VM lifetime; this is not a callback back-reference.
    // swiftlint:disable:next weak_delegate
    private let delegate: AnnotatedGravityRuntimeDelegate
    private let runtimeComponents: [RuntimeComponentDescriptor]
    private let virtualMachine: GravityVirtualMachine
    private let taskRuntime: AdaScriptTaskRuntime
    private let asyncHost: AdaScriptAsyncHost
    private let communityBudget: AdaScriptCommunityBudget?
    private var testTimeoutSeconds: Double?
    /// Present only when the module was loaded with tests; the plugin supplies its `build` closure.
    let testWorldFactory: AdaScriptTestWorldFactory?
    private let globalVariableNames: [String]
    private var instances: [String: GSValue] = [:]

    deinit {
        AdaScriptRuntimeCoordinator.lock.withLock {
            taskRuntime.cancelAll()
            asyncHost.cancelAll()
        }
    }

    init(
        module: ResolvedGravityScriptModule,
        componentConstructors: [AdaScriptLinkedComponentConstructor],
        runtimeComponents: [RuntimeComponentDescriptor],
        networkCommands: [AdaScriptNetworkCommandSchema],
        communityPolicy: AdaScriptCommunityPolicy?,
        testTimeout: Duration? = nil
    ) throws {
        let isInstrumented = communityPolicy != nil || testTimeout != nil
        let guardedSources = try module.sourcesByPath.mapValues { source in
            ResolvedGravityScriptModule.Source(
                fileID: source.fileID,
                source: !isInstrumented ? source.source : try AdaScriptCommunityLowerer.instrument(source: source.source)
            )
        }
        let delegate = AnnotatedGravityRuntimeDelegate(module: module, sourcesByPath: guardedSources)
        self.delegate = delegate
        self.runtimeComponents = runtimeComponents

        AdaScriptRuntimeCoordinator.lock.lock()
        defer { AdaScriptRuntimeCoordinator.lock.unlock() }

        let virtualMachine = GravityVirtualMachine(settings: .init(), delegate: delegate)
        try AdaScriptIdentifiers.bind(to: virtualMachine)
        self.virtualMachine = virtualMachine
        if let communityPolicy {
            self.communityBudget = try AdaScriptCommunityBudget.install(in: virtualMachine, policy: communityPolicy)
        } else if let testTimeout {
            // Only the deadline applies: tests keep `System`, the VM's default limits and unrestricted spawns.
            let seconds = Double(testTimeout.components.seconds) + Double(testTimeout.components.attoseconds) / 1e18
            self.communityBudget = try AdaScriptCommunityBudget.install(
                in: virtualMachine,
                policy: AdaScriptCommunityPolicy(maximumCheckpoints: Int.max, maximumCallbackSeconds: seconds),
                restrictsRuntime: false
            )
            self.testTimeoutSeconds = seconds
        } else {
            self.communityBudget = nil
        }
        let suspensionPolicy = AdaScriptSuspensionPolicy(scriptNonSendableTypes: module.nonSendableTypeNames)
        let taskRuntime = AdaScriptTaskRuntime.make(
            virtualMachine: virtualMachine,
            reportDiagnostic: delegate.append,
            suspensionPolicy: suspensionPolicy
        )
        self.taskRuntime = taskRuntime
        let asyncHost = AdaScriptAsyncHost()
        self.asyncHost = asyncHost
        asyncHost.onWake = { taskRuntime.wake() }
        asyncHost.ownerProvider = { taskRuntime.currentOwnerID }
        try virtualMachine.bindClass(with: AdaScriptTaskRuntime.self)
        try suspensionPolicy.bindSafe(AdaScriptAsyncResult.self, to: virtualMachine)
        try suspensionPolicy.bindSafe(AdaScriptAsyncOperation.self, to: virtualMachine)
        try virtualMachine.bindClass(with: AdaScriptAsyncHost.self)
        try suspensionPolicy.bindSafe(AdaScriptSaveWriter.self, to: virtualMachine)
        try suspensionPolicy.bindBorrowed(AnnotatedGravitySystemContext.self, to: virtualMachine)
        try suspensionPolicy.bindBorrowed(AdaScriptInputBridge.self, to: virtualMachine)
        try suspensionPolicy.bindBorrowed(AnnotatedGravityWorldContext.self, to: virtualMachine)
        try virtualMachine.bindClass(with: AnnotatedGravityEventBridge.self)
        try suspensionPolicy.bindBorrowed(AnnotatedGravityEventWriter.self, to: virtualMachine)
        try suspensionPolicy.bindBorrowed(AnnotatedGravityCommandsBridge.self, to: virtualMachine)
        try suspensionPolicy.bindBorrowed(AnnotatedGravityQueryBridge.self, to: virtualMachine)
        try suspensionPolicy.bindBorrowed(AnnotatedGravityQueryRow.self, to: virtualMachine)
        try suspensionPolicy.bindBorrowed(AnnotatedGravityComponentView.self, to: virtualMachine)
        try suspensionPolicy.bindBorrowed(AdaScriptShaderGraphBridge.self, to: virtualMachine)
        try suspensionPolicy.bindBorrowed(AnnotatedGravityResourceView.self, to: virtualMachine)
        try suspensionPolicy.bindBorrowed(AdaScriptMultiplayerAPI.self, to: virtualMachine)
        self.globalVariableNames = module.globalVariableNames
        if module.includesTests {
            let factory = AdaScriptTestWorldFactory()
            self.testWorldFactory = factory
            try suspensionPolicy.bindBorrowed(AdaScriptTestWorld.self, to: virtualMachine)
            try virtualMachine.bindClass(with: AdaScriptTestWorldFactory.self)
            virtualMachine.setValue(factory, forKey: "__adaTestFactory")
        } else {
            self.testWorldFactory = nil
        }
        try virtualMachine.bindClass(with: AdaScriptNetworkCommandFactory.self)
        try virtualMachine.bindClass(with: AdaScriptNetworkCommandValue.self)
        try virtualMachine.bindClass(with: AdaScriptNetworkValueBridge.self)
        try virtualMachine.bindClass(with: AdaScriptRemoteCommandBridge.self)
        try AdaScriptComponentRuntime.bind(
            to: virtualMachine,
            constructors: componentConstructors,
            runtimeDescriptors: runtimeComponents,
            reportDiagnostic: delegate.append
        )
        try AdaScriptAssetRuntime.bind(
            to: virtualMachine,
            reportDiagnostic: delegate.append,
            wake: { taskRuntime.wake() }
        )
        virtualMachine.setValue(
            AdaScriptNetworkCommandFactory.make(
                schemas: networkCommands,
                reportDiagnostic: delegate.append
            ),
            forKey: "__adaNetworkFactory"
        )
        virtualMachine.setValue(taskRuntime, forKey: "__adaTasks")
        virtualMachine.setValue(asyncHost, forKey: "__adaAsync")

        let authoredSource = module.entrySource
        let standardLibrary = communityPolicy == nil ? AdaScriptStandardLibrary.source : AdaScriptStandardLibrary.communitySource
        let runtimeSource = (isInstrumented ? "extern var __adaUGCBudget;\n" : "") + standardLibrary + "\n"
                + "func __ada_instantiate_system(systemType) { return systemType(); }\n"
                + AdaScriptTaskPrelude.source + "\n"
                + (module.includesTests ? AdaScriptTestPrelude.source + "\n" : "")
                + AdaScriptComponentRuntime.prelude(constructors: componentConstructors, authoredSource: module.combinedSource)
                + AdaScriptNetworkBridge.prelude(commands: networkCommands)
                + authoredSource
        let binary = virtualMachine.loadGravityFile(from: !isInstrumented ? runtimeSource : try AdaScriptCommunityLowerer.instrument(source: runtimeSource))
        guard delegate.errors.isEmpty else {
            throw AdaScriptError.compilation(delegate.errors)
        }
        self.annotations = binary.annotations
        communityBudget?.reset()
        virtualMachine.load(binary)
        guard delegate.errors.isEmpty else {
            throw AdaScriptError.compilation(delegate.errors)
        }
        if virtualMachine.getValue(forKey: "main").isClosure {
            throw AdaScriptError.invalidManifest("Ada Script modules must not declare main()")
        }
        // Enable the real-time policy after module initialization has published
        // its classes/functions. Compiler transfer temporarily holds unrooted code.
        virtualMachine.setGCAllocationBudget(AdaScriptRuntimeCoordinator.garbageCollectionAllocationBudget)
    }

    func instantiateSystems(_ plans: [AnnotatedSystemPlan]) throws {
        AdaScriptRuntimeCoordinator.lock.lock()
        defer { AdaScriptRuntimeCoordinator.lock.unlock() }
        communityBudget?.reset()
        for plan in plans {
            let systemClass = virtualMachine.getValue(forKey: plan.className)
            // Class.exec can redirect to an automatically generated initializer. That
            // redirection is executed by VM bytecode, not by a direct host closure call.
            let factory = virtualMachine.getValue(forKey: "__ada_instantiate_system")
            guard systemClass.isClass, let instance = factory.callConstructor(with: [systemClass]), instance.isInstance else {
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
        events: AnnotatedEventBindings,
        world: AnnotatedGravityWorldContext,
        ownerID: String
    ) {
        AdaScriptRuntimeCoordinator.lock.lock()
        defer { AdaScriptRuntimeCoordinator.lock.unlock() }
        communityBudget?.reset()
        let previousOwner = taskRuntime.currentOwnerID
        if let communityBudget {
            world.commands.restrictCommunitySpawns { communityBudget.permitSpawn() }
        }
        taskRuntime.currentOwnerID = ownerID
        defer { taskRuntime.currentOwnerID = previousOwner }
        defer {
            world.invalidate()
            for (_, query) in queries { query.invalidate() }
            for (_, resource) in resources { resource.invalidate() }
            for (_, writer) in events.writers { writer.invalidate() }
        }
        guard !taskRuntime.isVMAborted else {
            return
        }

        guard let instance = instances[className] else {
            return
        }

        do {
            // Swift-held GSValues are not GC roots. Property lookup can allocate
            // a key and collect a new bridge before it reaches the system instance.
            // Resume collection once every binding is rooted, before running user code.
            virtualMachine.setGCEnabled(false)
            defer { virtualMachine.setGCEnabled(true) }
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
            for (propertyName, value) in events.readers {
                guard instance.setStoredProperty(named: propertyName, to: value) else {
                    delegate.append("Unable to bind @events property '\(propertyName)' in system '\(systemIdentifier)'")
                    return
                }
            }
            for (propertyName, writer) in events.writers {
                guard instance.setStoredProperty(named: propertyName, to: GSValue(object: writer, in: virtualMachine)) else {
                    delegate.append("Unable to bind @eventWriter property '\(propertyName)' in system '\(systemIdentifier)'")
                    return
                }
            }
            for (propertyName, value) in remoteCommands {
                guard instance.setStoredProperty(named: propertyName, to: value) else {
                    delegate.append("Unable to bind @remote_commands property '\(propertyName)' in system '\(systemIdentifier)'")
                    return
                }
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

    /// Scalar module-level variables before a test. Strings are kept as Swift values because the VM's collector
    /// cannot see a `GSValue` held here. Lists and maps are references and are not restored.
    private func snapshotGlobals() -> [(name: String, value: GlobalScalar)] {
        globalVariableNames.compactMap { name in
            let value = virtualMachine.getValue(forKey: name)
            if value.isInteger { return (name, .integer(value.toInteger)) }
            if value.isDouble { return (name, .double(value.toDouble)) }
            if value.isBool { return (name, .bool(value.toBoolean)) }
            if value.isString { return (name, .string(value.toString)) }
            if value.isNull { return (name, .null) }
            return nil
        }
    }

    private func restoreGlobals(_ snapshot: [(name: String, value: GlobalScalar)]) {
        for (name, scalar) in snapshot {
            let value: GSValue
            switch scalar {
            case let .integer(number): value = GSValue(integer: Int(number), in: virtualMachine)
            case let .double(number): value = GSValue(double: number, in: virtualMachine)
            case let .bool(flag): value = GSValue(boolean: flag, in: virtualMachine)
            case let .string(text): value = GSValue(string: text, in: virtualMachine)
            case .null: value = GSValue(nullIn: virtualMachine)
            }
            virtualMachine.setValue(value, forKey: name)
        }
    }

    /// A `TestWorld` over `world`, which the caller has already installed the module into.
    func makeTestWorld(
        world: World,
        startupSystems: Set<String>,
        installer: @escaping @Sendable (String?, Set<String>) -> Set<String>
    ) -> AdaScriptTestWorld {
        let payloads = AnnotatedGravityComponentPayloads(
            runtimeComponents: runtimeComponents.reduce(into: [:]) { result, descriptor in
                result[descriptor.name] = descriptor
                result[descriptor.stableID] = descriptor
            },
            reportDiagnostic: appendDiagnostic
        )
        return AdaScriptTestWorld.make(
            world: world,
            exclusive: AnnotatedGravityExclusiveAccess(world: world, payloads: payloads, iterators: [], reportDiagnostic: appendDiagnostic),
            virtualMachine: virtualMachine,
            installer: installer,
            startupSystems: startupSystems,
            reportDiagnostic: appendDiagnostic
        )
    }

    /// Runs one `@test` function in its own fiber so a failed `require` or a runtime error ends only that test.
    func runTest(named name: String) -> AdaScriptTestExecution {
        AdaScriptRuntimeCoordinator.lock.lock()
        defer { AdaScriptRuntimeCoordinator.lock.unlock() }
        communityBudget?.reset()
        let body = virtualMachine.getValue(forKey: name)
        let runner = virtualMachine.getValue(forKey: "__adaTestRun")
        guard body.isClosure, runner.isClosure else {
            return AdaScriptTestExecution(failures: [], runtimeErrors: ["Test '\(name)' is not loaded"], didAbort: true)
        }
        let errorsBefore = delegate.errors.count
        let globals = snapshotGlobals()
        defer { restoreGlobals(globals) }
        communityBudget?.reset()
        let raw = virtualMachine.execute(closure: runner.toGravityClosure, params: [body])
        let reply = raw?.toList ?? []
        let failures = reply.count > 1 ? reply[1].toList.map(\.toString) : []
        return AdaScriptTestExecution(
            failures: failures,
            runtimeErrors: Array(delegate.errors.dropFirst(errorsBefore)).map { error in
                guard let testTimeoutSeconds, error.contains("Community execution limit exceeded") else { return error }
                return "\(name): test timed out after \(testTimeoutSeconds) seconds"
            },
            didAbort: reply.first?.toInteger == 1
        )
    }

    func pumpTasks(deltaTime: Double, worldID: String) {
        AdaScriptRuntimeCoordinator.lock.withLock {
            communityBudget?.reset()
            asyncHost.advanceGameTime(by: deltaTime, forWorld: worldID)
            taskRuntime.pump(onlyWorld: worldID)
        }
    }

    func cancelTasks(forWorld worldID: String) {
        AdaScriptRuntimeCoordinator.lock.withLock {
            taskRuntime.cancel(worldID: worldID)
            asyncHost.cancelGameTimers(forWorld: worldID)
        }
    }

    func resetForSceneChange(plans: [AnnotatedSystemPlan], worldID: String) {
        cancelTasks(forWorld: worldID)
        do {
            try instantiateSystems(plans)
        } catch {
            appendDiagnostic("Could not reset AdaScript systems for scene transition: \(error)")
        }
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

    func makeWorldBridge(
        commands: Commands?,
        world: World,
        dynamicComponents: [String: PreparedDynamicComponent] = [:],
        isExclusiveWorld: Bool = false,
        iterators: [AnnotatedGravityQueryBridge] = []
    ) -> AnnotatedGravityWorldContext {
        AnnotatedGravityWorldContext.make(
            world: world,
            commands: AnnotatedGravityCommandsBridge.make(
                commands: commands,
                navigator: world.getResource(SceneNavigator.self),
                runtimeComponents: runtimeComponents,
                reportDiagnostic: appendDiagnostic
            ),
            dynamicAccess: dynamicComponents.isEmpty ? nil : AnnotatedGravityDynamicAccess(
                world: world,
                components: dynamicComponents,
                virtualMachine: virtualMachine,
                reportDiagnostic: appendDiagnostic
            ),
            exclusiveAccess: isExclusiveWorld ? AnnotatedGravityExclusiveAccess(
                world: world,
                payloads: AnnotatedGravityComponentPayloads(
                    runtimeComponents: runtimeComponents.reduce(into: [:]) { result, descriptor in
                        result[descriptor.name] = descriptor
                        result[descriptor.stableID] = descriptor
                    },
                    reportDiagnostic: appendDiagnostic
                ),
                iterators: iterators,
                reportDiagnostic: appendDiagnostic
            ) : nil,
            reportDiagnostic: appendDiagnostic
        )
    }

    func makeEventBindings(for system: PreparedAnnotatedSystem) -> AnnotatedEventBindings {
        let readers = system.eventReaders.map { plan in
            let events = (system.eventReader?.wrappedValue ?? [])
                .filter { $0.name == plan.eventName }
                .map { GSValue(object: AnnotatedGravityEventBridge(event: $0, virtualMachine: virtualMachine), in: virtualMachine) as Any }
            return (propertyName: plan.propertyName, value: GSValue(newArrayIn: virtualMachine, items: events))
        }
        let writers = system.eventWriters.compactMap { plan -> (propertyName: String, writer: AnnotatedGravityEventWriter)? in
            guard let sender = system.eventSender else {
                return nil
            }
            return (
                propertyName: plan.propertyName,
                writer: AnnotatedGravityEventWriter(eventName: plan.eventName, sender: sender, reportDiagnostic: appendDiagnostic)
            )
        }
        return AnnotatedEventBindings(readers: readers, writers: writers)
    }

    var diagnostics: [String] {
        AdaScriptRuntimeCoordinator.lock.withLock { delegate.errors }
    }

    var activeAsyncTaskCount: Int {
        AdaScriptRuntimeCoordinator.lock.withLock { taskRuntime.activeTaskCount }
    }

    func appendDiagnostic(_ message: String) {
        AdaScriptRuntimeCoordinator.lock.withLock { delegate.append(message) }
    }
}
