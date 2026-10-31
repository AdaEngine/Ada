import Foundation

extension EditorViewModel {
    func exportAdaScriptNativeGame(web: Bool, launch: Bool = false) {
        #if (os(macOS) || os(Windows) || os(Linux)) && canImport(GravityAOT)
        #if !os(macOS)
        guard web else { appendOutput("macOS application packaging requires a macOS host."); return }
        #endif
        guard workspaceTask == nil, let projectURL else {
            return
        }
        guard workbench.saveAllDocuments() else {
            appendOutput("Export blocked: project documents could not be saved.")
            return
        }
        let title = web ? "Export AdaScript to Web" : "Export AdaScript to macOS"
        let activity = beginWorkspaceActivity(title: title, source: .build)
        workspaceStatus = .running(title)
        buildActivity = EditorBuildActivity(title: title)
        footer.setWorkspaceFooterTitle(title)
        let runner = EditorProcessRunner()
        adaScriptWebExportRunner = runner
        workspaceTask = Task { [weak self] in
            guard let self else {
                return
            }
            do {
                let settings = try ProjectSystem.loadProject(at: projectURL)
                let sdk = try EditorBuildSDK.locate()
                let toolchain = await SwiftToolchainLocator.locate()
                let buildSettings = EditorBuildExportConfiguration.load()
                #if os(Windows)
                let webSwift = ProcessInfo.processInfo.environment["ADA_WEB_SWIFT_EXECUTABLE"]
                    ?? buildSettings.swiftExecutable(for: .web) ?? ""
                #else
                let webSwift =
                    ProcessInfo.processInfo.environment["ADA_WEB_SWIFT_EXECUTABLE"]
                    ?? buildSettings.swiftExecutable(for: .web)
                    ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Developer/Toolchains/swift-6.3.2-RELEASE.xctoolchain/usr/bin/swift").path
                #endif
                let options = EditorAdaScriptNativeExportOptions(
                    destination: web ? .web : .macOS,
                    gravityRoot: sdk.compilerRoot,
                    engineRoot: sdk.engineRoot,
                    swiftExecutable: web ? webSwift : toolchain.swiftExecutablePath,
                    buildEnvironment: buildSettings.environment(for: web ? .web : .macOS),
                    swiftSDK: ProcessInfo.processInfo.environment["ADA_WEB_SWIFT_SDK"]
                        ?? buildSettings.values[EditorBuildPlatform.web.rawValue]?["ADA_WEB_SWIFT_SDK"] ?? "swift-6.3.2-RELEASE_wasm",
                    configuration: settings.build.configuration == "debug" ? .debug : .release
                )
                var output = projectURL.appendingPathComponent("Exports/\(web ? "Web" : "macOS")")
                if let directory = settings.buildTargetExportSubdirectory { output.appendPathComponent(directory) }
                let result = try await EditorAdaScriptNativeExporter(runner: runner).export(project: settings, at: projectURL, to: output, options: options) { [weak self] event in
                    await MainActor.run { self?.appendOutputBlock(event.text) }
                }
                appendOutput("Native AdaScript export ready: \(result.path)")
                workspaceStatus = .idle
                buildActivity?.finish(succeeded: true)
                finishWorkspaceActivity(activity, succeeded: true)
                if launch, web {
                    #if os(Windows)
                    try await serveWindowsWebExport(at: result.appendingPathComponent("web"), engine: sdk.engineRoot, runner: runner)
                    #else
                    _ = EditorPlatformFileActions.reveal(result)
                    #endif
                } else {
                    _ = EditorPlatformFileActions.reveal(result)
                }
            } catch is CancellationError {
                workspaceStatus = .cancelled
                buildActivity?.finish(succeeded: false)
                finishWorkspaceActivity(activity, succeeded: false, detail: "Cancelled")
            } catch {
                appendOutput("Native AdaScript export failed: \(error.localizedDescription)")
                workspaceStatus = .failed(error.localizedDescription)
                buildActivity?.finish(succeeded: false)
                finishWorkspaceActivity(activity, succeeded: false, detail: error.localizedDescription)
            }
            footer.setWorkspaceFooterTitle(workspaceStatus.title)
            workspaceTask = nil
            adaScriptWebExportRunner = nil
        }
        #else
        appendOutput("Native export requires standalone macOS AdaEditor with Gravity AOT.")
        #endif
    }

    #if os(Windows)
    private func serveWindowsWebExport(at directory: URL, engine: URL, runner: EditorProcessRunner) async throws {
        guard FileManager.default.fileExists(atPath: directory.appendingPathComponent("index.html").path) else {
            throw EditorPreviewBuildFailure(message: "The Web export has no index.html.")
        }
        let command = EditorProcessCommand(
            executablePath: EditorHostTools.executable("python3", windowsName: "python.exe"),
            arguments: [engine.appendingPathComponent("Tools/Windows/serve_web.py").path, "--directory", directory.path],
            workingDirectory: directory, environment: [:])
        let result = await runner.run(command) { [weak self] event in
            await MainActor.run {
                guard let self else { return }
                self.appendOutputBlock(event.text)
                for line in event.text.split(whereSeparator: \.isNewline) where line.hasPrefix("ADA_WEB_READY ") {
                    let data = Data(line.dropFirst("ADA_WEB_READY ".count).utf8)
                    if let address = (try? JSONDecoder().decode([String: String].self, from: data))?["url"], let url = URL(string: address) {
                        _ = self.externalURLOpener(url)
                        self.workspaceStatus = .running("Web · " + address)
                        self.footer.setWorkspaceFooterTitle(self.workspaceStatus.title)
                    }
                }
            }
        }
        try Task.checkCancellation()
        guard result.succeeded else { throw EditorPreviewBuildFailure(message: result.combinedOutput) }
        workspaceStatus = .ready
    }
    #endif
}
