@_spi(Scripting) import AdaECS
import AdaScriptCompilerCore
import AdaUI
import AdaUtils
import Foundation
import Gravity

/// Metadata for an AdaUI view declared with `@view` in Ada Script.
public struct AdaScriptViewMetadata: Equatable, Sendable {
    public let className: String
    public let environment: [AdaScriptViewEnvironment]
    public let identifier: String
    public let isPreviewable: Bool
    public let line: Int
    public let sourcePath: String
    public let title: String

    public init(
        className: String,
        environment: [AdaScriptViewEnvironment] = [],
        identifier: String,
        isPreviewable: Bool = false,
        line: Int = 1,
        sourcePath: String = "",
        title: String
    ) {
        self.className = className
        self.environment = environment
        self.identifier = identifier
        self.isPreviewable = isPreviewable
        self.line = line
        self.sourcePath = sourcePath
        self.title = title
    }
}

public struct AdaScriptViewEnvironment: Equatable, Sendable {
    public let key: String
    public let propertyName: String

    public init(key: String, propertyName: String) {
        self.key = key
        self.propertyName = propertyName
    }
}

/// Finds `@view` declarations without executing their source.
public enum AdaScriptViewScanner {
    public static func declarations(in sources: [AdaScriptSource]) throws -> [AdaScriptViewMetadata] {
        try AdaScriptSchemaParser.parseViews(sources: sources)
            .map {
                AdaScriptViewMetadata(
                    className: $0.className,
                    environment: $0.environment.map { AdaScriptViewEnvironment(key: $0.key, propertyName: $0.propertyName) },
                    identifier: $0.id,
                    isPreviewable: $0.isPreviewable,
                    line: $0.line,
                    sourcePath: $0.sourcePath,
                    title: $0.title
                )
            }
    }
}

/// A native AdaUI view whose declarative tree is supplied by Ada Script.
@MainActor
public struct AdaScriptView: View {
    private let directStorage: AdaScriptViewStorage?
    private let identifier: String
    private let catalog: UICatalog
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.scaleFactor) private var scaleFactor
    @Environment(\.userInterfaceIdiom) private var userInterfaceIdiom
    @State private var revision = 0
    @State private var storage: AdaScriptViewStorage?

    /// Creates a view registered by `AdaScriptBuildPlugin`.
    public init(_ identifier: String, catalog: UICatalog = .standard) {
        self.catalog = catalog
        self.directStorage = nil
        self.identifier = identifier
    }

    /// Creates a view directly from source, primarily for tools and previews.
    public init(sources: [AdaScriptSource], identifier: String, catalog: UICatalog = .standard) throws {
        self.catalog = catalog
        let metadata = try AdaScriptViewScanner.declarations(in: sources)
        let runtime = try AdaScriptViewModuleRuntime(sources: sources, views: metadata)
        let storage = try runtime.makeStorage(identifier: identifier)
        try storage.updateEnvironment(defaultAdaScriptViewEnvironment())
        self.directStorage = storage
        self.identifier = identifier
    }

    /// Compiles and validates a source-backed view without constructing UI state.
    ///
    /// Editor build tooling uses this entry point away from the main actor before
    /// publishing a prepared runtime artifact back to the UI.
    nonisolated public static func validate(
        sources: [AdaScriptSource],
        identifier: String
    ) throws {
        try AdaScriptRuntimeCoordinator.lock.withLock {
            let metadata = try AdaScriptViewScanner.declarations(in: sources)
            let runtime = try AdaScriptViewModuleRuntime(sources: sources, views: metadata)
            try runtime.validate(identifier: identifier)
        }
    }

    public var body: some View {
        _ = revision
        do {
            let resolvedStorage: AdaScriptViewStorage
            if let storage {
                resolvedStorage = storage
            } else if let directStorage {
                storage = directStorage
                resolvedStorage = directStorage
            } else {
                let newStorage = try AdaScriptViewRegistry.makeStorage(identifier: identifier)
                storage = newStorage
                resolvedStorage = newStorage
            }
            try resolvedStorage.updateEnvironment([
                "colorScheme": .string(colorScheme == .dark ? "dark" : "light"),
                "isEnabled": .bool(isEnabled),
                "scaleFactor": .double(Double(scaleFactor)),
                "userInterfaceIdiom": .string(userInterfaceIdiom.adaScriptName),
            ])
            let revision = $revision
            resolvedStorage.onTaskProgress = { revision.wrappedValue += 1 }
            if let error = resolvedStorage.error {
                return AnyView(
                    Text("Ada Script view error: \(error)")
                        .foregroundColor(.red)
                        .padding(12)
                )
            }
            guard let model = resolvedStorage.model else {
                throw AdaScriptError.invalidManifest("@view '\(identifier)' did not produce a view tree")
            }
            return AnyView(
                AdaScriptRenderedView(
                    model: model,
                    performAction: { action in
                        do {
                            try resolvedStorage.perform(action: action)
                        } catch {
                            resolvedStorage.error = error
                        }
                        revision.wrappedValue += 1
                    },
                    catalog: catalog
                )
            )
        } catch {
            return AnyView(
                Text("Ada Script view error: \(error)")
                    .foregroundColor(.red)
                    .padding(12)
            )
        }
    }
}

