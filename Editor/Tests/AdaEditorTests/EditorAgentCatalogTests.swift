@_spi(AdaEngine) import AdaEngine
@_spi(Internal) import AdaUI
import Foundation
import Math
import Testing

@testable import AdaEditor

#if os(macOS)
    import ACP
    import ACPModel
#endif

@Suite("Editor agent catalog")
struct EditorAgentCatalogTests {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("AgentCatalog-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func executable(_ name: String, at root: URL) throws -> URL {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\nexit 0\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    @Test("discovers CLI paths but requires adapters for Codex and Claude")
    func discovery() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try executable("codex", at: root)
        _ = try executable("claude", at: root)
        _ = try executable("gemini", at: root)
        var found = EditorAgentDiscovery.discover(paths: [root.path])
        #expect(found.count == 3)
        #expect(found.first { $0.id == "codex-acp" }?.target == nil)
        #expect(found.first { $0.id == "claude-acp" }?.target == nil)
        #expect(found.first { $0.id == "gemini" }?.target?.arguments == ["--acp"])
        let adapter = try executable("codex-acp", at: root)
        found = EditorAgentDiscovery.discover(paths: [root.path])
        #expect(found.first { $0.id == "codex-acp" }?.target?.command == adapter.path)
    }

    @Test("discovers Sloppy's built-in ACP server before a legacy adapter")
    func sloppyDiscovery() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sloppy = try executable("sloppy", at: root)
        _ = try executable("sloppy-acp", at: root)
        let found = try #require(EditorAgentDiscovery.discover(paths: [root.path]).first { $0.name == "Sloppy" })
        #expect(found.path == sloppy.path)
        #expect(found.target?.command == sloppy.path)
        #expect(found.target?.arguments == ["acp", "serve"])
        try FileManager.default.removeItem(at: sloppy)
        let fallback = try #require(EditorAgentDiscovery.discover(paths: [root.path]).first { $0.name == "Sloppy" })
        #expect(fallback.target?.arguments == [])
    }

    @Test("Sloppy invite sign-in accepts remote HTTPS and local HTTP servers")
    func sloppyInviteServer() throws {
        #expect(try EditorSloppyInviteService.serverURL("https://sloppy.example.com").host == "sloppy.example.com")
        #expect(try EditorSloppyInviteService.serverURL("http://localhost:25101").port == 25101)
        for invalid in ["http://sloppy.example.com", "https://user:password@sloppy.example.com", "https://sloppy.example.com/path"] {
            #expect(throws: EditorSloppyInviteError.self) { try EditorSloppyInviteService.serverURL(invalid) }
        }
    }

    @Test("invite option disappears when a local Sloppy ACP provider is available")
    @MainActor
    func sloppyInviteVisibility() {
        let catalog = EditorAgentCatalogViewModel()
        #expect(catalog.showsSloppyInvite)
        catalog.discovered = [EditorDiscoveredAgent(id: "sloppy-acp", name: "Sloppy", path: "/bin/sloppy")]
        #expect(!catalog.showsSloppyInvite)
    }

    #if os(macOS)
        @Test("enabling local Sloppy ACP keeps the rest of its configuration and file permissions")
        @MainActor
        func sloppyLocalACPSetup() throws {
            let sloppyTarget = AdaProjectAgentTarget(command: "/usr/local/bin/sloppy", arguments: ["acp", "serve"])
            let otherTarget = AdaProjectAgentTarget(command: "/usr/local/bin/opencode", arguments: ["acp"])
            #expect(EditorSloppyLocalSetup.isSloppyTarget(sloppyTarget) == true)
            #expect(EditorSloppyLocalSetup.isSloppyTarget(otherTarget) == false)
            let root = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let config = root.appendingPathComponent(".sloppy/sloppy.json")
            try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
            try """
            {"acp":{"server":{"enabled":false,"agentId":"","cwd":"/work"}},"models":[{"apiKey":"leave-me"}]}
            """.write(to: config, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: config.path)
            let agent = root.appendingPathComponent(".sloppy/agents/engineer")
            try FileManager.default.createDirectory(at: agent, withIntermediateDirectories: true)
            try "{}".write(to: agent.appendingPathComponent("agent.json"), atomically: true, encoding: .utf8)
            #expect(EditorSloppyLocalSetup.availableAgentIDs(home: root) == ["engineer"])
            try EditorSloppyLocalSetup.enableACP(at: config, agentID: "engineer")
            let object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: config)) as? [String: Any])
            let acp = try #require(object["acp"] as? [String: Any])
            let server = try #require(acp["server"] as? [String: Any])
            #expect(server["enabled"] as? Bool == true)
            #expect(server["agentId"] as? String == "engineer")
            #expect(server["cwd"] as? String == "/work")
            #expect(((object["models"] as? [[String: Any]])?.first)?["apiKey"] as? String == "leave-me")
            #expect(try FileManager.default.attributesOfItem(atPath: config.path)[.posixPermissions] as? Int == 0o600)
        }
    #endif

    @Test("GUI discovery includes user toolchains and ignores relative PATH entries")
    func searchPaths() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let binary = try executable(".nvm/versions/node/v24.1/bin/node", at: root)
        let paths = EditorAgentDiscovery.searchPaths(environment: ["PATH": ".::/usr/bin:/usr/bin"], home: root)
        #expect(EditorAgentDiscovery.executable("node", paths: [binary.deletingLastPathComponent().path]) == binary.path)
        #expect(paths.contains(binary.deletingLastPathComponent().path))
        #expect(paths.contains("/Applications/Codex.app/Contents/Resources"))
        #expect(paths.contains(root.appendingPathComponent("Library/Application Support/Sloppy/Backend/current/bin").path))
        #expect(!paths.contains("."))
        #expect(paths.count == Set(paths).count)
    }

    @Test("registry supports package and platform metadata and rejects duplicate IDs")
    func decodeRegistry() throws {
        let data = Data(
            """
            {"version":"1.0.0","agents":[{"id":"sample","name":"Sample","version":"1.0","description":"Agent",
            "distribution":{"npx":{"package":"@scope/agent@1.0","args":["--acp"],"env":{"A":"B"}},
            "binary":{"darwin-aarch64":{"archive":"https://example.com/a.zip","cmd":"./agent","sha256":"abc"}}}}]}
            """
            .utf8
        )
        let registry = try EditorAgentCatalogService.decodeRegistry(data)
        #expect(registry.agents.first?.distribution.npx?.env == ["A": "B"])
        var duplicate = registry
        duplicate.agents += registry.agents
        #expect(throws: EditorAgentCatalogError.self) {
            try EditorAgentCatalogService.decodeRegistry(JSONEncoder().encode(duplicate))
        }
    }

    @Test("local registration persists, deduplicates and removal preserves executables")
    func localPersistence() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let binary = try executable("opencode", at: root)
        let service = EditorAgentCatalogService(root: root.appendingPathComponent("catalog"), paths: [root.path])
        let local = try #require(await service.discover().first)
        let added = try await service.addLocal(local)
        _ = try await service.addLocal(local)
        let reloaded = EditorAgentCatalogService(root: root.appendingPathComponent("catalog"), paths: [])
        #expect(try await reloaded.installed() == [added])
        try await service.remove(added)
        #expect(try await reloaded.installed().isEmpty)
        #expect(FileManager.default.isExecutableFile(atPath: binary.path))
    }

    @Test("using an agent saves exact global arguments and preserves current project settings")
    @MainActor
    func useAgent() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        var project = ProjectSystem.defaultProject(projectName: "Catalog")
        project.ai.agent.permissionMode = .deny
        project.ai.agent.target.command = "/legacy"
        try ProjectSystem.saveProject(project, at: root)
        let viewModel = EditorAgentViewModel(project: EditorProjectReference(name: "Catalog", path: root.path), settings: EditorAgentSettingsStore())
        project.project.displayName = "Changed after opening"
        try ProjectSystem.saveProject(project, at: root)
        let target = AdaProjectAgentTarget(command: "/agent with spaces", arguments: ["a,b", "two words"], environment: ["VALUE": "one,two"])
        await viewModel.useCatalogAgent(EditorInstalledAgent(id: "sample", name: "Sample", version: "1", target: target))
        viewModel.saveAgentSettings()
        let saved = try ProjectSystem.loadProject(at: root)
        #expect(viewModel.settings.configuration.target == target)
        #expect(viewModel.settings.configuration.enabled)
        #expect(viewModel.settings.configuration.permissionMode == .deny)
        #expect(saved.ai.agent == project.ai.agent)
        #expect(saved.project.displayName == "Changed after opening")
        #expect(viewModel.activeSession != nil)
    }

    #if os(macOS)
        @Test("npm package parsing preserves scoped names and rejects unpinned or path packages")
        func npmPackageNames() throws {
            #expect(try EditorAgentCatalogService.npmPackageName("@agentclientprotocol/codex-acp@1.10.0") == "@agentclientprotocol/codex-acp")
            #expect(try EditorAgentCatalogService.npmPackageName("cline@3.0.61") == "cline")
            for invalid in ["codex-acp", "../../agent@1", "--config@1", "https://example.com/agent@1"] {
                #expect(throws: EditorAgentCatalogError.self) { try EditorAgentCatalogService.npmPackageName(invalid) }
            }
        }

        @Test("npm fallback pins the published version only for ETARGET", arguments: ["ETARGET", "EACCES"])
        func npmPublishedVersionFallback(errorCode: String) async throws {
            let root = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let npm = try executable("npm", at: root)
            _ = try executable("node", at: root)
            try """
            #!/bin/sh
            if [ "$1" = "view" ]; then
                printf '%s' '"1.0.0"'
                exit 0
            fi
            for argument in "$@"; do spec="$argument"; done
            if [ "$spec" = '@scope/agent@2.0.0' ]; then
                printf '%s' 'npm error code \(errorCode): No matching version found for @scope/agent@2.0.0.' >&2
                exit 1
            fi
            [ "$spec" = '@scope/agent@1.0.0' ] || exit 2
            /bin/mkdir -p "$3/node_modules/@scope/agent" "$3/node_modules/.bin"
            printf '%s' '{"bin":{"agent":"cli.js"}}' > "$3/node_modules/@scope/agent/package.json"
            printf '#!/bin/sh\nexit 0\n' > "$3/node_modules/.bin/agent"
            /bin/chmod +x "$3/node_modules/.bin/agent"
            """
            .write(to: npm, atomically: true, encoding: .utf8)
            let service = EditorAgentCatalogService(root: root.appendingPathComponent("catalog"), paths: [root.path])
            let item = EditorRegistryAgent(
                id: "agent",
                name: "Agent",
                version: "2.0.0",
                description: "",
                distribution: .init(npx: .init(package: "@scope/agent@2.0.0"))
            )
            if errorCode == "ETARGET" {
                let entry = try await service.install(item)
                #expect(entry.version == "1.0.0")
                #expect(try await service.installed() == [entry])
            } else {
                await #expect(throws: EditorAgentCatalogError.self) { try await service.install(item) }
                #expect(try await service.installed().isEmpty)
            }
        }

        @Test("archive validation rejects traversal, symlinks and hardlinks")
        func archiveValidation() throws {
            try EditorAgentCatalogService.validateArchive(names: "./bin/agent\n", details: "-rwxr-xr-x agent\n", command: "./bin/agent")
            for badPath in ["../outside", "/tmp/outside", "bin/../../outside"] {
                #expect(throws: EditorAgentCatalogError.self) {
                    try EditorAgentCatalogService.validateArchive(names: badPath, details: "-rwxr-xr-x", command: "agent")
                }
            }
            for link in ["lrwxr-xr-x agent -> /tmp", "hrwxr-xr-x agent link to /tmp"] {
                #expect(throws: EditorAgentCatalogError.self) {
                    try EditorAgentCatalogService.validateArchive(names: "agent", details: link, command: "agent")
                }
            }
        }

        @Test("catalog renders in the actual settings UI")
        @MainActor
        func settingsUI() async throws {
            if unsafe RenderEngine.shared == nil {
                unsafe RenderEngine.configurations.preferredBackend = .headless
                RenderWorldPlugin().setup(in: AppWorlds(main: World(name: "AgentCatalogUI")))
            }
            let root = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            try ProjectSystem.saveProject(ProjectSystem.defaultProject(projectName: "UI"), at: root)
            let agent = EditorAgentViewModel(project: EditorProjectReference(name: "UI", path: root.path), settings: EditorAgentSettingsStore(), service: FakeEditorAgentService())
            agent.catalog.installed = [EditorInstalledAgent(id: "sample", name: "Sample", version: "1", target: AdaProjectAgentTarget(command: "/sample"))]
            agent.catalog.discovered = [
                EditorDiscoveredAgent(
                    id: "local",
                    name: "Local",
                    path: "/usr/local/bin/local-agent",
                    target: AdaProjectAgentTarget(command: "/usr/local/bin/local-agent")
                )
            ]
            agent.catalog.agents = [
                EditorRegistryAgent(
                    id: "registry",
                    name: "Registry",
                    version: "1",
                    description: "Registry agent",
                    repository: nil,
                    website: nil,
                    distribution: EditorRegistryAgent.Distribution()
                )
            ]
            let container = UIContainerView(rootView: EditorAgentCatalogView(agent: agent, loadsCatalog: false))
            container.frame = Rect(x: 0, y: 0, width: 700, height: 600)
            container.bounds.size = container.frame.size
            container.layoutIfNeeded()
            let search = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.Agents.Search"))
            #expect(search.absoluteFrame.width > 0)
            #expect(search.absoluteFrame.height == 32)
            let refresh = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.Agents.Refresh"))
            let addLocal = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.Agents.AddLocal.local"))
            let install = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.Agents.Install.registry"))
            let sloppyInvite = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.Agents.SloppyInvite"))
            #expect(sloppyInvite.absoluteFrame.width > 0)
            for button in [refresh, addLocal, install] {
                #expect(button.absoluteFrame.height <= 32)
                #expect(button.absoluteFrame.width < 180)
                #expect(buttonContainsGlass(button))
            }
            _ = try container.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.Agents.Use.sample"))
            for _ in 0..<100 where !agent.settingsStatusMessage.contains("connected.") {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(agent.settings.configuration.target.command == "/sample")
            #expect(try ProjectSystem.loadProject(at: root).ai.agent.target.command == nil)
            #expect(agent.settingsStatusMessage.contains("connected."))
        }

        @Test("discovered CLI offers its matching adapter in the same row")
        @MainActor
        func discoveredAdapterUI() throws {
            if unsafe RenderEngine.shared == nil {
                unsafe RenderEngine.configurations.preferredBackend = .headless
                RenderWorldPlugin().setup(in: AppWorlds(main: World(name: "AgentAdapterUI")))
            }
            let agent = EditorAgentViewModel(project: nil, settings: EditorAgentSettingsStore())
            agent.catalog.discovered = [EditorDiscoveredAgent(id: "codex-acp", name: "Codex", path: "/bin/codex")]
            let adapter = EditorRegistryAgent(
                id: "codex-acp",
                name: "Codex",
                version: "1",
                description: "Adapter",
                distribution: .init()
            )
            agent.catalog.agents = [adapter]
            #expect(agent.catalog.adapter(for: agent.catalog.discovered[0]) == adapter)
            let container = UIContainerView(rootView: EditorAgentCatalogView(agent: agent, loadsCatalog: false))
            container.frame = Rect(x: 0, y: 0, width: 700, height: 600)
            container.bounds.size = container.frame.size
            container.layoutIfNeeded()
            let button = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.Agents.InstallAdapter.codex-acp"))
            #expect(button.absoluteFrame.width > 80)
            #expect(button.absoluteFrame.height <= 32)
        }

        @Test("adding a local agent registers, selects and connects without sending a prompt")
        @MainActor
        func addAndConnect() async throws {
            let root = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            try ProjectSystem.saveProject(ProjectSystem.defaultProject(projectName: "Connect"), at: root)
            _ = try executable("opencode", at: root)
            let service = EditorAgentCatalogService(root: root.appendingPathComponent("catalog"), paths: [root.path])
            let local = try #require(await service.discover().first)
            let catalog = EditorAgentCatalogViewModel(service: service)
            catalog.filter = .available
            let connection = FakeEditorAgentService()
            let agent = EditorAgentViewModel(
                project: EditorProjectReference(name: "Connect", path: root.path),
                settings: EditorAgentSettingsStore(),
                service: connection,
                catalog: catalog
            )
            await agent.connectCatalogAgent(local: local)
            let entry = try #require(try await service.installed().first)
            #expect(agent.settings.configuration.target == local.target)
            #expect(try ProjectSystem.loadProject(at: root).ai.agent.target.command == nil)
            #expect(agent.isCatalogAgentSelected(entry))
            #expect(catalog.filter == .all)
            #expect(agent.settingsStatusMessage.contains("connected."))
            #expect(!agent.isConnectingCatalogAgent)
            let request = try #require(await connection.recordedRequest())
            #expect(request.project.ai.agent.target == local.target)
            #expect(request.prompt.isEmpty)
        }

        @Test("connection failure is visible without claiming the agent is connected")
        @MainActor
        func connectionFailure() async throws {
            let root = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            try ProjectSystem.saveProject(ProjectSystem.defaultProject(projectName: "Failure"), at: root)
            let connection = FakeEditorAgentService(connectionError: .sessionUnavailable)
            let agent = EditorAgentViewModel(project: EditorProjectReference(name: "Failure", path: root.path), settings: EditorAgentSettingsStore(), service: connection)
            let entry = EditorInstalledAgent(id: "test", name: "Test", version: "1", target: .init(command: "/test"))
            await agent.connectCatalogAgent(installed: entry)
            #expect(agent.isCatalogAgentSelected(entry))
            #expect(agent.settingsStatusMessage.contains("connection failed"))
            #expect(agent.settingsStatusMessage.contains("ACP session is unavailable"))
            #expect(!agent.isConnectingCatalogAgent)
            #expect(agent.canConnectCatalogAgent)
        }

        @Test("failed adapter install preserves the current project agent")
        @MainActor
        func failedInstallKeepsSelection() async throws {
            let root = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            var project = ProjectSystem.defaultProject(projectName: "KeepAgent")
            project.ai.agent.target.command = "/existing-agent"
            try ProjectSystem.saveProject(project, at: root)
            let catalog = EditorAgentCatalogViewModel(service: EditorAgentCatalogService(root: root.appendingPathComponent("catalog"), paths: []))
            let agent = EditorAgentViewModel(
                project: EditorProjectReference(name: "KeepAgent", path: root.path),
                settings: EditorAgentSettingsStore(),
                service: FakeEditorAgentService(),
                catalog: catalog
            )
            let adapter = EditorRegistryAgent(id: "unavailable", name: "Unavailable", version: "1", description: "", distribution: .init())
            await agent.connectCatalogAgent(registry: adapter)
            #expect(try ProjectSystem.loadProject(at: root).ai.agent.target.command == "/existing-agent")
            #expect(catalog.installed.isEmpty)
            #expect(catalog.status.contains("no distribution"))
            #expect(!agent.isConnectingCatalogAgent)
        }

        private func buttonContainsGlass(_ node: UINodeSnapshot) -> Bool {
            node.nodeType.hasSuffix("GlassEffectViewNode") || node.children.contains(where: buttonContainsGlass)
        }

        @Test("live registry installs Codex and initializes ACP", .enabled(if: ProcessInfo.processInfo.environment["ADAEDITOR_ACP_LIVE_TEST"] == "1"))
        func liveInstall() async throws {
            let root = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let service = EditorAgentCatalogService(root: root)
            let agents = try await service.refresh()
            var codex = try #require(agents.first { $0.id == "codex-acp" })
            if let version = ProcessInfo.processInfo.environment["ADAEDITOR_ACP_TEST_CODEX_VERSION"] {
                codex.version = version
                codex.distribution.npx?.package = "@agentclientprotocol/codex-acp@\(version)"
            }
            let entry = try await service.install(codex)
            #expect(try await service.installed() == [entry])
            let client = Client()
            try await client.launch(
                agentPath: try #require(entry.target.command),
                arguments: entry.target.arguments,
                workingDirectory: root.path,
                environment: entry.target.environment
            )
            do {
                _ = try await client.initialize(capabilities: ClientCapabilities(fs: FileSystemCapabilities(readTextFile: false, writeTextFile: false), terminal: false), timeout: 30)
            } catch {
                await client.terminate()
                throw error
            }
            await client.terminate()
        }
    #endif
}
