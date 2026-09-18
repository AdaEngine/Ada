import Foundation

#if os(macOS)
    import CryptoKit
#endif

struct EditorAgentCatalogError: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}

actor EditorAgentCatalogService {
    static let shared = EditorAgentCatalogService()
    static let registryAddress = "https://cdn.agentclientprotocol.com/registry/v1/latest/registry.json"
    let root: URL
    let paths: [String]
    private let runner: any EditorProcessRunning
    private let session: URLSession

    init(root: URL? = nil, paths: [String]? = nil, runner: any EditorProcessRunning = EditorProcessRunner(), session: URLSession = .shared) {
        let homeDirectory = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        self.root =
            root
            ?? homeDirectory
            .appendingPathComponent("Library/Application Support/AdaEditor/Agents")
        self.paths =
            paths
            ?? EditorAgentDiscovery.searchPaths(
                environment: ProcessInfo.processInfo.environment,
                home: homeDirectory
            )
        self.runner = runner
        self.session = session
    }

    func discover() -> [EditorDiscoveredAgent] {
        #if os(macOS)
            EditorAgentDiscovery.discover(paths: paths)
        #else
            []
        #endif
    }

    func installed() throws -> [EditorInstalledAgent] {
        let url = root.appendingPathComponent("installed.json")
        guard FileManager.default.fileExists(atPath: url.path) else {
            return []
        }
        return try JSONDecoder().decode([EditorInstalledAgent].self, from: Data(contentsOf: url))
    }

    func cachedRegistry() -> [EditorRegistryAgent] {
        guard
            let data = try? Data(contentsOf: root.appendingPathComponent("registry.json")),
            let registry = try? Self.decodeRegistry(data)
        else {
            return []
        }
        return registry.agents
    }

    static func decodeRegistry(_ data: Data) throws -> EditorAgentRegistry {
        let registry = try JSONDecoder().decode(EditorAgentRegistry.self, from: data)
        guard
            registry.version.hasPrefix("1."), Set(registry.agents.map(\.id)).count == registry.agents.count,
            registry.agents.allSatisfy({ validComponent($0.id) && validComponent($0.version) })
        else {
            throw EditorAgentCatalogError(message: "Unsupported or invalid ACP registry.")
        }
        return registry
    }

    func refresh() async throws -> [EditorRegistryAgent] {
        let data = try await download(Self.registryAddress, timeout: 20)
        let registry = try Self.decodeRegistry(data)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try data.write(to: root.appendingPathComponent("registry.json"), options: .atomic)
        return registry.agents
    }

    func addLocal(_ agent: EditorDiscoveredAgent) throws -> EditorInstalledAgent {
        guard let target = agent.target else {
            throw EditorAgentCatalogError(message: "Install the ACP adapter first.")
        }
        let entry = EditorInstalledAgent(id: agent.id, name: agent.name, version: "Local", target: target)
        try save(entry)
        return entry
    }

    func install(_ agent: EditorRegistryAgent) async throws -> EditorInstalledAgent {
        #if os(macOS)
            guard Self.validComponent(agent.id), Self.validComponent(agent.version) else {
                throw EditorAgentCatalogError(message: "Invalid agent identity.")
            }
            // A fresh directory makes failed installs disposable and leaves existing versions usable.
            let directory = root.appendingPathComponent("\(agent.id)-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            do {
                let target: AdaProjectAgentTarget
                var installedVersion = agent.version
                if let package = agent.distribution.npx {
                    let installation = try await installNPM(package, in: directory)
                    target = installation.target
                    installedVersion = installation.version
                } else if let package = agent.distribution.uvx {
                    target = try await installUV(package, in: directory)
                } else if let binary = agent.distribution.binary?[EditorRegistryAgent.platform] {
                    target = try await installBinary(binary, in: directory)
                } else {
                    throw EditorAgentCatalogError(message: "This agent has no distribution for this Mac.")
                }
                let entry = EditorInstalledAgent(id: agent.id, name: agent.name, version: installedVersion, target: target, managedDirectory: directory.path)
                try save(entry)
                return entry
            } catch {
                try? FileManager.default.removeItem(at: directory)
                throw error
            }
        #else
            throw EditorAgentCatalogError(message: "Local ACP agents require macOS.")
        #endif
    }

    func remove(_ entry: EditorInstalledAgent) throws {
        var entries = try installed()
        entries.removeAll { $0.id == entry.id }
        // Unregister only: other projects can still refer to a managed executable.
        // Never delete an externally discovered CLI or another project's running agent.
        try writeInstalled(entries)
    }

    private func save(_ entry: EditorInstalledAgent) throws {
        var entries = try installed()
        entries.removeAll { $0.id == entry.id }
        entries.append(entry)
        try writeInstalled(entries)
    }

    private func writeInstalled(_ entries: [EditorInstalledAgent]) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(entries).write(to: root.appendingPathComponent("installed.json"), options: .atomic)
    }

    private func download(_ address: String, timeout: TimeInterval = 120) async throws -> Data {
        guard let url = URL(string: address), url.scheme == "https" else {
            throw EditorAgentCatalogError(message: "Expected an HTTPS download URL.")
        }
        let (data, response) = try await session.data(for: URLRequest(url: url, timeoutInterval: timeout))
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode), response.url?.scheme == "https" else {
            throw EditorAgentCatalogError(message: "The agent download failed. Check your connection and retry.")
        }
        return data
    }

    private static func validComponent(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-._+".contains($0)) }
    }

    #if os(macOS)
        private func run(_ executable: String, _ arguments: [String], in directory: URL, environment: [String: String] = [:]) async throws -> String {
            let timeout = Task {
                do { try await Task.sleep(for: .seconds(300)) } catch { return }
                await runner.cancelAll()
            }
            defer { timeout.cancel() }
            let result = await runner.run(
                EditorProcessCommand(
                    executablePath: executable,
                    arguments: arguments,
                    workingDirectory: directory,
                    environment: ["PATH": paths.joined(separator: ":")].merging(environment) { _, new in new }
                )
            )
            guard result.succeeded else {
                throw EditorAgentCatalogError(message: "Installation failed: \(result.combinedOutput.suffix(2000))")
            }
            return result.standardOutput
        }

        static func npmPackageName(_ spec: String) throws -> String {
            guard let separator = spec.lastIndex(of: "@"), separator != spec.startIndex else {
                throw EditorAgentCatalogError(message: "The registry must pin the npm package version.")
            }
            let name = String(spec[..<separator])
            let version = String(spec[spec.index(after: separator)...])
            let parts = name.split(separator: "/", omittingEmptySubsequences: false)
            let validName =
                name.hasPrefix("@")
                ? parts.count == 2 && validComponent(String(parts[0].dropFirst())) && validComponent(String(parts[1]))
                : parts.count == 1 && validComponent(name)
            guard validName, validComponent(version), !name.hasPrefix("-") else {
                throw EditorAgentCatalogError(message: "Invalid npm package.")
            }
            return name
        }

        static func publishedNPMSpec(packageName: String, metadata: String) throws -> String {
            let version = try JSONDecoder().decode(String.self, from: Data(metadata.utf8))
            guard version.first?.isNumber == true else {
                throw EditorAgentCatalogError(message: "npm did not return a published package version.")
            }
            let spec = "\(packageName)@\(version)"
            guard try npmPackageName(spec) == packageName else {
                throw EditorAgentCatalogError(message: "npm returned an invalid package version.")
            }
            return spec
        }

        private func installNPM(
            _ package: EditorRegistryAgent.Package,
            in directory: URL
        ) async throws -> (target: AdaProjectAgentTarget, version: String) {
            guard let npm = EditorAgentDiscovery.executable("npm", paths: paths), EditorAgentDiscovery.executable("node", paths: paths) != nil else {
                throw EditorAgentCatalogError(message: "Install Node.js (which includes npm), then Refresh to install this agent.")
            }
            let packageName = try Self.npmPackageName(package.package)
            var installedSpec = package.package
            do {
                _ = try await run(npm, ["install", "--prefix", directory.path, "--no-audit", "--no-fund", "--", installedSpec], in: directory)
            } catch let error as EditorAgentCatalogError {
                guard
                    error.message.contains("ETARGET"),
                    error.message.contains("No matching version found for \(package.package).")
                else {
                    throw error
                }
                // The ACP registry can lead npm publication. Resolve the same package's
                // stable release, then pin that exact version rather than launching `latest`.
                let metadata = try await run(npm, ["view", packageName, "dist-tags.latest", "--json"], in: directory)
                installedSpec = try Self.publishedNPMSpec(packageName: packageName, metadata: metadata)
                guard installedSpec != package.package else {
                    throw error
                }
                _ = try await run(npm, ["install", "--prefix", directory.path, "--no-audit", "--no-fund", "--", installedSpec], in: directory)
            }
            let installedVersion = String(installedSpec.split(separator: "@").last ?? "")
            let manifestURL = directory.appendingPathComponent("node_modules/\(packageName)/package.json")
            let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any]
            let binaryNames: [String]
            if let bins = manifest?["bin"] as? [String: String] {
                binaryNames = bins.keys.sorted()
            } else if manifest?["bin"] is String {
                binaryNames = [String(packageName.split(separator: "/").last ?? "")]
            } else {
                binaryNames = []
            }
            let preferredName = String(packageName.split(separator: "/").last ?? "")
            guard
                let name = binaryNames.contains(preferredName) ? preferredName : (binaryNames.count == 1 ? binaryNames.first : nil),
                Self.validComponent(name)
            else {
                throw EditorAgentCatalogError(message: "The package exposes multiple or no executables. Configure it manually.")
            }
            return (try executableTarget(directory.appendingPathComponent("node_modules/.bin/\(name)"), args: package.args, env: package.env), installedVersion)
        }

        private func installUV(_ package: EditorRegistryAgent.Package, in directory: URL) async throws -> AdaProjectAgentTarget {
            guard let uv = EditorAgentDiscovery.executable("uv", paths: paths) else {
                throw EditorAgentCatalogError(message: "Install uv, then Refresh to install this Python agent.")
            }
            guard !package.package.hasPrefix("-") else {
                throw EditorAgentCatalogError(message: "Invalid Python package.")
            }
            let bin = directory.appendingPathComponent("bin")
            _ = try await run(
                uv,
                ["tool", "install", "--", package.package],
                in: directory,
                environment: [
                    "UV_TOOL_DIR": directory.appendingPathComponent("tools").path, "UV_TOOL_BIN_DIR": bin.path,
                ]
            )
            let binaries = try FileManager.default.contentsOfDirectory(at: bin, includingPropertiesForKeys: nil)
            let packageName = package.package.components(separatedBy: "==")[0].components(separatedBy: "@")[0]
            guard let binary = binaries.first(where: { $0.lastPathComponent == packageName }) ?? (binaries.count == 1 ? binaries.first : nil) else {
                throw EditorAgentCatalogError(message: "The Python package exposes multiple or no executables. Configure it manually.")
            }
            return try executableTarget(binary, args: package.args, env: package.env)
        }

        private func installBinary(_ binary: EditorRegistryAgent.Binary, in directory: URL) async throws -> AdaProjectAgentTarget {
            let data = try await download(binary.archive)
            if let checksum = binary.sha256 {
                let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                guard actual == checksum.lowercased() else {
                    throw EditorAgentCatalogError(message: "Agent archive checksum mismatch.")
                }
            }
            let archive = directory.appendingPathComponent("download.archive")
            try data.write(to: archive)
            let names = try await run("/usr/bin/tar", ["-tf", archive.path], in: directory)
            let details = try await run("/usr/bin/tar", ["-tvf", archive.path], in: directory)
            try Self.validateArchive(names: names, details: details, command: binary.cmd)
            _ = try await run("/usr/bin/tar", ["-xf", archive.path, "--no-same-owner", "--no-same-permissions"], in: directory)
            try FileManager.default.removeItem(at: archive)
            let executable = directory.appendingPathComponent(binary.cmd).standardizedFileURL
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
            return try executableTarget(executable, args: binary.args, env: binary.env)
        }

        static func validateArchive(names: String, details: String, command: String) throws {
            func safe(_ path: String) -> Bool {
                !path.isEmpty && !path.hasPrefix("/") && !path.contains("\\") && !path.split(separator: "/").contains("..")
            }
            guard
                safe(command), names.split(separator: "\n").allSatisfy({ safe(String($0)) }),
                details.split(separator: "\n").allSatisfy({ $0.first == "-" || $0.first == "d" })
            else {
                throw EditorAgentCatalogError(message: "Unsafe archive paths or links. Install this agent manually.")
            }
        }

        private func executableTarget(_ url: URL, args: [String]?, env: [String: String]?) throws -> AdaProjectAgentTarget {
            guard FileManager.default.isExecutableFile(atPath: url.path) else {
                throw EditorAgentCatalogError(message: "Installed agent executable is missing.")
            }
            return AdaProjectAgentTarget(command: url.path, arguments: args ?? [], environment: ["PATH": paths.joined(separator: ":")].merging(env ?? [:]) { _, new in new })
        }
    #endif
}
