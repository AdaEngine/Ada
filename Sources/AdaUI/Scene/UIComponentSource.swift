import AdaECS
import AdaRender
import AdaUIDescription
import AdaUtils
import Foundation

/// Serializable source of an ECS UI. Native closures and live View instances are never encoded.
public struct UIComponentSource: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case ui, script, swiftView }
    public var kind: Kind
    public var path: String
    public var identifier: String
    public var contextName: String
    public var inputs: [String: UIValue]
    /// Input names mapped to exported fields of scripts attached to this UI entity.
    public var scriptBindings: [String: UIScriptFieldBinding]

    public init(
        kind: Kind = .ui,
        path: String = "",
        identifier: String = "",
        contextName: String = "",
        inputs: [String: UIValue] = [:],
        scriptBindings: [String: UIScriptFieldBinding] = [:]
    ) {
        self.kind = kind
        self.path = path
        self.identifier = identifier
        self.contextName = contextName
        self.inputs = inputs
        self.scriptBindings = scriptBindings
    }

    private enum CodingKeys: String, CodingKey { case kind, path, identifier, contextName, inputs, scriptBindings }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            kind: try container.decodeIfPresent(Kind.self, forKey: .kind) ?? .ui,
            path: try container.decodeIfPresent(String.self, forKey: .path) ?? "",
            identifier: try container.decodeIfPresent(String.self, forKey: .identifier) ?? "",
            contextName: try container.decodeIfPresent(String.self, forKey: .contextName) ?? "",
            inputs: try container.decodeIfPresent([String: UIValue].self, forKey: .inputs) ?? [:],
            scriptBindings: try container.decodeIfPresent([String: UIScriptFieldBinding].self, forKey: .scriptBindings) ?? [:]
        )
    }
}

/// A stored-property binding scoped to the scripts on the same entity as the UI component.
public struct UIScriptFieldBinding: Codable, Hashable, Sendable {
    public var script: String
    public var field: String

    public init(script: String, field: String) {
        self.script = script
        self.field = field
    }
}

/// Runtime services are scoped to a world/project, so concurrently open projects never share UI state.
@MainActor
public final class UIComponentRuntime {
    public var catalog: UICatalog
    public let resources: UISceneResources
    public var defaultContext: UIBindingContext?
    public var contexts: [String: UIBindingContext] = [:]
    public var scriptFactory: (@MainActor (UIComponentSource, UIBindingContext, UISceneResources) throws -> AnyView)?
    private var sessions: [WeakUISession] = []

    public init(resourceRoot: URL, catalog: UICatalog = .standard) {
        self.resources = UISceneResources(rootURL: resourceRoot)
        self.catalog = catalog
    }

    /// Validates persisted mappings without constructing a view or executing gameplay scripts.
    public func validateScriptBindings(source: UIComponentSource) throws {
        guard !source.scriptBindings.isEmpty else {
            return
        }
        guard source.kind == .ui else {
            throw UIDiagnostic("Script field bindings require a .ui source.")
        }
        guard source.contextName.isEmpty else {
            throw UIDiagnostic("Script field bindings use an entity-owned context. Clear Data context.")
        }
        let document = try resources.load(resources.resolve(source.path))
        if let name = source.scriptBindings.keys.first(where: { name in !document.inputs.contains { $0.name == name } }) {
            throw UIDiagnostic("UI input '\(name)' is not declared in '\(source.path)'.")
        }
    }

    public func makeView(source: UIComponentSource, context suppliedContext: UIBindingContext? = nil) throws -> AnyView {
        try validateScriptBindings(source: source)
        let context: UIBindingContext
        if let suppliedContext {
            context = suppliedContext
        } else if source.contextName.isEmpty {
            context = defaultContext ?? UIBindingContext(values: source.inputs)
        } else if let named = contexts[source.contextName] {
            context = named
        } else {
            throw UIDiagnostic("Unknown UI context '\(source.contextName)'.")
        }
        switch source.kind {
        case .ui:
            let url = try resources.resolve(source.path)
            let document = try resources.load(url)
            let session = try UISceneInstance(document: document, context: context, catalog: catalog, resources: resources, sourceURL: url)
            sessions.append(WeakUISession(session))
            return AnyView(UISceneView(session: session))
        case .script:
            guard let scriptFactory else {
                throw UIDiagnostic("This host has no AdaScript UI source provider.")
            }
            return try scriptFactory(source, context, resources)
        case .swiftView:
            let node = UINodeDescription(type: source.identifier, arguments: source.inputs.mapValues { .init(value: $0) })
            return AnyView(UISceneView(session: try UISceneInstance(document: .init(root: node), context: context, catalog: catalog, resources: resources)))
        }
    }

    /// Revalidates mounted scenes after a file watcher reports a resource change.
    public func reload(_ url: URL, document: UISceneDocument? = nil) throws {
        if let document {
            try resources.publish(document, at: url)
        } else {
            resources.invalidate(url)
        }
        sessions.removeAll { $0.value == nil }
        for session in sessions.compactMap(\.value) {
            let candidate = try session.sourceURL.map(resources.load) ?? session.document
            _ = session.update(candidate)
            session.context.invalidate()
        }
    }
}

private final class WeakUISession {
    weak var value: UISceneInstance?
    init(_ value: UISceneInstance) { self.value = value }
}

/// Insert into a world's resources before loading entities with file-backed UI components.
public struct UIComponentRuntimeResource: Resource {
    public let runtime: UIComponentRuntime
    public init(_ runtime: UIComponentRuntime) { self.runtime = runtime }
}

final class UIComponentStorage: Sendable {
    let source: UIComponentSource?
    let suppliedView: UIView?
    @MainActor private var resolvedView: UIView?
    @MainActor private var runtime: UIComponentRuntime?
    @MainActor var scriptData: UIScriptBindingData?

    @MainActor func bindingData() -> UIScriptBindingData? {
        guard let source, !source.scriptBindings.isEmpty else {
            return nil
        }
        if let scriptData {
            return scriptData
        }
        let data = UIScriptBindingData(values: source.inputs)
        scriptData = data
        return data
    }

    init(view: UIView) {
        suppliedView = view
        source = nil
    }
    init(source: UIComponentSource) {
        suppliedView = nil
        self.source = source
    }

    @MainActor
    func resolve(runtime: UIComponentRuntime?) throws -> UIView {
        if let suppliedView {
            return suppliedView
        }
        if let resolvedView {
            return resolvedView
        }
        guard let source else {
            throw UIDiagnostic("Missing UI source.")
        }
        let runtime = runtime ?? self.runtime ?? UIComponentRuntime(resourceRoot: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
        self.runtime = runtime
        let view = UIContainerView(rootView: try runtime.makeView(source: source, context: bindingData()?.context))
        view.backgroundColor = .clear
        resolvedView = view
        return view
    }
}
