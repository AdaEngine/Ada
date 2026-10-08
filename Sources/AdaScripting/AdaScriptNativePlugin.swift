#if canImport(GravityAOT)
import AdaApp
@_spi(Scripting) import AdaECS
import AdaInput
import AdaMultiplayer
import AdaScene
import AdaScriptCompilerCore
import AdaTilemap
import AdaUtils
import Foundation
import GravityAOT

/// Installs statically linked AOT module metadata and native callbacks into the
/// existing ECS scheduler. Compilation and foreign-runtime ownership stay in Gravity.
public final class AdaScriptNativePlugin: Plugin, @unchecked Sendable {
    public let name: String
    public var pluginIdentifier: String { "AdaScripting.Native.\(name)" }
    public var diagnostics: [String] { recorder.messages }
    public var componentDescriptors: [RuntimeComponentDescriptor] { metadata.components }
    public var preloadedTileMaps: [String: TileMap] { assets.tileMaps }
    private let module: NativeModule
    private let metadata: NativeMetadata
    private let recorder = NativeDiagnostics()
    private let assets = NativeAssetStore()
    private let asyncRegistry = NativeAsyncRegistry()
    private let preloadedAssets: [String]
    @MainActor private var loadingTask: Task<Void, Never>?

    public init(module: NativeModule, name: String, sources: [AdaScriptSource] = [], startupSystemIdentifier: String? = nil, preloadedAssets: [String] = []) throws {
        self.module = module
        self.preloadedAssets = preloadedAssets
        self.name = name
        metadata = try NativeMetadata(module: module, sources: sources, startupSystemIdentifier: startupSystemIdentifier)
    }

    /// Validates component/resource bindings without installing schedulers or
    /// changing global scriptable registrations. Used by Editor before publishing.
    @MainActor
    public func validateBindings() throws {
        let world = World(name: "Native AdaScript binding validation")
        for descriptor in metadata.components { world.registerRuntimeComponent(descriptor) }
        for plan in metadata.plans {
            for (index, query) in plan.queries.enumerated() {
                _ = try AdaScriptPlugin.prepareQuery(query, systemIdentifier: plan.identifier, queryIndex: index, world: world)
            }
            for resource in plan.resources { _ = try prepareResource(resource) }
        }
        try validateNativeScriptableBindings(module: module, metadata: metadata, world: world, recorder: recorder)
    }

    @MainActor
    public func setup(in app: borrowing AppWorlds) {
        do {
            if !preloadedAssets.isEmpty {
                assets.beginPreloading()
                loadingTask = Task {
                    defer { assets.finishPreloading() }
                    do { try await assets.preload(paths: preloadedAssets) } catch { recorder.append("Native asset preload failed: \(error)") }
                }
            }
            for descriptor in metadata.components { app.main.registerRuntimeComponent(descriptor) }
            var resources = app.main.getResource(AdaScriptNativeResources.self) ?? AdaScriptNativeResources()
            for schema in metadata.resources.values where schema.autoInsert && resources.values[schema.identifier] == nil {
                resources.values[schema.identifier] = schema.defaults
            }
            app.main.insertResource(resources)
            app.main.getResource(SceneNavigator.self)?.onSceneWillReplace { [weak asyncRegistry] in
                asyncRegistry?.cancelAll(stopOwners: false)
            }
            try installNetwork(in: app)
            let systems = try metadata.plans.map { plan in
                let asyncRuntime = NativeAsyncRuntime(module: module, registry: asyncRegistry)
                return NativeECSSystem(
                    module: module,
                    instance: try module.makeInstance(type: plan.className, globals: asyncRuntime.globals),
                    plan: plan,
                    plugin: name,
                    queries: try plan.queries.enumerated().map {
                        try AdaScriptPlugin.prepareQuery($0.element, systemIdentifier: plan.identifier, queryIndex: $0.offset, world: app.main)
                    },
                    resources: try plan.resources.map(prepareResource),
                    recorder: recorder,
                    commands: Commands(entities: app.main.entities, commandsQueue: app.main.commandQueue),
                    components: metadata.components,
                    networkSchemas: metadata.networkCommands,
                    assets: assets,
                    asyncRuntime: asyncRuntime
                )
            }
            try registerNativeScriptables(module: module, metadata: metadata, world: app.main, recorder: recorder, asyncRegistry: asyncRegistry)
            for system in systems { app.main.schedulers.addSystem(system, for: system.scheduler) }
        } catch {
            recorder.append("Unable to install native AdaScript '\(name)': \(error)")
        }
    }