/// Process-wide registry populated by generated Ada Script plugins.
@MainActor
public enum AdaScriptViewRegistry {
    private struct Registration {
        let moduleName: String
        let runtime: AdaScriptViewModuleRuntime
    }

    private static var registrations: [String: Registration] = [:]

    public static func register(
        views: [AdaScriptViewMetadata],
        sources: [AdaScriptSource],
        moduleName: String
    ) throws {
        guard !views.isEmpty else {
            return
        }

        let runtime = try AdaScriptViewModuleRuntime(sources: sources, views: views)
        for view in views {
            let storage = try runtime.makeStorage(identifier: view.identifier)
            try storage.updateEnvironment(defaultAdaScriptViewEnvironment())
        }

        var next = registrations.filter { $0.value.moduleName != moduleName }
        for view in views {
            guard next[view.identifier] == nil else {
                throw AdaScriptError.invalidManifest("Duplicate @view id '\(view.identifier)'")
            }
            next[view.identifier] = Registration(moduleName: moduleName, runtime: runtime)
        }
        let previousRuntimes = registrations.values
            .filter { $0.moduleName == moduleName }
            .map(\.runtime)
        for previous in previousRuntimes {
            previous.retire()
        }
        registrations = next
    }

    public static func makeView(identifier: String) throws -> AnyView {
        let storage = try makeStorage(identifier: identifier)
        try storage.updateEnvironment(defaultAdaScriptViewEnvironment())
        guard let model = storage.model else {
            throw AdaScriptError.invalidManifest("@view '\(identifier)' did not produce a view tree")
        }
        return AnyView(
            AdaScriptRenderedView(
                model: model,
                performAction: { action in try? storage.perform(action: action) }
            )
        )
    }

    static func makeStorage(identifier: String) throws -> AdaScriptViewStorage {
        guard let registration = registrations[identifier] else {
            throw AdaScriptError.invalidManifest("Unknown @view id '\(identifier)'")
        }
        return try registration.runtime.makeStorage(identifier: identifier)
    }
}

final class AdaScriptViewModuleRuntime: @unchecked Sendable {
    private let factoryNamesByIdentifier: [String: String]
    private let viewsByIdentifier: [String: AdaScriptViewMetadata]
    // The runtime owns its delegate for exactly the VM lifetime; this is not a callback back-reference.
    // swiftlint:disable:next weak_delegate
    private let delegate: AnnotatedGravityRuntimeDelegate
    private let virtualMachine: GravityVirtualMachine
    private let taskRuntime: AdaScriptTaskRuntime
    private let asyncHost: AdaScriptAsyncHost
    private let exportedParameters: [String]

    @MainActor private var storages: [WeakAdaScriptViewStorage] = []
    @MainActor private var isRetired = false

