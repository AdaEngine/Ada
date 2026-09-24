import AdaRender
import AdaScriptCompilerCore
import AdaUI
import Foundation

extension UIComponentRuntime {
    /// Installs the optional AdaScript source provider in this host's UI runtime.
    @MainActor
    public func enableAdaScript(sourceRoot _: URL? = nil) {
        scriptFactory = { _, _, _ in
            throw UIDiagnostic("AdaUI views in AdaScript are temporarily unavailable.")
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
        _ = resourceRoot
        throw UIDiagnostic("AdaUI views in AdaScript are temporarily unavailable.")
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
