#if os(Windows)
import Foundation

/// Resolves native executables and npm shims without interpreting agent arguments
/// as cmd.exe source. Spaces, Unicode and shell metacharacters remain literal argv.
enum EditorWindowsAgentCommand {
    static func environment(_ overrides: [String: String], inheriting base: [String: String] = EditorBuildToolDiscovery.currentEnvironment()) -> [String: String] {
        let merged = EditorHostTools.mergedEnvironment(overrides, inheriting: base)
        let home = URL(fileURLWithPath: NSHomeDirectory())
        // Saved adapter PATHs can contain deleted Codex Desktop versions. Keep
        // explicit entries first, and include current host tools and app installs.
        let paths = EditorAgentDiscovery.searchPaths(environment: merged, home: home)
            + EditorAgentDiscovery.searchPaths(environment: base, home: home)
        var seen = Set<String>()
        let path = paths.filter { seen.insert($0.lowercased()).inserted }.joined(separator: ";")
        return EditorHostTools.mergedEnvironment(["PATH": path], inheriting: merged)
    }

    static func resolve(_ command: String, arguments: [String], environment: [String: String]) throws -> (executable: URL, arguments: [String]) {
        let paths = EditorAgentDiscovery.searchPaths(environment: environment, home: URL(fileURLWithPath: NSHomeDirectory()))
        let path = EditorHostTools.isAbsolutePath(command) ? command : EditorAgentDiscovery.executable(command, paths: paths)
        guard let path, FileManager.default.fileExists(atPath: path) else {
            throw EditorAgentCatalogError(message: "Agent executable was not found: \(command)")
        }
        let url = URL(fileURLWithPath: path)
        let ext = url.pathExtension.lowercased()
        if ["js", "cjs", "mjs"].contains(ext) {
            return try node(script: url, arguments: arguments, paths: [url.deletingLastPathComponent().path] + paths)
        }
        if ext == "cmd" || ext == "bat" {
            let directory = url.deletingLastPathComponent()
            let npm = directory.appendingPathComponent("node_modules/npm/bin/npm-cli.js")
            if url.deletingPathExtension().lastPathComponent.lowercased() == "npm", FileManager.default.fileExists(atPath: npm.path) {
                return try node(script: npm, arguments: arguments, paths: [directory.path] + paths)
            }
            let source = try String(contentsOf: url, encoding: .utf8)
            let expression = try NSRegularExpression(pattern: #"(?i)%(?:dp0%|~dp0)[\\/]?([^"\r\n]+\.(?:cjs|mjs|js))"#)
            for match in expression.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
                guard let range = Range(match.range(at: 1), in: source) else { continue }
                let script = directory.appendingPathComponent(String(source[range]).replacingOccurrences(of: "\\", with: "/")).standardizedFileURL
                if FileManager.default.fileExists(atPath: script.path) {
                    return try node(script: script, arguments: arguments, paths: [directory.path] + paths)
                }
            }
            if let executable = nativeNpmExecutable(in: source, relativeTo: directory) {
                return (executable, arguments)
            }
            throw EditorAgentCatalogError(message: "Select the agent's .exe or its Node.js entry point. This batch file is not an npm launcher: \(path)")
        }
        return (url, arguments)
    }

    private static func nativeNpmExecutable(in source: String, relativeTo directory: URL) -> URL? {
        // Native global npm shims forward argv directly to an exe in node_modules.
        let pattern = #"(?im)^[ \t]*@?"%dp0%[\\/](node_modules[\\/][^"%:\r\n]+\.exe)"[ \t]+%\*[ \t]*$"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)),
              let range = Range(match.range(at: 1), in: source) else { return nil }
        let relativePath = source[range].replacingOccurrences(of: "\\", with: "/")
        guard relativePath.split(separator: "/").allSatisfy({ $0 != "." && $0 != ".." }) else { return nil }
        let executable = directory.appendingPathComponent(relativePath).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: executable.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else { return nil }
        return executable
    }

    private static func node(script: URL, arguments: [String], paths: [String]) throws -> (executable: URL, arguments: [String]) {
        guard let node = EditorAgentDiscovery.executable("node", paths: paths) else {
            throw EditorAgentCatalogError(message: "Install Node.js, then Refresh to launch this agent.")
        }
        return (URL(fileURLWithPath: node), [script.path] + arguments)
    }
}
#endif