    init(sources: [AdaScriptSource], views: [AdaScriptViewMetadata], exportedParameters: [String] = []) throws {
        guard exportedParameters.allSatisfy({ $0.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil }) else {
            throw UIDiagnostic("Exported UI parameter names must be stored-property identifiers.")
        }
        self.exportedParameters = exportedParameters
        let componentConstructors = AdaScriptComponentRuntime.linkedConstructors()
        let runtimeComponents = AdaScriptComponentRuntime.runtimeDescriptors(
            schemas: try AdaScriptSchemaParser.parse(sources: sources)
        )
        let networkCommands = try AdaScriptSchemaParser.parseNetworkCommands(sources: sources)
        let module = try GravityScriptModuleResolver.resolve(sources)
        self.factoryNamesByIdentifier = Dictionary(
            uniqueKeysWithValues: views.enumerated()
                .map { index, view in
                    (view.identifier, "__ada_make_view_\(index)")
                }
        )
        self.viewsByIdentifier = Dictionary(uniqueKeysWithValues: views.map { ($0.identifier, $0) })

        let delegate = AnnotatedGravityRuntimeDelegate(module: module)
        self.delegate = delegate

        let runtimeBundle = try AdaScriptRuntimeCoordinator.lock.withLock {
            let virtualMachine = GravityVirtualMachine(settings: .init(), delegate: delegate)
            let taskRuntime = AdaScriptTaskRuntime.make(virtualMachine: virtualMachine, reportDiagnostic: delegate.append)
            let asyncHost = AdaScriptAsyncHost()
            asyncHost.onWake = { taskRuntime.wake() }
            asyncHost.ownerProvider = { taskRuntime.currentOwnerID }
            try virtualMachine.bindClass(with: AdaScriptTaskRuntime.self)
            try virtualMachine.bindClass(with: AdaScriptAsyncResult.self)
            try virtualMachine.bindClass(with: AdaScriptAsyncOperation.self)
            try virtualMachine.bindClass(with: AdaScriptAsyncHost.self)
            try virtualMachine.bindClass(with: AdaScriptSaveWriter.self)
            try virtualMachine.bindClass(with: AdaScriptViewBridge.self)
            try AdaScriptComponentRuntime.bind(
                to: virtualMachine,
                constructors: componentConstructors,
                runtimeDescriptors: runtimeComponents,
                reportDiagnostic: delegate.append
            )
            try virtualMachine.bindClass(with: AdaScriptNetworkCommandFactory.self)
            try virtualMachine.bindClass(with: AdaScriptNetworkCommandValue.self)
            virtualMachine.setValue(
                AdaScriptNetworkCommandFactory.make(schemas: networkCommands, reportDiagnostic: delegate.append),
                forKey: "__adaNetworkFactory"
            )
            try AdaScriptAssetRuntime.bind(
                to: virtualMachine,
                reportDiagnostic: delegate.append,
                wake: { taskRuntime.wake() }
            )
            virtualMachine.setValue(AdaScriptViewBridge(), forKey: "adaUIBuilder")
            virtualMachine.setValue(taskRuntime, forKey: "__adaTasks")
            virtualMachine.setValue(asyncHost, forKey: "__adaAsync")

            let factories = views.enumerated()
                .map { index, view in
                    "func __ada_make_view_\(index)() { return \(view.className)(); }"
                }
                .joined(separator: "\n")
            let getters = exportedParameters.enumerated()
                .map { index, name in
                    "func __ada_ui_get_\(index)(instance) { return instance.\(name); }"
                }
                .joined(separator: "\n")
            let binary = virtualMachine.loadGravityFile(
                from: AdaScriptTaskPrelude.source + "\n"
                    + AdaScriptComponentRuntime.prelude(constructors: componentConstructors)
                    + AdaScriptNetworkBridge.prelude(commands: networkCommands)
                    + module.entrySource + "\n" + factories + "\n" + getters
            )
            guard delegate.errors.isEmpty else {
                throw AdaScriptError.compilation(delegate.errors)
            }
            virtualMachine.load(binary)
            guard delegate.errors.isEmpty else {
                throw AdaScriptError.compilation(delegate.errors)
            }
            return (virtualMachine, taskRuntime, asyncHost)
        }
        self.virtualMachine = runtimeBundle.0
        self.taskRuntime = runtimeBundle.1
        self.asyncHost = runtimeBundle.2
        taskRuntime.onWake = { [weak self] in
            Task { @MainActor [weak self] in self?.dispatchTasks() }
        }
    }

    deinit {
        AdaScriptRuntimeCoordinator.lock.withLock {
            taskRuntime.cancelAll()
            asyncHost.cancelAll()
        }
    }

