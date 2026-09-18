import Foundation

/// Assembles a static web directory using an already compiled player. Uses Foundation only, including on iPadOS.
/// The caller may ZIP the resulting directory with index.html at the archive root.
public enum AdaWebPlayerBundle {
    public static func assemble(template: URL, project directory: URL, output: URL) throws {
        let fileManager = FileManager.default
        let project = try AdaWebPlayerProject.load(at: directory)
        let sources = try project.loadSources(at: directory)
        guard
            try AdaScriptSchemaParser.parse(sources: sources).isEmpty,
            try AdaScriptSchemaParser.parseSystemCapabilities(sources: sources).isEmpty
        else {
            throw AdaWebPlayerProjectError.invalid("This Web Player profile supports views without ECS systems or custom native data.")
        }
        guard try AdaScriptSchemaParser.parseViews(sources: sources).contains(where: { $0.id == project.entryView }) else {
            throw AdaWebPlayerProjectError.invalid("Entry view '\(project.entryView)' was not found.")
        }
        let descriptor = try JSONDecoder()
            .decode(
                PlayerDescriptor.self,
                from: Data(contentsOf: template.appendingPathComponent("ada-web-player.json"))
            )
        guard descriptor.runtimeAPI >= project.runtimeAPI, descriptor.profile == "views" else {
            throw AdaWebPlayerProjectError.invalid("The player template is incompatible with this project's runtime API or profile.")
        }
        for path in ["index.html", "main.js", "AdaWebPlayer.wasm", "runtime.mjs", "bridge-js.js", "browser-wasi-shim/dist/index.js"] {
            guard fileManager.fileExists(atPath: template.appendingPathComponent(path).path) else {
                throw AdaWebPlayerProjectError.invalid("Incomplete Web Player template: missing \(path).")
            }
        }
        var resources = try JSONDecoder()
            .decode(
                [ResourceEntry].self,
                from: Data(contentsOf: template.appendingPathComponent("ada-resource-manifest.json"))
            )
        let templateRoot = template.resolvingSymlinksInPath().standardizedFileURL
        for resource in resources {
            let relativePath = resource.url.removingPercentEncoding ?? resource.url
            let file = templateRoot.appendingPathComponent(relativePath).resolvingSymlinksInPath().standardizedFileURL
            guard
                file.path.hasPrefix(templateRoot.path + "/"),
                (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            else {
                throw AdaWebPlayerProjectError.invalid("Missing or invalid player resource: \(resource.url).")
            }
        }
        guard
            !resources.contains(where: { $0.path == "game" || $0.path.hasPrefix("game/") || $0.path.hasPrefix("/game/") }),
            !fileManager.fileExists(atPath: template.appendingPathComponent("game").path)
        else {
            throw AdaWebPlayerProjectError.invalid("Expected a player template without embedded game content.")
        }
        guard !fileManager.fileExists(atPath: output.path) else {
            throw AdaWebPlayerProjectError.invalid("Export destination already exists: \(output.path).")
        }
        // copyItem fails on an existing destination; never overwrite a user's existing export.
        try fileManager.copyItem(at: template, to: output)
        var complete = false
        defer {
            if !complete {
                try? fileManager.removeItem(at: output)
            }
        }
        let game = output.appendingPathComponent("game", isDirectory: true)
        try fileManager.createDirectory(at: game, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(project).write(to: game.appendingPathComponent("project.json"))
        resources.append(ResourceEntry(path: "game/project.json", url: "game/project.json"))
        for source in sources {
            let destination = game.appendingPathComponent(source.path)
            try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try source.source.write(to: destination, atomically: true, encoding: .utf8)
            // Encode URL-sensitive characters while keeping the WASI path exactly equal to the source path.
            let path = "game/\(source.path)"
            let url = path.split(separator: "/")
                .map {
                    String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "?#%"))) ?? String($0)
                }
                .joined(separator: "/")
            resources.append(ResourceEntry(path: path, url: url))
        }
        for asset in project.assets ?? [] {
            let source = try project.resourceURL(asset.path, at: directory)
            let destination = game.appendingPathComponent(asset.path)
            try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileManager.copyItem(at: source, to: destination)
            // Audio is fetched on demand by Web Audio, not duplicated in WASI memory at startup.
            if asset.kind != .audio && asset.kind != .license {
                let path = "game/\(asset.path)"
                let url = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "?#%"))) ?? path
                resources.append(ResourceEntry(path: path, url: url))
            }
        }
        try encoder.encode(resources.sorted { $0.path < $1.path }).write(to: output.appendingPathComponent("ada-resource-manifest.json"))
        complete = true
    }

    private struct PlayerDescriptor: Decodable {
        let runtimeAPI: Int
        let profile: String
    }

    private struct ResourceEntry: Codable {
        let path: String
        let url: String
    }
}
