import Foundation

extension EditorViewModel {
    func exportAdaScriptNativeGame(web: Bool) {
        #if os(macOS) && canImport(GravityAOT)
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
                let engine = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent()
                    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                let override = ProcessInfo.processInfo.environment["ADAENGINE_GRAVITY_PACKAGE_PATH"].map { URL(fileURLWithPath: $0) }
                let candidates = override.map { [$0] } ?? [
                    engine.deletingLastPathComponent().appendingPathComponent("gravity-lang-aot", isDirectory: true),
                    engine.appendingPathComponent(".build/checkouts/gravity-lang", isDirectory: true),
                    engine.appendingPathComponent("Editor/.build/checkouts/gravity-lang", isDirectory: true),
                ]
                guard let gravityRoot = candidates.first(where: { FileManager.default.fileExists(atPath: $0.appendingPathComponent("tools/aot_build.py").path) }) else {
                    throw EditorPreviewBuildFailure(message: "Set ADAENGINE_GRAVITY_PACKAGE_PATH to a Gravity checkout with tools/aot_build.py.")
                }
                let toolchain = await SwiftToolchainLocator.locate()
                let webSwift =
                    ProcessInfo.processInfo.environment["ADA_WEB_SWIFT_EXECUTABLE"]
                    ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Developer/Toolchains/swift-6.3.2-RELEASE.xctoolchain/usr/bin/swift").path
                let options = EditorAdaScriptNativeExportOptions(
                    destination: web ? .web : .macOS,
                    gravityRoot: gravityRoot,
                    engineRoot: engine,
                    swiftExecutable: web ? webSwift : toolchain.swiftExecutablePath,
                    swiftSDK: ProcessInfo.processInfo.environment["ADA_WEB_SWIFT_SDK"] ?? "swift-6.3.2-RELEASE_wasm"
                )
                let output = projectURL.appendingPathComponent("Exports/\(web ? "Web" : "macOS")")
                let result = try await EditorAdaScriptNativeExporter(runner: runner).export(project: settings, at: projectURL, to: output, options: options) { [weak self] event in
                    await MainActor.run { self?.appendOutputBlock(event.text) }
                }
                appendOutput("Native AdaScript export ready: \(result.path)")
                workspaceStatus = .idle
                buildActivity?.finish(succeeded: true)
                finishWorkspaceActivity(activity, succeeded: true)
                _ = EditorPlatformFileActions.reveal(result)
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
}
