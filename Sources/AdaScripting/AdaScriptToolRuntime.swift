import AdaScriptCompilerCore
import Foundation
import Gravity

/// A detached snapshot of the editor document supplied for one tool action.
public struct AdaScriptToolScene: Sendable {
    public let path: String
    public let revision: String
    public let entityCount: Int

    public init(path: String, revision: String, entityCount: Int) {
        self.path = path
        self.revision = revision
        self.entityCount = entityCount
    }
}

/// A panel contribution. The host resolves `ui` relative to the declaring source.
public struct AdaScriptToolPanel: Equatable, Sendable {
    public let id: String
    public let title: String
    public let location: String
    public let ui: String
}

/// An entity creation requested by a tool; the editor applies the complete batch atomically.
public struct AdaScriptToolEntity: Equatable, Sendable {
    public let name: String
    public let x: Double
    public let y: Double
}

/// An instance-owned editor runtime. All execution is main-actor isolated and
/// serialized with other Gravity runtimes. No host editor objects enter the VM.
@MainActor
public final class AdaScriptToolRuntime {
    public let schema: AdaScriptToolSchema
    public private(set) var panels: [AdaScriptToolPanel] = []
    public private(set) var values: [String: AdaScriptSchemaField.Value] = [:]
    public private(set) var isFailed = false
    private let virtualMachine: GravityVirtualMachine
    // Gravity holds its delegate unowned, so the runtime owns it for the VM lifetime.
    // swiftlint:disable:next weak_delegate
    private let delegate: AnnotatedGravityRuntimeDelegate
    private let bridge: AdaScriptToolBridge
    private let instance: GSValue
    private let context: GSValue
    private let budget: AdaScriptCommunityBudget
    private let module: ResolvedGravityScriptModule
    private var isActive = false

    public init(sources: [AdaScriptSource], schema: AdaScriptToolSchema, grantedPermissions: [AdaScriptToolPermission]) throws {
        guard try AdaScriptSchemaParser.parseTools(sources: sources).first(where: { $0.id == schema.id }) == schema else {
            throw AdaScriptError.invalidManifest("Tool metadata does not match its sources.")
        }
        guard schema.apiVersion == 1, schema.platforms.contains(.macOS) else {
            throw AdaScriptError.invalidManifest("This tool requires an unsupported Studio API or platform.")
        }
        let supported: Set<AdaScriptToolPermission> = [.documentRead, .documentWrite]
        guard Set(schema.permissions).isSubset(of: supported), Set(schema.permissions).isSubset(of: Set(grantedPermissions)) else {
            throw AdaScriptError.invalidManifest("The tool's requested permissions are unsupported or have not been granted.")
        }
        for source in sources { try AdaScriptCommunityLowerer.validate(source: source.source) }
        let module = try GravityScriptModuleResolver.resolve(sources)
        try module.requireSynchronousCallback(className: schema.className, method: "activate", annotation: "@tool")
        try module.requireSynchronousCallback(className: schema.className, method: "deactivate", annotation: "@tool")
        self.module = module
        self.schema = schema
        let guardedSources = try module.sourcesByPath.mapValues {
            ResolvedGravityScriptModule.Source(fileID: $0.fileID, source: try AdaScriptCommunityLowerer.instrument(source: $0.source))
        }
        let delegate = AnnotatedGravityRuntimeDelegate(module: module, sourcesByPath: guardedSources)
        self.delegate = delegate
        let bridge = AdaScriptToolBridge.make(permissions: Set(schema.permissions))
        self.bridge = bridge
        let bundle = try AdaScriptRuntimeCoordinator.lock.withLock {
            let vm = GravityVirtualMachine(settings: .init(), delegate: delegate)
            let budget = try AdaScriptCommunityBudget.install(in: vm, policy: .init(maximumCheckpoints: 20_000, maximumCallbackSeconds: 0.05))
            try vm.bindClass(with: AdaScriptToolBridge.self)
            let getters = schema.fields.enumerated().map { index, field in
                "func __ada_tool_get_\(index)(instance) { return instance.\(field.name); }"
            }.joined(separator: "\n")
            let prelude = try AdaScriptCommunityLowerer.instrument(source: AdaScriptStandardLibrary.communitySource + Self.contextPrelude)
            let binary = vm.loadGravityFile(
                from: "extern var __adaUGCBudget;\n" + prelude + "\n" + module.entrySource + "\nfunc __ada_make_tool() { return \(schema.className)(); }\n" + getters
            )
            guard delegate.errors.isEmpty else { throw AdaScriptError.compilation(delegate.errors) }
            budget.reset()
            vm.load(binary)
            guard delegate.errors.isEmpty else { throw AdaScriptError.compilation(delegate.errors) }
            budget.reset()
            guard let instance = vm.getValue(forKey: "__ada_make_tool").callConstructor(with: []), !instance.isNull else {
                throw AdaScriptError.invalidManifest("Unable to instantiate tool '\(schema.id)'.")
            }
            guard let context = vm.getValue(forKey: "__ada_make_context").callConstructor(with: [bridge]), !context.isNull else {
                throw AdaScriptError.invalidManifest("Unable to create the editor tool context.")
            }
            return (vm, budget, instance, context)
        }
        virtualMachine = bundle.0
        budget = bundle.1
        instance = bundle.2
        context = bundle.3
    }