    @MainActor
    func makeStorage(identifier: String) throws -> AdaScriptViewStorage {
        let storage = try AdaScriptViewStorage(runtime: self, identifier: identifier)
        storages.append(WeakAdaScriptViewStorage(storage))
        return storage
    }

    @MainActor
    private func dispatchTasks() {
        guard !isRetired else {
            return
        }
        AdaScriptRuntimeCoordinator.lock.withLock { taskRuntime.pump() }
        storages.removeAll(where: { $0.storage == nil })
        for storage in storages.compactMap(\.storage) {
            storage.invalidateAfterTaskProgress()
        }
    }

    @MainActor
    func retire() {
        guard !isRetired else {
            return
        }
        isRetired = true
        AdaScriptRuntimeCoordinator.lock.withLock {
            taskRuntime.cancelAll()
            asyncHost.cancelAll()
        }
    }

    func validate(identifier: String) throws {
        _ = try makeInstance(identifier: identifier)
    }

    @MainActor
    func instantiate(identifier: String) throws -> GSValue {
        try makeInstance(identifier: identifier)
    }

    private func makeInstance(identifier: String) throws -> GSValue {
        try AdaScriptRuntimeCoordinator.lock.withLock {
            guard let factoryName = factoryNamesByIdentifier[identifier] else {
                throw AdaScriptError.invalidManifest("Unknown @view id '\(identifier)'")
            }
            let factory = virtualMachine.getValue(forKey: factoryName)
            guard
                factory.isClosure,
                let instance = factory.callConstructor(with: []),
                instance.isInstance
            else {
                throw AdaScriptError.invalidManifest("Unable to instantiate @view '\(identifier)'")
            }
            guard instance.hasMethod(named: "body") else {
                throw AdaScriptError.invalidManifest("@view '\(identifier)' must define body()")
            }
            return instance
        }
    }

    @MainActor
    func writeInputs(_ values: [String: UIValue], instance: GSValue) throws {
        try AdaScriptRuntimeCoordinator.lock.withLock {
            for (name, value) in values {
                guard exportedParameters.contains(name), instance.setStoredProperty(named: name, to: AdaScriptUIValueBridge.make(value, in: virtualMachine)) else {
                    throw UIDiagnostic("Cannot bind exported property '\(name)'.")
                }
            }
        }
    }

    @MainActor
    func readInput(_ name: String, instance: GSValue) throws -> UIValue {
        try AdaScriptRuntimeCoordinator.lock.withLock {
            guard
                let index = exportedParameters.firstIndex(of: name),
                let value = virtualMachine.getValue(forKey: "__ada_ui_get_\(index)").callConstructor(with: [instance]),
                let field = AdaScriptUIValueBridge.detached(value)
            else {
                throw UIDiagnostic("Cannot read exported binding '\(name)'.")
            }
            return field
        }
    }

    @MainActor
    func evaluate(
        instance: GSValue,
        identifier: String,
        environment: [String: ReflectedFieldValue]
    ) throws -> AdaScriptViewModel {
        guard !isRetired else {
            throw AdaScriptError.invalidManifest("Ada Script view belongs to a retired module generation")
        }
        guard !taskRuntime.isVMAborted else {
            throw AdaScriptError.invalidManifest("Ada Script VM stopped after a coroutine failure; reload the module")
        }
        return try AdaScriptRuntimeCoordinator.lock.withLock {
            guard let metadata = viewsByIdentifier[identifier] else {
                throw AdaScriptError.invalidManifest("Unknown @view id '\(identifier)'")
            }
            for binding in metadata.environment {
                guard let value = environment[binding.key] else {
                    throw AdaScriptError.invalidManifest("Unknown environment key '\(binding.key)' in @view '\(identifier)'")
                }
                guard
                    instance.setStoredProperty(
                        named: binding.propertyName,
                        to: AnnotatedGravityValueBridge.makeGravityValue(value, virtualMachine: virtualMachine)
                    )
                else {
                    throw AdaScriptError.invalidManifest("Unable to bind @environment property '\(binding.propertyName)' in @view '\(identifier)'")
                }
            }
            let builder = AdaScriptViewBridge()
            virtualMachine.setValue(builder, forKey: "adaUIBuilder")
            guard
                let value = instance.callMethod(named: "body", with: []),
                let bridge = value.toObjectOf(AdaScriptViewBridge.self)
            else {
                let diagnostic = delegate.errors.isEmpty ? "" : ": \(delegate.errors.suffix(5).joined(separator: "; "))"
                throw AdaScriptError.invalidManifest("@view '\(identifier)' body() must return a View value\(diagnostic)")
            }
            return bridge.model
        }
    }