    @MainActor
    public func destroy(for _: borrowing AppWorlds) {
        asyncRegistry.cancelAll()
        loadingTask?.cancel()
        loadingTask = nil
        recorder.disable()
    }

    @MainActor
    public func isLoaded(in _: borrowing AppWorlds) -> Bool { assets.isLoaded }

    @MainActor
    private func installNetwork(in app: borrowing AppWorlds) throws {
        let replicated = metadata.dataSchemas.filter { $0.replication != nil }
        guard !metadata.networkCommands.isEmpty || !replicated.isEmpty else { return }
        guard app.getResource(MultiplayerRegistry.self) != nil else {
            throw AdaScriptError.invalidManifest("Native networking requires MultiplayerPlugin")
        }
        for schema in replicated {
            guard let descriptor = metadata.components.first(where: { $0.stableID == schema.id }) else {
                throw AdaScriptError.invalidManifest("Missing native replicated component '\(schema.name)'")
            }
            let indices = Dictionary(
                uniqueKeysWithValues: schema.fields.enumerated().compactMap { index, field in
                    field.network.map { ($0.tag, index) }
                }
            )
            app.registerReplicatedRuntimeComponent(descriptor, schema: try AdaScriptNetworkBridge.descriptor(for: schema), fieldIndices: indices)
        }
        for command in metadata.networkCommands {
            app.registerAdaScriptNetworkCommand(
                name: command.name,
                schema: try AdaScriptNetworkBridge.descriptor(for: command),
                fieldNames: Dictionary(uniqueKeysWithValues: command.fields.compactMap { field in field.network.map { ($0.tag, field.name) } }),
                orderedTags: command.fields.compactMap(\.network?.tag)
            )
        }
    }

    private func prepareResource(_ plan: AnnotatedResourcePlan) throws -> NativePreparedResource {
        if plan.resourceName == "Input" {
            return NativePreparedResource(propertyName: plan.propertyName, optional: plan.isOptional, storage: .input(Res<Input?>()))
        }
        if let schema = metadata.resources[plan.resourceName] {
            return NativePreparedResource(
                propertyName: plan.propertyName,
                optional: plan.isOptional,
                storage: .compiled(ResMut<AdaScriptNativeResources>(), schema)
            )
        }
        guard let type = RuntimeTypeRegistry.resourceType(named: plan.resourceName),
            let fields = RuntimeResourceReflectionRegistry.descriptor(for: type)?.fields
        else {
            throw AdaScriptError.unknownResource(system: name, resource: plan.resourceName)
        }
        return NativePreparedResource(
            propertyName: plan.propertyName,
            optional: plan.isOptional,
            storage: .reflected(
                DynamicResource(resourceType: type, isOptional: plan.isOptional, writable: true),
                Dictionary(uniqueKeysWithValues: fields.map { ($0.key, $0) })
            )
        )
    }
}

/// Scheduler workers and lifecycle callbacks append diagnostics through one lock.
final class NativeDiagnostics: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    private var active = true
    var messages: [String] { lock.withLock { storage } }
    var isActive: Bool { lock.withLock { active } }
    func disable() { lock.withLock { active = false } }
    func append(_ message: String) {
        lock.withLock { if storage.count < 100 { storage.append(message) } }
        RuntimeLogStore.shared.append(level: "error", label: "AdaScript", message: message)
    }
}