    /// Activation stages registrations; the editor publishes them only after UI validation succeeds.
    public func activate() throws {
        guard !isActive else {
            return
        }
        try AdaScriptRuntimeCoordinator.lock.withLock {
            bridge.isRegistering = true
            defer { bridge.isRegistering = false }
            try invoke("activate", arguments: [context])
            guard !bridge.panels.isEmpty else { throw AdaScriptError.invalidManifest("The tool did not register a .ui panel.") }
            panels = bridge.panels
            try refreshValues()
            isActive = true
        }
    }

    public func validateAction(_ action: String) throws {
        try AdaScriptRuntimeCoordinator.lock.withLock {
            guard action != "activate", action != "deactivate", instance.hasMethod(named: action) else {
                throw AdaScriptError.invalidManifest("Missing tool action '\(action)'.")
            }
            try module.requireSynchronousCallback(className: schema.className, method: action, annotation: "@tool")
        }
    }

    /// Inputs are copied into exported fields before the action. Failed callbacks
    /// discard their queued edits; UI rendering itself never invokes the VM.
    public func perform(_ action: String, inputs: [String: AdaScriptSchemaField.Value], scene: AdaScriptToolScene?) throws -> [AdaScriptToolEntity] {
        guard isActive, !isFailed else { throw AdaScriptError.invalidManifest("The tool is disabled or failed; reload it before running another action.") }
        return try AdaScriptRuntimeCoordinator.lock.withLock {
            try validateAction(action)
            bridge.scene = scene
            bridge.entities = []
            defer {
                bridge.scene = nil
                bridge.entities = []
            }
            for field in schema.fields {
                guard let value = inputs[field.name] else { continue }
                guard Self.matches(value, field.defaultValue), instance.setStoredProperty(named: field.name, to: gravityValue(value)) else {
                    throw AdaScriptError.invalidManifest("Invalid input '\(field.name)'.")
                }
            }
            try invoke(action, arguments: [context])
            try refreshValues()
            return bridge.entities
        }
    }

    public func deactivate() {
        guard isActive else {
            return
        }
        AdaScriptRuntimeCoordinator.lock.withLock {
            // A retired bridge cannot write documents or register new panels.
            bridge.scene = nil
            bridge.isRetired = true
            if instance.hasMethod(named: "deactivate") { try? invoke("deactivate", arguments: []) }
            isActive = false
            panels = []
        }
    }

    private func invoke(_ method: String, arguments: [Any]) throws {
        budget.reset()
        bridge.failure = nil
        let errorCount = delegate.errors.count
        guard instance.hasMethod(named: method), instance.callMethod(named: method, with: arguments) != nil,
            delegate.errors.count == errorCount
        else {
            isFailed = true
            throw AdaScriptError.compilation(Array(delegate.errors.dropFirst(errorCount)) + ["Tool callback '\(method)' failed."])
        }
        if let failure = bridge.failure { throw AdaScriptError.invalidManifest(failure) }
    }

    private func refreshValues() throws {
        var snapshot: [String: AdaScriptSchemaField.Value] = [:]
        for (index, field) in schema.fields.enumerated() {
            guard let value = virtualMachine.getValue(forKey: "__ada_tool_get_\(index)").callConstructor(with: [instance]) else {
                throw AdaScriptError.invalidManifest("Unable to read exported tool field '\(field.name)'.")
            }
            let detached: AdaScriptSchemaField.Value
            if value.isBool {
                detached = .bool(value.toBoolean)
            } else if value.isInteger {
                detached = .int(Int64(value.toInteger))
            } else if value.isDouble, value.toDouble.isFinite {
                detached = .double(value.toDouble)
            } else if value.isString {
                detached = .string(value.toString)
            } else {
                throw AdaScriptError.invalidManifest("Unsupported value in tool field '\(field.name)'.")
            }
            guard Self.matches(detached, field.defaultValue) else {
                throw AdaScriptError.invalidManifest("Type changed for tool field '\(field.name)'.")
            }
            snapshot[field.name] = detached
        }
        values = snapshot
    }

