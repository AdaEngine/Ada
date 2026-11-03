import Foundation

struct EditorAgentRegistry: Codable, Sendable {
    var version: String
    var agents: [EditorRegistryAgent]
}

struct EditorRegistryAgent: Codable, Identifiable, Equatable, Sendable {
    struct Package: Codable, Equatable, Sendable {
        var package: String
        var args: [String]?
        var env: [String: String]?
    }
    struct Binary: Codable, Equatable, Sendable {
        var archive: String
        var cmd: String
        var args: [String]?
        var env: [String: String]?
        var sha256: String?
    }
    struct Distribution: Codable, Equatable, Sendable {
        var npx: Package?
        var uvx: Package?
        var binary: [String: Binary]?
    }
    var id: String
    var name: String
    var version: String
    var description: String
    var repository: String?
    var website: String?
    var distribution: Distribution
    var icon: String?

    static var platform: String {
        #if os(macOS) && arch(arm64)
            "darwin-aarch64"
        #elseif os(macOS)
            "darwin-x86_64"
        #elseif os(Windows) && arch(arm64)
            "windows-aarch64"
        #elseif os(Windows)
            "windows-x86_64"
        #else
            "unsupported"
        #endif
    }
}

struct EditorInstalledAgent: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var name: String
    var version: String
    var target: AdaProjectAgentTarget
    var managedDirectory: String?
    var icon: String?
}

struct EditorDiscoveredAgent: Identifiable, Equatable, Sendable {
    var id: String
    var name: String
    var path: String
    // A regular Codex/Claude CLI is only a recommendation, never an ACP target.
    var target: AdaProjectAgentTarget?
}

enum EditorAgentDiscovery {
    static var pathSeparator: String {
        #if os(Windows)
        ";"
        #else
        ":"
        #endif
    }

    static func searchPaths(environment: [String: String], home: URL, fileManager: FileManager = .default) -> [String] {
        #if os(Windows)
        var paths = (EditorHostTools.environmentValue("PATH", in: environment) ?? "").components(separatedBy: ";")
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
            .filter { EditorHostTools.isAbsolutePath($0) }
        paths += [".local/bin", ".bun/bin", ".volta/bin", ".cargo/bin", "AppData/Roaming/npm"].map { home.appendingPathComponent($0).path }
        let local = EditorHostTools.environmentValue("LOCALAPPDATA", in: environment).map { URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent("AppData/Local")
        paths += ["Programs/nodejs", "Sloppy/bin"].map { local.appendingPathComponent($0).path }
        let codex = local.appendingPathComponent("OpenAI/Codex/bin")
        let versions = (try? fileManager.contentsOfDirectory(at: codex, includingPropertiesForKeys: nil)) ?? []
        paths += versions.compactMap { version -> (path: String, modified: Date)? in
            let binary = version.appendingPathComponent("codex.exe")
            guard fileManager.isExecutableFile(atPath: binary.path),
                  let values = try? binary.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey]),
                  values.isRegularFile == true else { return nil }
            return (version.path, values.contentModificationDate ?? .distantPast)
        }.sorted { lhs, rhs in
            lhs.modified == rhs.modified ? lhs.path < rhs.path : lhs.modified > rhs.modified
        }.map(\.path)
        paths.append(codex.path)
        if let programs = EditorHostTools.environmentValue("ProgramFiles", in: environment) {
            paths.append(URL(fileURLWithPath: programs).appendingPathComponent("nodejs").path)
        }
        var seen = Set<String>()
        return paths.filter { seen.insert($0.lowercased()).inserted }
        #else
        var paths = (environment["PATH"] ?? "").components(separatedBy: ":").filter { $0.hasPrefix("/") }
        paths += ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        paths += [".local/bin", ".npm-global/bin", ".bun/bin", ".volta/bin", ".cargo/bin", ".opencode/bin"]
            .map {
                home.appendingPathComponent($0).path
            }
        paths.append(home.appendingPathComponent("Library/Application Support/Sloppy/Backend/current/bin").path)
        let nvm = home.appendingPathComponent(".nvm/versions/node")
        let versions = (try? fileManager.contentsOfDirectory(atPath: nvm.path)) ?? []
        paths += versions.sorted { $0.compare($1, options: .numeric) == .orderedDescending }
            .map { nvm.appendingPathComponent($0).appendingPathComponent("bin").path }
        paths += ["/Applications/Codex.app/Contents/Resources", home.appendingPathComponent("Applications/Codex.app/Contents/Resources").path]
        var seen = Set<String>()
        return paths.filter { seen.insert($0).inserted }
        #endif
    }

    static func executable(_ name: String, paths: [String], fileManager: FileManager = .default) -> String? {
        for directory in paths {
            #if os(Windows)
            let names = URL(fileURLWithPath: name).pathExtension.isEmpty ? [name + ".exe", name + ".com", name + ".cmd", name + ".bat", name] : [name]
            #else
            let names = [name]
            #endif
            for filename in names {
                let path = URL(fileURLWithPath: directory).appendingPathComponent(filename).path
                var isDirectory: ObjCBool = false
                if fileManager.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue,
                    fileManager.isExecutableFile(atPath: path) { return path }
            }
        }
        return nil
    }

    static func discover(paths: [String]) -> [EditorDiscoveredAgent] {
        let candidates: [(String, String, [(String, [String]?)])] = [
            ("codex-acp", "Codex", [("codex-acp", []), ("codex", nil)]),
            ("claude-acp", "Claude Agent", [("claude-agent-acp", []), ("claude-code-acp", []), ("claude", nil)]),
            ("gemini", "Gemini CLI", [("gemini", ["--acp"])]),
            ("opencode", "OpenCode", [("opencode", ["acp"])]),
            ("github-copilot-cli", "GitHub Copilot", [("copilot", ["--acp"])]),
            ("sloppy-acp", "Sloppy", [("sloppy", ["acp", "serve"]), ("sloppy-acp", [])]),
        ]
        return candidates.compactMap { id, name, commands in
            for (command, arguments) in commands {
                if let path = executable(command, paths: paths) {
                    return EditorDiscoveredAgent(
                        id: id,
                        name: name,
                        path: path,
                        target: arguments.map {
                            AdaProjectAgentTarget(command: path, arguments: $0, environment: ["PATH": paths.joined(separator: pathSeparator)])
                        }
                    )
                }
            }
            return nil
        }
    }
}