private struct NativeECSSystem: System {
    private let deltaTime = Res<DeltaTime?>()
    private let module: NativeModule?
    private let instance: NativeInstance?
    private let plan: AnnotatedSystemPlan?
    private let plugin: String
    private let nativeQueries: [PreparedAnnotatedQuery]
    private let nativeResources: [NativePreparedResource]
    private let recorder: NativeDiagnostics?
    private let commands: Commands
    private let navigator = Res<SceneNavigator?>()
    private let network: ResMut<AdaScriptNetworkRuntime>?
    private let components: [RuntimeComponentDescriptor]
    private let networkSchemas: [AdaScriptNetworkCommandSchema]
    private let assets: NativeAssetStore
    private let asyncRuntime: NativeAsyncRuntime?
    var scheduler: SchedulerName { plan?.scheduler ?? .update }
    var systemIdentifier: String { Self.identifier(plugin: plugin, system: plan?.identifier ?? "Unconfigured") }
    var systemDependencies: [SystemDependency] {
        plan?.dependencies.map {
            switch $0 {
            case .before(let id): .before(Self.identifier(plugin: plugin, system: id))
            case .after(let id): .after(Self.identifier(plugin: plugin, system: id))
            }
        } ?? []
    }
    var queries: SystemQueries {
        SystemQueries(
            queries: nativeQueries.map { $0.query as any SystemParameter } + nativeResources.map(\.parameter) + [deltaTime, commands, navigator]
                + (network.map { [$0 as any SystemParameter] } ?? [])
        )
    }
    init(world: World) {
        module = nil
        instance = nil
        plan = nil
        plugin = "Unconfigured"
        nativeQueries = []
        nativeResources = []
        recorder = nil
        commands = Commands(entities: world.entities, commandsQueue: world.commandQueue)
        components = []
        networkSchemas = []
        network = nil
        assets = NativeAssetStore()
        asyncRuntime = nil
    }
    init(
        module: NativeModule,
        instance: NativeInstance,
        plan: AnnotatedSystemPlan,
        plugin: String,
        queries: [PreparedAnnotatedQuery],
        resources: [NativePreparedResource],
        recorder: NativeDiagnostics,
        commands: Commands,
        components: [RuntimeComponentDescriptor],
        networkSchemas: [AdaScriptNetworkCommandSchema],
        assets: NativeAssetStore,
        asyncRuntime: NativeAsyncRuntime
    ) {
        self.module = module
        self.instance = instance
        self.plan = plan
        self.plugin = plugin
        nativeQueries = queries
        nativeResources = resources
        self.recorder = recorder
        self.commands = commands
        self.components = components
        self.networkSchemas = networkSchemas
        self.network = networkSchemas.isEmpty ? nil : ResMut<AdaScriptNetworkRuntime>()
        self.assets = assets
        self.asyncRuntime = asyncRuntime
    }
    static func identifier(plugin: String, system: String) -> String {
        "AdaScripting.NativeSystem.\(plugin.utf8.count):\(plugin)\(system.utf8.count):\(system)"
    }
    func update(context _: UpdateContext) async {
        guard let module, let instance, let plan, let recorder, recorder.isActive else {
            return
        }
        let scope = NativeCallbackScope()
        defer { scope.isActive = false }
        do {
            var bindings: [String: NativeValue] = [:]
            for query in nativeQueries { bindings[query.propertyName] = .host(NativeQueryHost(query: query, scope: scope)) }
            for resource in nativeResources { bindings[resource.propertyName] = try resource.bridge(scope: scope) }
            for remote in plan.remoteCommands {
                bindings[remote.propertyName] = .host(NativeRemoteCommandsHost(
                    payloads: network?.wrappedValue.commands(named: remote.commandName) ?? [], scope: scope
                ))
            }
            let world = NativeWorldHost(scope: scope, commands: commands, navigator: navigator.wrappedValue, components: components, module: module)
            let assetHost = NativeAssetsHost(store: assets, scope: scope, asyncRuntime: asyncRuntime)
            let networkHost = NativeNetworkHost(runtime: network, schemas: networkSchemas, module: module, scope: scope)
            let globals: [String: NativeValue] = (asyncRuntime?.globals ?? [:]).merging([
                "Assets": .host(assetHost), "__adaAssets": .host(assetHost), "multiplayer": .host(networkHost),
                "__adaComponentFactory": .host(NativeComponentFactory(scope: scope, components: components)),
                "__adaNetworkFactory": .host(NativeNetworkFactory(schemas: networkSchemas, scope: scope)),
            ]) { _, host in host }
            asyncRuntime?.advance(deltaTime: Double(deltaTime.wrappedValue?.deltaTime ?? 0))
            asyncRuntime?.resume(receiver: instance, bindings: bindings, globals: globals, recorder: recorder)
            for rpc in plan.rpcMethods {
                for payload in network?.wrappedValue.commands(named: rpc.commandName) ?? [] {
                    let values = rpc.fieldNames.map { payload.values[$0]?.nativeValue ?? .null }
                    let method = module.types.first(where: { $0.name == plan.className })?.methods.first(where: { $0.name == rpc.commandName })
                    let args = method?.parameters.first?.name == "source" ? [NativeValue.string(payload.source)] + values : values
                    let value = try module.invoke(instance, method: rpc.commandName, arguments: args, bindings: bindings, globals: globals)
                    try asyncRuntime?.adopt(value)
                }
            }
            let value = try module.invoke(
                instance,
                method: "update",
                arguments: [
                    .host(NativeSystemContext(scope: scope, deltaTime: Double(deltaTime.wrappedValue?.deltaTime ?? 0), world: world, assets: assetHost))
                ],
                bindings: bindings,
                globals: globals
            )
            try asyncRuntime?.adopt(value)
        } catch {
            recorder.append("Native AdaScript system '\(plan.identifier)' failed: \(error)")
        }
    }
}
#endif
