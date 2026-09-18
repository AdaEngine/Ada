import AdaRender
import AdaScriptCompilerCore
import AdaUI
import Foundation

extension UIComponentRuntime {
    /// Installs the optional AdaScript source provider in this host's UI runtime.
    @MainActor
    public func enableAdaScript(sourceRoot: URL? = nil) {
        let catalog = self.catalog
        scriptFactory = { source, context, resources in
            let resolver = sourceRoot.map { UISceneResources(rootURL: $0) } ?? resources
            let url = try resolver.resolve(source.path)
            let sources = try AdaScriptUISource.sources(at: url)
            let identifier = try AdaScriptUISource.identifier(in: sources, requested: source.identifier)
            if source.inputs.isEmpty {
                return AnyView(try AdaScriptView(sources: sources, identifier: identifier, catalog: catalog))
            }
            let parameters = source.inputs.keys.sorted()
                .compactMap { name in
                    source.inputs[name].map { UIParameter(name, type: $0.type, defaultValue: $0, isBinding: true) }
                }
            let exported = AdaScriptUIExport(
                source: source.path,
                identifier: identifier,
                signature: .init(id: "Source." + identifier, name: identifier, parameters: parameters)
            )
            let catalog = try catalog.adding(script: exported, sources: sources)
            let node = UINodeDescription(
                type: exported.signature.id,
                arguments: Dictionary(uniqueKeysWithValues: parameters.map { ($0.name, UIArgument(binding: $0.name)) })
            )
            return AnyView(UISceneView(session: try UISceneInstance(document: .init(root: node), context: context, catalog: catalog)))
        }
    }
}

extension UIComponent {
    @MainActor
    public init(
        script path: String,
        identifier: String? = nil,
        behaviour: Behaviour = .overlay,
        windowRef: WindowRef = .primary,
        resourceRoot: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    ) throws {
        self.init(source: .init(kind: .script, path: path, identifier: identifier ?? ""), behaviour: behaviour, windowRef: windowRef)
        let runtime = UIComponentRuntime(resourceRoot: resourceRoot)
        runtime.enableAdaScript()
        _ = try resolveView(runtime: runtime)
    }
}

public enum AdaScriptUISource {
    /// Loads a source file with sibling module sources, in deterministic order.
    public static func sources(at url: URL) throws -> [AdaScriptSource] {
        let directory = url.deletingLastPathComponent()
        let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "ada" }.sorted { $0.path < $1.path }
        guard urls.contains(url) else {
            throw UIDiagnostic("Missing AdaScript file: \(url.path)")
        }
        return try urls.map { AdaScriptSource(path: $0.path, source: try String(contentsOf: $0, encoding: .utf8)) }
    }

    public static func identifier(in sources: [AdaScriptSource], requested: String = "") throws -> String {
        let declarations = try AdaScriptViewScanner.declarations(in: sources)
        if !requested.isEmpty {
            guard declarations.contains(where: { $0.identifier == requested }) else {
                throw UIDiagnostic("Unknown AdaScript View '\(requested)'.")
            }
            return requested
        }
        guard declarations.count == 1, let declaration = declarations.first else {
            throw UIDiagnostic("Specify a View identifier when a module contains multiple @view declarations.")
        }
        return declaration.identifier
    }
}