    @MainActor
    func perform(instance: GSValue, action: String, identifier: String, ownerID: String) throws {
        guard !isRetired else {
            throw AdaScriptError.invalidManifest("Ada Script view belongs to a retired module generation")
        }
        guard !taskRuntime.isVMAborted else {
            throw AdaScriptError.invalidManifest("Ada Script VM stopped after a coroutine failure; reload the module")
        }
        try AdaScriptRuntimeCoordinator.lock.withLock {
            let previousOwner = taskRuntime.currentOwnerID
            taskRuntime.currentOwnerID = "view:\(ownerID)"
            defer { taskRuntime.currentOwnerID = previousOwner }
            guard instance.hasMethod(named: action) else {
                throw AdaScriptError.invalidManifest("Unknown action '\(action)' in @view '\(identifier)'")
            }
            guard instance.callMethod(named: action, with: []) != nil else {
                let diagnostic = delegate.errors.last.map { ": \($0)" } ?? ""
                throw AdaScriptError.invalidManifest("Action '\(action)' failed in @view '\(identifier)'\(diagnostic)")
            }
        }
    }

    func cancelTasks(ownerID: String) {
        AdaScriptRuntimeCoordinator.lock.withLock {
            taskRuntime.cancel(ownerID: "view:\(ownerID)")
            asyncHost.cancelSaveWriters(forOwner: "view:\(ownerID)")
        }
    }

    @MainActor
    var activeTaskCount: Int {
        AdaScriptRuntimeCoordinator.lock.withLock { taskRuntime.activeTaskCount }
    }
}

@MainActor
final class AdaScriptViewStorage {
    var error: (any Error)?
    var onTaskProgress: (@MainActor () -> Void)?
    private(set) var model: AdaScriptViewModel?

    private let identifier: String
    private let instance: GSValue
    private let runtime: AdaScriptViewModuleRuntime
    private let ownerID = UUID().uuidString
    private var environment: [String: ReflectedFieldValue] = [:]

    init(runtime: AdaScriptViewModuleRuntime, identifier: String) throws {
        self.identifier = identifier
        self.runtime = runtime
        let instance = try runtime.instantiate(identifier: identifier)
        self.instance = instance
        self.model = nil
    }

    deinit { runtime.cancelTasks(ownerID: ownerID) }

    private var inputs: [String: UIValue] = [:]

    func updateInputs(_ values: [String: UIValue]) throws {
        guard inputs != values else {
            return
        }
        try runtime.writeInputs(values, instance: instance)
        inputs = values
        model = nil
    }

    func readInput(_ name: String) throws -> UIValue { try runtime.readInput(name, instance: instance) }

    func updateEnvironment(_ environment: [String: ReflectedFieldValue]) throws {
        guard model == nil || self.environment != environment else {
            return
        }
        self.environment = environment
        model = try runtime.evaluate(instance: instance, identifier: identifier, environment: environment)
    }

    func perform(action: String) throws {
        try runtime.perform(instance: instance, action: action, identifier: identifier, ownerID: ownerID)
        model = try runtime.evaluate(instance: instance, identifier: identifier, environment: environment)
        error = nil
    }

    func invalidateAfterTaskProgress() {
        model = nil
        onTaskProgress?()
    }
}

@MainActor
private final class WeakAdaScriptViewStorage {
    weak var storage: AdaScriptViewStorage?

    init(_ storage: AdaScriptViewStorage) { self.storage = storage }
}

extension UserInterfaceIdiom {
    var adaScriptName: String {
        switch self {
        case .desktop: "desktop"
        case .pad: "pad"
        case .phone: "phone"
        case .tv: "tv"
        case .xr: "xr"
        }
    }
}

private func defaultAdaScriptViewEnvironment() -> [String: ReflectedFieldValue] {
    [
        "colorScheme": .string("light"),
        "isEnabled": .bool(true),
        "scaleFactor": .double(1),
        "userInterfaceIdiom": .string("desktop"),
    ]
}