    private func gravityValue(_ value: AdaScriptSchemaField.Value) -> GSValue {
        switch value {
        case .bool(let value): GSValue(boolean: value, in: virtualMachine)
        case .int(let value): GSValue(integer: Int(value), in: virtualMachine)
        case .double(let value): GSValue(double: value, in: virtualMachine)
        case .string(let value): GSValue(string: value, in: virtualMachine)
        }
    }

    private static func matches(_ value: AdaScriptSchemaField.Value, _ expected: AdaScriptSchemaField.Value) -> Bool {
        switch (value, expected) {
        case (.bool, .bool), (.int, .int), (.double, .double), (.string, .string): true
        default: false
        }
    }

    // Script methods retain parameter metadata for named calls. The foreign
    // bridge receives positional raw values and validates them before conversion.
    private static let contextPrelude = """

        class __AdaStudioContext {
            var __host;
            func init(host) { __host = host; }
            var scenePath { get { return __host.scenePath; } };
            var sceneRevision { get { return __host.sceneRevision; } };
            var entityCount { get { return __host.entityCount; } };
            func addPanel(id, title, location, ui) { return __host.addPanel(id, title, location, ui); }
            func createEntity(name, x, y) { return __host.createEntity(name, x, y); }
        }
        func __ada_make_context(host) { return __AdaStudioContext(host); }
        """
}

// Only the owning main-actor runtime accesses this bridge, inside the shared VM lock.
// Bridge calls collect detached data; they never invoke AdaUI or editor models.
@GSExportable("AdaEditorToolContext")
final class AdaScriptToolBridge {
    @GSExportableIgnore let permissions: Set<AdaScriptToolPermission>
    @GSExportableIgnore var panels: [AdaScriptToolPanel] = []
    @GSExportableIgnore var entities: [AdaScriptToolEntity] = []
    @GSExportableIgnore var scene: AdaScriptToolScene?
    @GSExportableIgnore var failure: String?
    @GSExportableIgnore var isRegistering = false
    @GSExportableIgnore var isRetired = false

    var scenePath: String { readableScene?.path ?? "" }
    var sceneRevision: String { readableScene?.revision ?? "" }
    var entityCount: Int { readableScene?.entityCount ?? 0 }

    @GSExportableIgnore
    private var readableScene: AdaScriptToolScene? {
        guard !isRetired, permissions.contains(.documentRead) else {
            failure = "editor.documents.read permission is required."
            return nil
        }
        return scene
    }

    @GSExportableIgnore
    static func make(permissions: Set<AdaScriptToolPermission>) -> AdaScriptToolBridge { AdaScriptToolBridge(permissions: permissions) }

    private init(permissions: Set<AdaScriptToolPermission>) { self.permissions = permissions }

    func addPanel(id: GSValue, title: GSValue, location: GSValue, ui: GSValue) -> Bool {
        guard id.isString, title.isString, location.isString, ui.isString else {
            failure = "Panel arguments must be strings."
            return false
        }
        let id = id.toString
        let title = title.toString
        let location = location.toString
        let ui = ui.toString
        guard isRegistering, !isRetired, !id.isEmpty, !title.isEmpty, location == "right", !ui.isEmpty,
            panels.count < 8, !panels.contains(where: { $0.id == id })
        else {
            failure = "Invalid or duplicate panel; API 1 supports .ui panels in the right sidebar."
            return false
        }
        panels.append(.init(id: id, title: title, location: location, ui: ui))
        return true
    }

    func createEntity(name: GSValue, x: GSValue, y: GSValue) -> Bool {
        guard name.isString, x.isInteger || x.isDouble, y.isInteger || y.isDouble else {
            failure = "Entity arguments must be a name and numeric coordinates."
            return false
        }
        let name = name.toString
        let x = x.isInteger ? Double(x.toInteger) : x.toDouble
        let y = y.isInteger ? Double(y.toInteger) : y.toDouble
        guard !isRetired, !isRegistering, scene != nil, permissions.contains(.documentWrite) else {
            failure = "An open editable scene and editor.documents.write permission are required."
            return false
        }
        guard entities.count < 256, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            x.isFinite, y.isFinite, abs(x) < 1_000_000, abs(y) < 1_000_000
        else {
            failure = "Invalid entity or tool batch exceeds 256 entities."
            return false
        }
        entities.append(.init(name: name, x: x, y: y))
        return true
    }
}
