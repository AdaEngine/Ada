import AdaDebugging
import AdaEngine
import Foundation

extension EditorViewModel {
    func presentDebugger() {
        toolStrip.activeLeftBottomTool = "debug"
        showBottomPanel = true
    }

    func configureDebugger() {
        debugger.configure(projectURL: projectURL)
        for session in [debugger.swift, debugger.adaScript] {
            session.onSelectFrame = { [weak self] frame in self?.revealDebugFrame(frame) }
            session.onStopped = { [weak self, weak session] in
                guard let self, let session else {
                    return
                }
                self.debugger.selectedLanguage = session === self.debugger.swift ? .swift : .adaScript
                self.presentDebugger()
            }
        }
        rememberDebugSource()
    }

    func rememberDebugSource() {
        guard case let .text(document)? = workbench.activeDocument, let path = document.absolutePath else {
            return
        }
        if debugger.sourceContents[path] == nil {
            debugger.sourceContents[path] = document.content
        }
    }

    func updateDebugSource(documentID: String) {
        guard let document = workbench.textDocument(id: documentID), let path = document.absolutePath else {
            return
        }
        debugger.sourceChanged(path: path, text: document.content)
    }

    func revealDebugFrame(_ frame: DebugStackFrame) {
        guard var path = frame.path else {
            return
        }
        if let projectURL {
            let canonicalRoot = DebugSourcePath.physical(projectURL.path)
            if path.hasPrefix(canonicalRoot + "/") {
                path = projectURL.appendingPathComponent(String(path.dropFirst(canonicalRoot.count + 1))).path
            }
        }
        let position = EditorSourceLocation(line: max(0, frame.line - 1), character: max(0, frame.column - 1))
        let range = EditorSourceRange(start: position, end: position)
        openSourceTarget(EditorSourceSymbolTarget(uri: URL(fileURLWithPath: path).absoluteString, filePath: path, range: range, selectionRange: range))
    }

    func debugSelectedTarget() {
        guard !debugger.isActive, workspaceTask == nil, let projectURL else {
            return
        }
        presentDebugger()
        guard workbench.saveAllDocuments() else {
            debugger.status = "Debug blocked: unable to save project documents."
            return
        }
        let settings: AdaProject
        do { settings = try ProjectSystem.loadProject(at: projectURL, fileManager: fileManager) } catch {
            debugger.status = error.localizedDescription
            return
        }
        guard selectedRunDestination != .web else {
            debugger.status = "Debugging is available for macOS and AdaScript on iPadOS."
            return
        }
        if settings.build.system.isAdaScript {
            debugger.selectedLanguage = .adaScript
            guard selectedRunDestination == .macOS else {
                debugger.status = "AdaScript debugging currently runs in the local macOS runtime. Select macOS as the destination."
                return
            }
            let projectName = settings.project.displayName ?? settings.project.name ?? project?.name ?? "AdaScript Project"
            debugger.status = "Preparing AdaScript debug run…"
            debugger.launchedBreakpoints = debugger.breakpoints
            buildAdaScriptProject(
                settings,
                at: projectURL,
                statusTitle: "Prepare AdaScript Debug Run"
            ) { [weak self] artifact in
                guard let self else {
                    return
                }
                if self.launchAdaScriptProject(artifact, projectName: projectName) {
                    self.debugger.status = "AdaScript runtime is running. VM pause, stepping, and breakpoint suspension are not available yet."
                } else {
                    self.debugger.status = "AdaScript debug run failed to launch. See Output for details."
                }
            }
            return
        }
        guard EditorDistribution.current.supportsSwiftProjects else {
            debugger.status = EditorDistributionError.swiftProjectsMessage
            return
        }
        #if os(macOS)
            guard selectedRunDestination == .macOS, let product = selectedRunProduct ?? runProducts.first else {
                debugger.status = "Select a macOS executable product to debug."
                return
            }
            debugger.selectedLanguage = .swift
            debugger.isBuilding = true
            debugger.modifiedSources = []
            debugger.launchedBreakpoints = debugger.breakpoints
            debugger.swift.watches = debugger.watches
            debugger.status = "Building \(product) for debugging…"
            debugger.buildGeneration += 1
            let generation = debugger.buildGeneration
            debugger.buildTask = Task { [weak self] in
                guard let self else {
                    return
                }
                defer {
                    if self.debugger.buildGeneration == generation {
                        self.debugger.isBuilding = false
                        self.debugger.buildTask = nil
                    }
                }
                do {
                    let toolchain = await SwiftToolchainLocator.locate()
                    let scratch = projectURL.appendingPathComponent(".build/adaeditor-debug", isDirectory: true)
                    let arguments = ["build", "--configuration", "debug", "--scratch-path", scratch.path, "--jobs", "4"]
                    let result = await self.debugger.buildRunner.run(
                        EditorProcessCommand(
                            executablePath: toolchain.swiftExecutablePath,
                            arguments: arguments + ["--product", product],
                            workingDirectory: projectURL
                        )
                    ) { [weak self] event in
                        await MainActor.run { self?.debugger.swift.appendConsole(event.text) }
                    }
                    try Task.checkCancellation()
                    guard result.exitCode == 0 else {
                        throw DebuggerError.requestFailed("Debug build failed. See console output.")
                    }
                    let location = await self.debugger.buildRunner.run(
                        EditorProcessCommand(
                            executablePath: toolchain.swiftExecutablePath,
                            arguments: arguments + ["--show-bin-path"],
                            workingDirectory: projectURL
                        )
                    )
                    try Task.checkCancellation()
                    guard location.exitCode == 0 else {
                        throw DebuggerError.requestFailed(location.standardError)
                    }
                    let executable = URL(fileURLWithPath: location.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)).appendingPathComponent(product)
                    let adapter = await self.debugger.buildRunner.run(
                        EditorProcessCommand(
                            executablePath: "/usr/bin/xcrun",
                            arguments: ["--find", "lldb-dap"],
                            workingDirectory: projectURL
                        )
                    )
                    try Task.checkCancellation()
                    guard adapter.exitCode == 0 else {
                        throw DebuggerError.unavailable("Install or select an Xcode toolchain containing lldb-dap.")
                    }
                    let client = LLDBDebugClient()
                    try await client.start(executable: URL(fileURLWithPath: adapter.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)))
                    self.debugger.status = ""
                    await self.debugger.swift.launch(
                        transport: client,
                        arguments: [
                            "program": .string(executable.path), "cwd": .string(projectURL.path),
                            "sourceMap": .object([DebugSourcePath.physical(projectURL.path): .string(projectURL.path)]),
                            "args": .array(settings.run.arguments.map(DebugJSON.string)), "stopOnEntry": .bool(false),
                        ],
                        breakpoints: self.debugger.breakpoints.filter { URL(fileURLWithPath: $0.path).pathExtension == "swift" }
                    )
                } catch is CancellationError {
                    if self.debugger.buildGeneration == generation {
                        self.debugger.status = "Debug launch cancelled."
                    }
                } catch {
                    if self.debugger.buildGeneration == generation {
                        self.debugger.status = error.localizedDescription
                    }
                }
            }
        #else
            debugger.status = "Swift debugging requires AdaEditor on macOS."
        #endif
    }
}
