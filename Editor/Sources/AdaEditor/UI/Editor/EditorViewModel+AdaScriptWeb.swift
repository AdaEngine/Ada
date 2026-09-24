#if os(macOS)
    import AdaScriptCompilerCore
    import Foundation

    extension EditorViewModel {
        func runAdaScriptProjectOnWeb(_ settings: AdaProject, artifact: EditorAdaScriptProjectBuildArtifact, at projectURL: URL) {
            guard workspaceTask == nil else { return }
            stopAdaScriptWebServer()
            let title = "Run AdaScript on Web"
            let activityID = beginWorkspaceActivity(title: title, source: .build)
            workspaceStatus = .running(title)
            buildActivity = EditorBuildActivity(title: title)
            footer.setWorkspaceFooterTitle(workspaceStatus.title)
            appendOutput("Preparing the AdaScript Web Player…")

            workspaceTask = Task { [weak self] in
                guard let self else { return }
                do {
                    try Self.validateAdaScriptWebScene(artifact)
                    let template = try await prepareAdaScriptWebPlayerTemplate()
                    try Task.checkCancellation()
                    let runDirectory = FileManager.default.temporaryDirectory
                        .appendingPathComponent("AdaEditorWebRun-\(UUID().uuidString)", isDirectory: true)
                    do {
                        try AdaWebPlayerBundle.assemble(template: template, project: projectURL, output: runDirectory)
                        try Task.checkCancellation()
                        let plugins = try EditorAdaScriptRuntimePluginResolver.resolve(settings.runtime.plugins)
                        let room: EditorCloudValue?
                        let usesMultiplayer = plugins.contains(.multiplayer)
                        if usesMultiplayer, EditorCloudAccount.shared.accountID != nil {
                            do {
                                room = try await EditorCloudAccount.shared.createMultiplayerRoom()
                            } catch {
                                room = nil
                                appendOutput("New Cloud room unavailable: \(error.localizedDescription). You can join a room or play solo.")
                            }
                        } else {
                            room = nil
                        }
                        try Task.checkCancellation()
                        try await startAdaScriptWebServer(directory: runDirectory, room: room, usesMultiplayer: usesMultiplayer)
                        let address = "http://127.0.0.1:8080"
                        guard let url = URL(string: address), externalURLOpener(url) else {
                            throw AdaScriptWebRunError.browserUnavailable
                        }
                        adaScriptWebRunDirectory = runDirectory
                        let roomCode = room?["joinCode"].string
                        workspaceStatus = .running(roomCode.map { "AdaScript Web · Room \($0)" } ?? "AdaScript Web")
                        footer.setWorkspaceFooterTitle(workspaceStatus.title)
                        appendOutput("AdaScript Web Player is ready at \(url.absoluteString).")
                        if let roomCode { appendOutput("Room code: \(roomCode)") }
                        buildActivity?.finish(succeeded: true)
                        finishWorkspaceActivity(activityID, succeeded: true)
                    } catch {
                        stopAdaScriptWebServer()
                        try? FileManager.default.removeItem(at: runDirectory)
                        throw error
                    }
                } catch is CancellationError {
                    workspaceStatus = .cancelled
                    footer.setWorkspaceFooterTitle(workspaceStatus.title)
                    buildActivity?.finish(succeeded: false)
                    finishWorkspaceActivity(activityID, succeeded: false, detail: "Cancelled")
                } catch {
                    workspaceStatus = .failed(error.localizedDescription)
                    footer.setWorkspaceFooterTitle(workspaceStatus.title)
                    appendOutput("AdaScript Web run failed: \(error.localizedDescription)")
                    buildActivity?.finish(succeeded: false)
                    finishWorkspaceActivity(activityID, succeeded: false, detail: error.localizedDescription)
                }
                workspaceTask = nil
                adaScriptWebExportRunner = nil
            }
        }

        private static func validateAdaScriptWebScene(_ artifact: EditorAdaScriptProjectBuildArtifact) throws {
            if artifact.entry.scene == nil {
                guard artifact.entry.view != nil else { throw AdaScriptWebRunError.entrySceneRequired }
                return
            }
            guard let scene = artifact.sceneModel else {
                throw AdaScriptWebRunError.entrySceneRequired
            }
            let supported: Set<String> = ["AdaTransform.Transform", "AdaRender.Visibility", "AdaTilemap.TileMapComponent"]
            if let unsupported = scene.entities.flatMap({ $0.components.keys }).first(where: { !supported.contains($0) }) {
                throw AdaScriptWebRunError.unsupportedSceneComponent(unsupported)
            }
        }

        func stopAdaScriptWebServer() {
            if let server = adaScriptWebServer, server.isRunning {
                server.terminate()
            }
            adaScriptWebServer = nil
            if let runDirectory = adaScriptWebRunDirectory {
                try? FileManager.default.removeItem(at: runDirectory)
            }
            adaScriptWebRunDirectory = nil
        }

        private func prepareAdaScriptWebPlayerTemplate() async throws -> URL {
            let bundled = Bundle.module.resourceURL?.appendingPathComponent("Assets/WebPlayerTemplate", isDirectory: true)
            if let bundled, Self.hasCurrentWebPlayerTemplate(at: bundled) {
                return bundled
            }
            let cacheBase = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            let cache = cacheBase.appendingPathComponent("AdaEditor/WebPlayer", isDirectory: true)
            let template = cache.appendingPathComponent("template", isDirectory: true)
            if Self.hasCurrentWebPlayerTemplate(at: template) {
                return template
            }
            try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
            let engineRoot = Self.adaEngineRootForWebPlayer
            guard FileManager.default.fileExists(atPath: engineRoot.appendingPathComponent("Package.swift").path) else {
                throw AdaScriptWebRunError.webPlayerSourceUnavailable
            }
            let swiftExecutable = ProcessInfo.processInfo.environment["ADA_WEB_SWIFT_EXECUTABLE"]
                ?? FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Library/Developer/Toolchains/swift-6.3.2-RELEASE.xctoolchain/usr/bin/swift").path
            guard FileManager.default.isExecutableFile(atPath: swiftExecutable) else {
                throw AdaScriptWebRunError.swiftToolchainUnavailable
            }
            let swiftSDK = ProcessInfo.processInfo.environment["ADA_WEB_SWIFT_SDK"] ?? "swift-6.3.2-RELEASE_wasm"
            let arguments = [
                "package", "--disable-sandbox",
                "--scratch-path", cache.appendingPathComponent("host-build").path,
                "--allow-writing-to-package-directory", "--allow-network-connections", "all",
                "export-web", "--product", "AdaWebPlayer", "--output", template.path,
                "--scratch-path", cache.appendingPathComponent("wasm-build").path,
                "--swift-sdk", swiftSDK,
            ]
            let runner = EditorProcessRunner()
            adaScriptWebExportRunner = runner
            let result = await runner.run(EditorProcessCommand(
                executablePath: swiftExecutable,
                arguments: arguments,
                workingDirectory: engineRoot,
                environment: [
                    "ADAENGINE_WEB_EXPORT": "1",
                    "BUILD_WASM": "1",
                    "PATH": URL(fileURLWithPath: swiftExecutable).deletingLastPathComponent().path + ":"
                        + (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"),
                ]
            )) { [weak self] event in
                await MainActor.run { self?.appendOutputBlock(event.text) }
            }
            try Task.checkCancellation()
            guard result.succeeded, Self.hasCurrentWebPlayerTemplate(at: template) else {
                throw AdaScriptWebRunError.exportFailed(String(result.combinedOutput.suffix(2_000)))
            }
            return template
        }

        private static var adaEngineRootForWebPlayer: URL {
            URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent() // Editor UI
                .deletingLastPathComponent() // UI
                .deletingLastPathComponent() // AdaEditor
                .deletingLastPathComponent() // Sources
                .deletingLastPathComponent() // Editor
                .deletingLastPathComponent() // AdaEngine
                .standardizedFileURL
        }

        private static func hasCurrentWebPlayerTemplate(at url: URL) -> Bool {
            guard
                let data = try? Data(contentsOf: url.appendingPathComponent("ada-web-player.json")),
                let descriptor = try? JSONDecoder().decode(AdaScriptWebPlayerDescriptor.self, from: data)
            else { return false }
            let requiredFiles = [
                "AdaWebPlayer.wasm", "index.html", "main.js", "runtime.mjs",
                "bridge-js.js", "browser-wasi-shim/dist/index.js",
                "ada-resource-manifest.json", "ada-web-manifest.json", "package.json", "player-lobby.js",
            ]
            return descriptor.runtimeAPI >= 3 && descriptor.profile == "universal"
                && requiredFiles.allSatisfy { FileManager.default.fileExists(atPath: url.appendingPathComponent($0).path) }
        }

        private func startAdaScriptWebServer(directory: URL, room: EditorCloudValue?, usesMultiplayer: Bool) async throws {
            let server = Process()
            server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            let apiOrigin = EditorCloudAccount.shared.server
            if usesMultiplayer, URL(string: apiOrigin)?.scheme == "https" {
                guard let script = Bundle.module.url(forResource: "player-server", withExtension: "py", subdirectory: "Assets/Runtime") else {
                    throw AdaScriptWebRunError.serverUnavailable
                }
                server.arguments = [script.path, "--directory", directory.path, "--api-origin", apiOrigin, "--port", "8080"]
                if let room {
                    guard let sessionJSON = String(data: try JSONEncoder().encode(room), encoding: .utf8) else {
                        throw AdaScriptWebRunError.serverUnavailable
                    }
                    server.environment = ProcessInfo.processInfo.environment.merging(["ADA_WEB_HOST_SESSION": sessionJSON]) { _, new in new }
                }
            } else {
                server.arguments = ["-m", "http.server", "8080", "--bind", "127.0.0.1", "--directory", directory.path]
            }
            server.standardOutput = FileHandle.nullDevice
            server.standardError = FileHandle.nullDevice
            try server.run()
            adaScriptWebServer = server

            guard let probe = URL(string: "http://127.0.0.1:8080/index.html") else {
                throw AdaScriptWebRunError.serverUnavailable
            }
            for _ in 0..<30 {
                try Task.checkCancellation()
                if !server.isRunning { break }
                if let (_, response) = try? await URLSession.shared.data(from: probe),
                    (response as? HTTPURLResponse)?.statusCode == 200 {
                    return
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            throw AdaScriptWebRunError.serverUnavailable
        }
    }

    private struct AdaScriptWebPlayerDescriptor: Decodable {
        let runtimeAPI: Int
        let profile: String
    }

    private enum AdaScriptWebRunError: LocalizedError {
        case browserUnavailable
        case entrySceneRequired
        case exportFailed(String)
        case serverUnavailable
        case swiftToolchainUnavailable
        case unsupportedSceneComponent(String)
        case webPlayerSourceUnavailable

        var errorDescription: String? {
            switch self {
            case .browserUnavailable: "The Web Player is ready, but the browser could not be opened."
            case .entrySceneRequired: "Set runtime.entry.scene before running this AdaScript project on Web."
            case let .exportFailed(detail): "Web Player export failed: \(detail)"
            case .serverUnavailable: "The Web Player server could not start on 127.0.0.1:8080."
            case .swiftToolchainUnavailable: "Swift 6.3.2 WebAssembly toolchain is unavailable. Install it or set ADA_WEB_SWIFT_EXECUTABLE."
            case let .unsupportedSceneComponent(name): "The Web Player cannot load scene component \(name) yet."
            case .webPlayerSourceUnavailable: "The AdaEngine Web Player source package is not available to this editor build."
            }
        }
    }
#endif
