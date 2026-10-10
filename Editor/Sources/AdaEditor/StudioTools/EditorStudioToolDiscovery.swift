import AdaScriptCompilerCore
import Foundation

struct EditorStudioToolDefinition {
    let schema: AdaScriptToolSchema
    let sources: [AdaScriptCompilerSource]
    let directory: URL
    var signature: String { sources.map { $0.path + "\n" + $0.source }.joined(separator: "\n") }
}

enum EditorStudioToolDiscovery {
    static func discover(at projectURL: URL, overrides: [String: String] = [:]) throws -> [EditorStudioToolDefinition] {
        let root = projectURL.resolvingSymlinksInPath().standardizedFileURL
        let tools = root.appendingPathComponent("Tools", isDirectory: true)
        guard FileManager.default.fileExists(atPath: tools.path) else {
            return []
        }
        guard tools.resolvingSymlinksInPath() == tools else { throw Failure("Tools must be a project-local directory.") }
        let folders = try FileManager.default.contentsOfDirectory(at: tools, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: .skipsHiddenFiles)
        var result: [EditorStudioToolDefinition] = []
        for folder in folders.sorted(by: { $0.path < $1.path }) {
            let properties = try folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard properties.isDirectory == true, properties.isSymbolicLink != true else { continue }
            guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isSymbolicLinkKey], options: .skipsHiddenFiles) else { continue }
            var sources: [AdaScriptCompilerSource] = []
            for case let file as URL in enumerator {
                if try file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
                    enumerator.skipDescendants()
                    continue
                }
                guard file.pathExtension.lowercased() == "ada" else { continue }
                let relative = String(file.path.dropFirst(root.path.count + 1))
                let local = String(file.path.dropFirst(folder.path.count + 1))
                sources.append(.init(path: local, source: try overrides[relative] ?? String(contentsOf: file, encoding: .utf8)))
            }
            sources.sort { $0.path < $1.path }
            for schema in try AdaScriptSchemaParser.parseTools(sources: sources) {
                result.append(.init(schema: schema, sources: sources, directory: folder))
            }
        }
        var ids = Set<String>()
        for definition in result where !ids.insert(definition.schema.id).inserted {
            throw Failure("Duplicate Studio tool id: \(definition.schema.id)")
        }
        return result
    }

    struct Failure: Error, LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}
