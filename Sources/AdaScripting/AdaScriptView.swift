@_spi(Scripting) import AdaECS
import AdaScriptCompilerCore
import AdaText
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
    /// Creates a view registered by `AdaScriptBuildPlugin`.
    public init(_ identifier: String, catalog: UICatalog = .standard) {
        _ = identifier
        _ = catalog
    }

    /// AdaScript-backed AdaUI views are temporarily unavailable.
    public init(sources: [AdaScriptSource], identifier: String, catalog: UICatalog = .standard) throws {
        _ = sources
        _ = identifier
        _ = catalog
        throw AdaScriptError.invalidManifest("AdaUI views in AdaScript are temporarily unavailable.")
    }

    /// Rejects legacy preview and build requests for AdaScript-backed views.
    nonisolated public static func validate(sources: [AdaScriptSource], identifier: String) throws {
        _ = sources
        _ = identifier
        throw AdaScriptError.invalidManifest("AdaUI views in AdaScript are temporarily unavailable.")
    }

    public var body: some View {
        Text("AdaUI views in AdaScript are temporarily unavailable.")
    }
}

/// Compatibility entry point retained while the AdaScript UI integration is redesigned.
@MainActor
public enum AdaScriptViewRegistry {
    public static func register(
        views: [AdaScriptViewMetadata],
        sources: [AdaScriptSource],
        moduleName: String
    ) throws {
        _ = views
        _ = sources
        _ = moduleName
        throw AdaScriptError.invalidManifest("AdaUI views in AdaScript are temporarily unavailable.")
    }

    public static func makeView(identifier: String) throws -> AnyView {
        _ = identifier
        throw AdaScriptError.invalidManifest("AdaUI views in AdaScript are temporarily unavailable.")
    }

    static func makeStorage(identifier: String) throws -> AdaScriptViewStorage {
        _ = identifier
        throw AdaScriptError.invalidManifest("AdaUI views in AdaScript are temporarily unavailable.")
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
        for view in views {
            try module.requireSynchronousCallback(className: view.className, method: "body", annotation: "@view")
        }
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
            let suspensionPolicy = AdaScriptSuspensionPolicy(scriptNonSendableTypes: module.nonSendableTypeNames)
            let taskRuntime = AdaScriptTaskRuntime.make(
                virtualMachine: virtualMachine,
                reportDiagnostic: delegate.append,
                suspensionPolicy: suspensionPolicy
            )
            let asyncHost = AdaScriptAsyncHost()
            asyncHost.onWake = { taskRuntime.wake() }
            asyncHost.ownerProvider = { taskRuntime.currentOwnerID }
            try virtualMachine.bindClass(with: AdaScriptTaskRuntime.self)
            try suspensionPolicy.bindSafe(AdaScriptAsyncResult.self, to: virtualMachine)
            try suspensionPolicy.bindSafe(AdaScriptAsyncOperation.self, to: virtualMachine)
            try virtualMachine.bindClass(with: AdaScriptAsyncHost.self)
            try suspensionPolicy.bindSafe(AdaScriptSaveWriter.self, to: virtualMachine)
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
                from: AdaScriptStandardLibrary.source + "\n"
                    + AdaScriptTaskPrelude.source + "\n"
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
