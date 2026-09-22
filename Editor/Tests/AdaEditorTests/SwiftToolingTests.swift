import AdaPackageManifestTool
import Foundation
import GravityLanguageCore
import Testing

@testable import AdaEditor

@Suite("SwiftPM workspace tooling")
struct SwiftToolingTests {
    @Test("SwiftPM execute forwards live process output")
    func swiftPMExecuteForwardsLiveOutput() async {
        let event = EditorProcessOutputEvent(
            stream: .standardOutput,
            text: "[1/2] Compiling Game Player.swift\n"
        )
        let runner = FakeProcessRunner(results: [], outputChunks: [[event]])
        let recorder = WorkspaceOutputRecorder()
        let service = SwiftPMWorkspaceService(processRunner: runner)

        _ = await service.execute(
            .build(target: "Game", buildTests: false),
            projectURL: URL(fileURLWithPath: "/tmp/Game", isDirectory: true)
        ) { output in
            await recorder.append(output)
        }

        #expect(await recorder.events == [event])
    }

    @Test("SwiftPM service constructs expected commands")
    func swiftPMCommandConstruction() {
        let service = SwiftPMWorkspaceService(processRunner: FakeProcessRunner(results: []))
        let toolchain = SwiftToolchain(swiftExecutablePath: "/usr/bin/swift", sourceKitLSPExecutablePath: "/usr/bin/sourcekit-lsp")
        let projectURL = URL(fileURLWithPath: "/tmp/Game", isDirectory: true)
        let buildPrefix = ["build", "--jobs", String(SwiftPMWorkspaceService.responsiveBuildJobCount)]
        let targetBuild = service.makeCommand(.build(target: "Game", buildTests: false), projectURL: projectURL, toolchain: toolchain)
        let testBuild = service.makeCommand(.build(target: nil, buildTests: true), projectURL: projectURL, toolchain: toolchain)

        #expect(service.makeCommand(.resolve, projectURL: projectURL, toolchain: toolchain).arguments == ["package", "resolve"])
        #expect(service.makeCommand(.describe, projectURL: projectURL, toolchain: toolchain).arguments == ["package", "describe", "--type", "json"])
        #expect(targetBuild.arguments == buildPrefix + ["--target", "Game"])
        #expect(testBuild.arguments == buildPrefix + ["--build-tests"])
        #expect(service.makeCommand(.run(target: "Game", arguments: ["--debug"]), projectURL: projectURL, toolchain: toolchain).arguments == ["run", "Game", "--", "--debug"])
        let webCommand = service.makeCommand(.runWeb(target: "Game", outputPath: "dist/web", serve: true), projectURL: projectURL, toolchain: toolchain)
        #expect(
            webCommand.arguments == [
                "package", "--allow-writing-to-package-directory", "--allow-network-connections", "all",
                "export-web", "--product", "Game", "--output", "dist/web", "--serve",
            ]
        )
        #expect(webCommand.environment["ADAENGINE_WEB_EXPORT"] == "1")
        #expect(webCommand.environment["BUILD_WASM"] == "1")
        #expect(service.makeCommand(.test(filter: "GameTests"), projectURL: projectURL, toolchain: toolchain).arguments == ["test", "--parallel", "--filter", "GameTests"])
    }

    @Test("workspace bootstrap builds production targets and batches indexing progress")
    func workspaceBootstrapUsesResponsiveIndexBuild() async throws {
        let projectURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceBootstrap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: projectURL) }

        let toolchain = SwiftToolchain(swiftExecutablePath: "/usr/bin/swift", sourceKitLSPExecutablePath: nil)
        let placeholderCommand = EditorProcessCommand(
            executablePath: toolchain.swiftExecutablePath,
            arguments: [],
            workingDirectory: projectURL
        )
        let runner = FakeProcessRunner(
            results: [
                EditorProcessResult(command: placeholderCommand, exitCode: 0, standardOutput: "", standardError: ""),
                EditorProcessResult(command: placeholderCommand, exitCode: 0, standardOutput: packageDescriptionJSON, standardError: ""),
                EditorProcessResult(command: placeholderCommand, exitCode: 0, standardOutput: "", standardError: ""),
            ],
            outputChunks: [
                [],
                [],
                [
                    EditorProcessOutputEvent(
                        stream: .standardOutput,
                        text: "[1/2] Compiling Game main.swift\n[2/2] Compiling Game Player.swift\n"
                    )
                ],
            ]
        )
        let recorder = WorkspaceProgressRecorder()
        let service = SwiftPMWorkspaceService(processRunner: runner, toolchain: toolchain)

        let result = await service.bootstrap(projectURL: projectURL) { update in
            await recorder.append(update)
        }
        let commands = await runner.commands
        let updates = await recorder.updates
        let indexingUpdates = updates.filter { $0.phase == .indexingBuild }
        let buildArguments = try #require(commands.last?.arguments)
        let finalIndexingUpdateIndex = try #require(updates.lastIndex { $0.phase == .indexingBuild })
        let sourceKitUpdateIndex = try #require(updates.lastIndex { $0.phase == .startingSourceKitLSP })

        #expect(result.succeeded)
        #expect(!buildArguments.contains("--build-tests"))
        #expect(buildArguments == ["build", "--jobs", String(SwiftPMWorkspaceService.responsiveBuildJobCount)])
        #expect(indexingUpdates.count == 2)
        #expect(indexingUpdates.last?.detail == "[1/2] Compiling Game main.swift\n[2/2] Compiling Game Player.swift")
        #expect(finalIndexingUpdateIndex < sourceKitUpdateIndex)
    }

    @Test("run uses executable product while project settings map to its target")
    @MainActor
    func runUsesExecutableProductName() async throws {
        let projectURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("RunSettings-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: projectURL) }
        var projectSettings = ProjectSystem.defaultProject(projectName: "My-Game")
        projectSettings.run.arguments = ["--debug", "--level=intro"]
        try ProjectSystem.saveProject(projectSettings, at: projectURL)
        let project = EditorProjectReference(name: "My-Game", path: projectURL.path)
        let packageModel = SwiftPackageModel(
            name: "My-Game",
            products: [SwiftPackageProduct(name: "My-Game", type: "executable", targets: ["My_Game"])],
            targets: [SwiftPackageTarget(name: "My_Game", type: "executable", path: "Sources/My_Game", sources: ["main.swift"], targetDependencies: [], productDependencies: [])],
            dependencies: []
        )
        let service = RecordingWorkspaceService()
        let viewModel = EditorViewModel(
            project: project,
            workspaceService: service,
            workbench: EditorWorkbenchViewModel(activeEditorTab: "", openDocuments: [], activeDocumentID: ""),
            workspaceStatus: .ready,
            packageModel: packageModel,
            selectedRunProduct: "My-Game"
        )

        #expect(viewModel.runProducts == ["My-Game"])
        #expect(viewModel.selectedRunTargetName == "My_Game")
        viewModel.runSelectedTarget()
        try await waitForRecordedCommands(service, count: 1)
        #expect(await service.commands.first == .run(target: "My-Game", arguments: ["--debug", "--level=intro"]))

        let cleanDocument = EditorTextDocument(
            id: "main",
            title: "main.swift",
            relativePath: "Sources/My_Game/main.swift",
            absolutePath: projectURL.appendingPathComponent("Sources/My_Game/main.swift").path,
            language: .swift,
            content: "print(1)",
            isDirty: false
        )
        viewModel.workbench.open(.text(cleanDocument))
        viewModel.selectedRunDestination = .web
        viewModel.runSelectedTarget()
        try await waitForRecordedCommands(service, count: 2)
        #expect(await service.commands.last == .runWeb(target: "My-Game", outputPath: "dist/web", serve: true))
    }

    @Test("toolbar Run uses the selected Web destination even when a scene is active")
    @MainActor
    func toolbarRunUsesSelectedWebDestinationWithActiveScene() async throws {
        let projectURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ToolbarWebRun-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: projectURL) }
        try ProjectSystem.saveProject(ProjectSystem.defaultProject(projectName: "Game"), at: projectURL)
        let service = RecordingWorkspaceService(
            outputEvents: [
                EditorProcessOutputEvent(
                    stream: .standardError,
                    text: "Serving /tmp/web at http://127.0.0.1:8080\n"
                )
            ]
        )
        var openedURL: URL?
        let packageModel = SwiftPackageModel(
            name: "Game",
            products: [SwiftPackageProduct(name: "Game", type: "executable", targets: ["Game"])],
            targets: [],
            dependencies: []
        )
        let viewModel = EditorViewModel(
            project: EditorProjectReference(name: "Game", path: projectURL.path),
            workspaceService: service,
            externalURLOpener: { url in
                openedURL = url
                return true
            },
            workbench: EditorViewModel().workbench,
            workspaceStatus: .ready,
            packageModel: packageModel,
            selectedRunProduct: "Game",
            selectedRunDestination: .web
        )
        #expect(viewModel.workbench.activeSceneDocument != nil)

        viewModel.runFromToolbar()
        try await waitForRecordedCommands(service, count: 1)

        #expect(await service.commands == [.runWeb(target: "Game", outputPath: "dist/web", serve: true)])
        #expect(viewModel.playModeState == EditorPlayModeState.editing)
        #expect(openedURL?.absoluteString == "http://127.0.0.1:8080")
    }

    @Test("toolbar Run never enters editor Play Mode for an AdaScript Web destination")
    @MainActor
    func toolbarRunDoesNotEnterPlayModeForAdaScriptWebDestination() async throws {
        let projectURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ToolbarAdaScriptWebRun-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: projectURL) }
        var settings = ProjectSystem.defaultProject(projectName: "Game")
        settings.build.system = .adaScript
        try ProjectSystem.saveProject(settings, at: projectURL)
        let service = RecordingWorkspaceService()
        let viewModel = EditorViewModel(
            project: EditorProjectReference(name: "Game", path: projectURL.path),
            workspaceService: service,
            workbench: EditorViewModel().workbench,
            selectedRunDestination: .web
        )

        viewModel.runFromToolbar()
        await Task.yield()

        #expect(viewModel.playModeState == EditorPlayModeState.editing)
        #expect(viewModel.workspaceStatus == .failed("Web run is not available for AdaScript projects yet."))
        #expect(await service.commands.isEmpty)
    }

    @Test("run aborts when the active dirty document cannot be saved")
    @MainActor
    func runAbortsAfterSaveFailure() async {
        let service = RecordingWorkspaceService()
        let document = EditorTextDocument(
            id: "readonly",
            title: "main.swift",
            relativePath: "Sources/Game/main.swift",
            absolutePath: "/tmp/Game/Sources/Game/main.swift",
            language: .swift,
            content: "edited",
            isReadOnly: true,
            errorMessage: nil,
            isDirty: true
        )
        let model = SwiftPackageModel(
            name: "Game",
            products: [SwiftPackageProduct(name: "Game", type: "executable", targets: ["Game"])],
            targets: [],
            dependencies: []
        )
        let viewModel = EditorViewModel(
            project: EditorProjectReference(name: "Game", path: "/tmp/Game"),
            workspaceService: service,
            workbench: EditorWorkbenchViewModel(activeEditorTab: "main.swift", openDocuments: [.text(document)], activeDocumentID: document.id),
            workspaceStatus: .ready,
            packageModel: model,
            selectedRunProduct: "Game"
        )

        viewModel.runSelectedTarget()
        await Task.yield()

        #expect(await service.commands.isEmpty)
        guard case let .failed(message) = viewModel.workspaceStatus else {
            Issue.record("Expected run to fail before starting a process")
            return
        }
        #expect(message.contains("Run blocked"))
        #expect(message.contains("read-only"))
    }

    @Test("AdaScript workspace builds in process without invoking SwiftPM")
    @MainActor
    func adaScriptWorkspaceSkipsSwiftPM() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("AdaScriptWorkspace-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let project = try EditorProjectStore(
            storageURL: rootURL.appendingPathComponent("projects.json")
        )
        .createProject(named: "TabletGame", at: rootURL, template: .adaScript)
        let service = RecordingWorkspaceService()
        let viewModel = EditorViewModel(project: project, workspaceService: service)

        viewModel.startEditorSessionIfNeeded()
        #expect(viewModel.workspaceStatus == .running("Prepare AdaScript Workspace"))
        for _ in 0..<100 where viewModel.workspaceStatus != .ready {
            try await Task.sleep(for: .milliseconds(5))
        }

        #expect(await service.bootstrapCallCount == 0)
        #expect(await service.commands.isEmpty)
        #expect(viewModel.workspaceStatus == .ready)
        #expect(viewModel.outputLines.contains { $0.text.contains("AdaScript build succeeded") })
    }

    @Test("new caret position clears stale completions before debounce")
    @MainActor
    func caretChangeClearsCompletionImmediately() {
        let completion = EditorCompletionItem(label: "old", detail: nil, insertText: "old", replacementRange: nil, sortText: nil)
        let document = EditorTextDocument(
            id: "main",
            title: "main.swift",
            relativePath: "Sources/Game/main.swift",
            absolutePath: "/tmp/Game/Sources/Game/main.swift",
            language: .swift,
            content: "ol",
            completionItems: [completion],
            completionPosition: EditorSourceLocation(line: 0, character: 2)
        )
        let viewModel = EditorViewModel(
            project: EditorProjectReference(name: "Game", path: "/tmp/Game"),
            workspaceService: RecordingWorkspaceService(),
            workbench: EditorWorkbenchViewModel(activeEditorTab: "main.swift", openDocuments: [.text(document)], activeDocumentID: document.id)
        )

        viewModel.handleCompletionPosition(document: document, position: EditorSourceLocation(line: 0, character: 1), text: "o")

        guard case let .text(updatedDocument)? = viewModel.workbench.activeDocument else {
            Issue.record("Expected active text document")
            return
        }
        #expect(updatedDocument.completionItems.isEmpty)
        #expect(updatedDocument.completionPosition == nil)
    }

    @Test("automatic completion ignores closing delimiters")
    @MainActor
    func automaticCompletionIgnoresClosingDelimiters() async {
        let service = RecordingWorkspaceService()
        let document = EditorTextDocument(
            id: "main",
            title: "main.swift",
            relativePath: "Sources/Game/main.swift",
            absolutePath: "/tmp/Game/Sources/Game/main.swift",
            language: .swift,
            content: "Text(\"Hello\")\n}"
        )
        let viewModel = EditorViewModel(
            project: EditorProjectReference(name: "Game", path: "/tmp/Game"),
            workspaceService: service,
            workbench: EditorWorkbenchViewModel(activeEditorTab: "main.swift", openDocuments: [.text(document)], activeDocumentID: document.id)
        )

        viewModel.handleCompletionPosition(
            document: document,
            position: EditorSourceLocation(line: 0, character: 13),
            text: document.content
        )
        viewModel.handleCompletionPosition(
            document: document,
            position: EditorSourceLocation(line: 1, character: 1),
            text: document.content
        )
        await Task.yield()

        #expect(await service.completionRequests.isEmpty)
    }

    @Test("automatic completion still runs for identifiers and member access")
    func automaticCompletionAcceptsTypingContexts() {
        #expect(
            EditorViewModel.shouldRequestAutomaticCompletion(
                in: "player.upd",
                at: EditorSourceLocation(line: 0, character: 10)
            )
        )
        #expect(
            EditorViewModel.shouldRequestAutomaticCompletion(
                in: "player.",
                at: EditorSourceLocation(line: 0, character: 7)
            )
        )
        #expect(
            !EditorViewModel.shouldRequestAutomaticCompletion(
                in: "player.update()",
                at: EditorSourceLocation(line: 0, character: 15)
            )
        )
        #expect(
            !EditorViewModel.shouldRequestAutomaticCompletion(
                in: "}",
                at: EditorSourceLocation(line: 0, character: 1)
            )
        )
    }

    @Test("AdaScript completion offers Ada APIs and document declarations")
    func gravityCompletionOffersAdaAPIsAndSymbols() async throws {
        let service = SwiftPMWorkspaceService()
        let source = """
            @system(scheduler: "update")
            class MovementSystem {
                @que
                func update(context) {}
            }
            """
        let apiItems = await service.completions(
            fileURL: URL(fileURLWithPath: "/tmp/Movement.ada"),
            language: .ada,
            text: source,
            position: EditorSourceLocation(line: 2, character: 8)
        )

        let query = try #require(apiItems.first { $0.label == "query" })
        #expect(query.insertText == "query()")
        #expect(query.kind == .annotation)
        #expect(
            query.replacementRange
                == EditorSourceRange(
                    start: EditorSourceLocation(line: 2, character: 5),
                    end: EditorSourceLocation(line: 2, character: 8)
                )
        )

        let symbolItems = await service.completions(
            fileURL: URL(fileURLWithPath: "/tmp/Movement.ada"),
            language: .ada,
            text: source + "\nMove",
            position: EditorSourceLocation(line: 5, character: 4)
        )
        #expect(symbolItems.contains { $0.label == "MovementSystem" && $0.insertText == "MovementSystem" && $0.kind == .class })
        let scriptableItems = await service.completions(
            fileURL: URL(fileURLWithPath: "/tmp/Scriptable.ada"),
            language: .ada,
            text: "@scr",
            position: EditorSourceLocation(line: 0, character: 4)
        )
        let exportItems = await service.completions(
            fileURL: URL(fileURLWithPath: "/tmp/Export.ada"),
            language: .ada,
            text: "@exp",
            position: EditorSourceLocation(line: 0, character: 4)
        )
        #expect(scriptableItems.contains { $0.label == "scriptable" && $0.kind == .annotation })
        #expect(exportItems.contains { $0.label == "export" && $0.kind == .annotation })
    }

    @Test("AdaScript files enable editor tooling and definition navigation")
    func gravityEditorToolingAndDefinition() async throws {
        #expect(EditorSourceLanguage.detect(fileName: "Movement.gravity") == .ada)
        #expect(EditorSourceLanguage.ada.supportsLanguageTooling)

        let service = SwiftPMWorkspaceService()
        let source = "func tick() {}\nfunc update() { tick(); }"
        let fileURL = URL(fileURLWithPath: "/tmp/Movement.gravity")
        let targets = await service.definition(
            fileURL: fileURL,
            language: .ada,
            text: source,
            position: EditorSourceLocation(line: 1, character: 18)
        )

        let target = try #require(targets.first)
        #expect(target.filePath == fileURL.path)
        #expect(
            target.selectionRange
                == EditorSourceRange(
                    start: EditorSourceLocation(line: 0, character: 5),
                    end: EditorSourceLocation(line: 0, character: 9)
                )
        )
    }

    @Test("AdaScript editor completion uses workspace symbols and character columns")
    func gravityEditorCompletionUsesWorkspaceAndCharacterColumns() throws {
        let projectURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("AdaScriptEditorCompletion-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: projectURL) }
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        try "class SharedSystem { func tick() {} }"
            .write(
                to: projectURL.appendingPathComponent("Shared.ada"),
                atomically: true,
                encoding: .utf8
            )

        let workspace = GravityWorkspace()
        workspace.configure(rootURIs: [projectURL.absoluteString])
        let source = "var icon = \"😀\"; SharedSystem.ti"
        let items = EditorGravityLanguageService.completions(
            workspace: workspace,
            uri: projectURL.appendingPathComponent("Current.ada").absoluteString,
            text: source,
            position: EditorSourceLocation(line: 0, character: source.count)
        )

        let tick = try #require(items.first { $0.label == "tick" })
        #expect(
            tick.replacementRange
                == EditorSourceRange(
                    start: EditorSourceLocation(line: 0, character: source.count - 2),
                    end: EditorSourceLocation(line: 0, character: source.count)
                )
        )
    }

    @Test("Ada documents request automatic completion through the editor path")
    @MainActor
    func adaDocumentsRequestAutomaticCompletion() async throws {
        let service = RecordingWorkspaceService()
        let document = EditorTextDocument(
            id: "gravity",
            title: "Movement.ada",
            relativePath: "Sources/Game/Movement.ada",
            absolutePath: "/tmp/Game/Sources/Game/Movement.ada",
            language: .ada,
            content: "@que"
        )
        let viewModel = EditorViewModel(
            project: EditorProjectReference(name: "Game", path: "/tmp/Game"),
            workspaceService: service,
            workbench: EditorWorkbenchViewModel(activeEditorTab: document.title, openDocuments: [.text(document)], activeDocumentID: document.id)
        )

        viewModel.handleCompletionPosition(
            document: document,
            position: EditorSourceLocation(line: 0, character: 4),
            text: document.content
        )

        try await waitForCompletionRequests(service, count: 1)
        #expect(await service.completionRequests.first?.text == document.content)
    }

    @Test("escape requests completion immediately when the popup is hidden")
    @MainActor
    func escapeRequestsCompletionImmediately() async throws {
        let service = RecordingWorkspaceService()
        let document = EditorTextDocument(
            id: "main",
            title: "main.swift",
            relativePath: "Sources/Game/main.swift",
            absolutePath: "/tmp/Game/Sources/Game/main.swift",
            language: .swift,
            content: "Text(\"Hello\").font"
        )
        let viewModel = EditorViewModel(
            project: EditorProjectReference(name: "Game", path: "/tmp/Game"),
            workspaceService: service,
            workbench: EditorWorkbenchViewModel(activeEditorTab: "main.swift", openDocuments: [.text(document)], activeDocumentID: document.id)
        )
        let position = EditorSourceLocation(line: 0, character: document.content.count)

        viewModel.handleCompletionRequest(document: document, position: position, text: document.content)

        try await waitForCompletionRequests(service, count: 1)
        #expect(await service.completionRequests.first?.position == position)
    }

    @Test("escape dismisses an already visible completion popup")
    @MainActor
    func escapeDismissesVisibleCompletion() {
        let completion = EditorCompletionItem(label: "font", detail: "View", insertText: "font", replacementRange: nil, sortText: nil)
        let document = EditorTextDocument(
            id: "main",
            title: "main.swift",
            relativePath: "Sources/Game/main.swift",
            absolutePath: "/tmp/Game/Sources/Game/main.swift",
            language: .swift,
            content: "Text(\"Hello\").font",
            completionItems: [completion],
            completionPosition: EditorSourceLocation(line: 0, character: 18)
        )
        let service = RecordingWorkspaceService()
        let viewModel = EditorViewModel(
            project: EditorProjectReference(name: "Game", path: "/tmp/Game"),
            workspaceService: service,
            workbench: EditorWorkbenchViewModel(activeEditorTab: "main.swift", openDocuments: [.text(document)], activeDocumentID: document.id)
        )

        viewModel.handleCompletionRequest(
            document: document,
            position: EditorSourceLocation(line: 0, character: document.content.count),
            text: document.content
        )

        guard case let .text(updatedDocument)? = viewModel.workbench.activeDocument else {
            Issue.record("Expected active text document")
            return
        }
        #expect(updatedDocument.completionItems.isEmpty)
        #expect(updatedDocument.completionPosition == nil)
    }

    @Test("completion selection moves with arrows and Enter applies the selected item")
    @MainActor
    func completionSelectionMovesAndApplies() {
        let suggestions = [
            EditorCompletionItem(label: "if", detail: nil, insertText: "if", replacementRange: nil, sortText: nil),
            EditorCompletionItem(label: "import", detail: nil, insertText: "import", replacementRange: nil, sortText: nil),
        ]
        let document = EditorTextDocument(
            id: "main",
            title: "main.ada",
            relativePath: "Sources/Game/main.ada",
            absolutePath: "/tmp/Game/Sources/Game/main.ada",
            language: .ada,
            content: "i",
            completionItems: suggestions,
            completionPosition: EditorSourceLocation(line: 0, character: 1)
        )
        let viewModel = EditorViewModel(
            project: EditorProjectReference(name: "Game", path: "/tmp/Game"),
            workspaceService: RecordingWorkspaceService(),
            workbench: EditorWorkbenchViewModel(activeEditorTab: "main.ada", openDocuments: [.text(document)], activeDocumentID: document.id)
        )

        #expect(viewModel.moveCompletionSelection(in: document, by: 1))
        guard case let .text(selectedDocument)? = viewModel.workbench.activeDocument else {
            Issue.record("Expected active text document")
            return
        }
        #expect(selectedDocument.selectedCompletionIndex == 1)
        #expect(viewModel.moveCompletionSelection(in: selectedDocument, by: 1))

        guard case let .text(clampedDocument)? = viewModel.workbench.activeDocument else {
            Issue.record("Expected active text document")
            return
        }
        #expect(clampedDocument.selectedCompletionIndex == 1)
        #expect(viewModel.applySelectedCompletion(in: clampedDocument))

        guard case let .text(completedDocument)? = viewModel.workbench.activeDocument else {
            Issue.record("Expected active text document")
            return
        }
        #expect(completedDocument.content == "import")
        #expect(completedDocument.completionItems.isEmpty)
        #expect(completedDocument.completionPosition == nil)
    }

    @Test("command hover stores the selected symbol range and available description")
    @MainActor
    func commandHoverStoresRangeAndDescription() async throws {
        let hoveredRange = EditorSourceRange(
            start: EditorSourceLocation(line: 0, character: 9),
            end: EditorSourceLocation(line: 0, character: 22)
        )
        let service = RecordingWorkspaceService(
            hoverResponse: EditorSymbolHover(contents: "Dispatches an event.", range: hoveredRange),
            documentHighlightResponse: [EditorDocumentHighlight(range: hoveredRange, kind: .text)]
        )
        let document = EditorTextDocument(
            id: "main",
            title: "main.swift",
            relativePath: "Sources/Game/main.swift",
            absolutePath: "/tmp/Game/Sources/Game/main.swift",
            language: .swift,
            content: "document.dispatchEvent"
        )
        let viewModel = EditorViewModel(
            project: EditorProjectReference(name: "Game", path: "/tmp/Game"),
            workspaceService: service,
            workbench: EditorWorkbenchViewModel(activeEditorTab: "main.swift", openDocuments: [.text(document)], activeDocumentID: document.id)
        )

        viewModel.handleSourceHover(document: document, position: EditorSourceLocation(line: 0, character: 12))
        for _ in 0..<100 {
            if case let .text(updatedDocument)? = viewModel.workbench.activeDocument,
                updatedDocument.sourceHoverDescription != nil {
                break
            }
            try await Task.sleep(for: .milliseconds(5))
        }

        guard case let .text(hoveredDocument)? = viewModel.workbench.activeDocument else {
            Issue.record("Expected active text document")
            return
        }
        #expect(hoveredDocument.sourceHoverRange == hoveredRange)
        #expect(hoveredDocument.sourceHoverDescription == "Dispatches an event.")
        #expect(hoveredDocument.symbolHighlights == [hoveredRange])

        viewModel.handleSourceHover(document: hoveredDocument, position: nil)
        guard case let .text(clearedDocument)? = viewModel.workbench.activeDocument else {
            Issue.record("Expected active text document")
            return
        }
        #expect(clearedDocument.sourceHoverRange == nil)
        #expect(clearedDocument.sourceHoverDescription == nil)
        #expect(clearedDocument.symbolHighlights.isEmpty)
    }

    @Test("go to definition opens a read-only Swift interface with persistent documentation")
    @MainActor
    func goToDefinitionOpensGeneratedInterfaceAndDocumentation() async throws {
        let uri = "sourcekit-lsp://generated-swift-interface/Foundation.swiftinterface?moduleName=Foundation"
        let selection = EditorSourceRange(
            start: EditorSourceLocation(line: 1, character: 13),
            end: EditorSourceLocation(line: 1, character: 31)
        )
        let interface = "/// A notification delivery center.\npublic class NotificationCenter {}\n"
        let service = RecordingWorkspaceService(
            hoverResponse: EditorSymbolHover(contents: "Delivers notifications to registered observers.", range: nil),
            definitionResponse: [
                EditorSourceSymbolTarget(
                    uri: uri,
                    filePath: "/Foundation.swiftinterface",
                    range: EditorSourceRange(
                        start: EditorSourceLocation(line: 0, character: 0),
                        end: EditorSourceLocation(line: 1, character: 34)
                    ),
                    selectionRange: selection,
                    content: interface
                )
            ]
        )
        let source = EditorTextDocument(
            id: "main",
            title: "main.swift",
            relativePath: "Sources/Game/main.swift",
            absolutePath: "/tmp/Game/Sources/Game/main.swift",
            language: .swift,
            content: "let center = NotificationCenter.default"
        )
        let viewModel = EditorViewModel(
            project: EditorProjectReference(name: "Game", path: "/tmp/Game"),
            workspaceService: service,
            workbench: EditorWorkbenchViewModel(openDocuments: [.text(source)], activeDocumentID: source.id)
        )

        viewModel.goToDefinition(document: source, position: EditorSourceLocation(line: 0, character: 15))
        for _ in 0..<100 {
            if case let .text(document)? = viewModel.workbench.activeDocument, document.sourceURI == uri {
                break
            }
            try await Task.sleep(for: .milliseconds(5))
        }

        guard case let .text(document)? = viewModel.workbench.activeDocument else {
            Issue.record("Expected generated interface document")
            return
        }
        #expect(document.sourceURI == uri)
        #expect(document.absolutePath == nil)
        #expect(document.content == interface)
        #expect(document.isReadOnly)
        #expect(document.focusedRange == selection)
        #expect(document.symbolDocumentation == "Delivers notifications to registered observers.")
        #expect(document.statusMessage == "Read-only: generated Swift interface")
    }

    @Test("build diagnostics replacement preserves SourceKit diagnostics")
    @MainActor
    func buildDiagnosticsPreserveSourceKit() {
        let sourceKit = testDiagnostic(message: "live", source: "sourcekit-lsp")
        let oldBuild = testDiagnostic(message: "old build", source: "swift")
        let newBuild = testDiagnostic(message: "new build", source: "swift")

        let merged = EditorViewModel.replacingBuildDiagnostics(in: [sourceKit, oldBuild], with: [newBuild])

        #expect(merged == [sourceKit, newBuild])
    }

    @Test("workspace cancellation reaches the process runner")
    func workspaceCancellation() async {
        let runner = FakeProcessRunner(results: [])
        let connection = FakeSourceKitLSPConnection(completionResponse: .array([.object(["label": .string("update")])]))
        let sourceKitClient = SourceKitLSPClient(connection: connection)
        let service = SwiftPMWorkspaceService(processRunner: runner, sourceKitClient: sourceKitClient)

        await service.cancel()
        let completions = await service.completions(
            fileURL: URL(fileURLWithPath: "/tmp/Game/main.swift"),
            language: .swift,
            text: "up",
            position: EditorSourceLocation(line: 0, character: 2)
        )

        #expect(await runner.cancelCount == 1)
        #expect(await connection.stopCount == 0)
        #expect(completions.map(\.label) == ["update"])
    }

    @Test("package describe JSON parses products targets dependencies and plugins")
    func packageDescriptionParses() throws {
        let model = try #require(SwiftPackageModel.parse(from: packageDescriptionJSON))

        #expect(model.name == "Game")
        #expect(model.executableTargets == ["Game"])
        #expect(model.testTargets == ["GameTests"])
        #expect(model.pluginTargets == ["GamePlugin"])
        #expect(model.dependencies.map(\.identity) == ["adaengine"])
    }

    @Test("preview scanner finds top-level previewable views")
    func previewScannerFindsDeclarations() {
        let declarations = EditorPreviewScanner.declarations(
            in: """
                import AdaEngine

                @Previewable(title: "Primary")
                public struct PrimaryView: View {
                    var body: some View { EmptyView() }
                }

                @Previewable
                struct SecondaryView: View {
                    var body: some View { EmptyView() }
                }

                @AdaUI.Previewable(title: "Private")
                private final class PrivatePreviewView: AdaUI.View {
                    var body: some View { EmptyView() }
                }

                @Previewable
                struct NotAView {
                }
                """
        )

        #expect(declarations.map(\.typeName) == ["PrimaryView", "SecondaryView", "PrivatePreviewView"])
        #expect(declarations.map(\.title) == ["Primary", "SecondaryView", "Private"])
        #expect(
            declarations.map(\.symbolName) == [
                "ada_editor_preview_make_PrimaryView",
                "ada_editor_preview_make_SecondaryView",
                "ada_editor_preview_make_PrivatePreviewView",
            ]
        )
    }

    @Test("preview builder mirrors executable preview from entrypoint file")
    func previewBuilderMirrorsExecutableTarget() async throws {
        let fileManager = FileManager.default
        let projectURL = fileManager.temporaryDirectory
            .appendingPathComponent("AdaEditorPreviewBuilder-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? fileManager.removeItem(at: projectURL)
        }

        let gameSourceURL = projectURL.appendingPathComponent("Sources/Game", isDirectory: true)
        let sharedSourceURL = projectURL.appendingPathComponent("Sources/Shared", isDirectory: true)
        try fileManager.createDirectory(at: gameSourceURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: sharedSourceURL, withIntermediateDirectories: true)
        try """
        import AdaEngine

        @main
        struct GameMain {
            static func main() {}
        }

        @Previewable
        struct GameView: View {
            var body: some View { EmptyView() }
        }
        """
        .write(to: gameSourceURL.appendingPathComponent("main.swift"), atomically: true, encoding: .utf8)
        try "struct SharedHelper {}\n".write(to: sharedSourceURL.appendingPathComponent("SharedHelper.swift"), atomically: true, encoding: .utf8)

        let model = SwiftPackageModel(
            name: "Game",
            products: [
                SwiftPackageProduct(name: "Game", type: "executable", targets: ["Game"])
            ],
            targets: [
                SwiftPackageTarget(
                    name: "Game",
                    type: "executable",
                    path: "Sources/Game",
                    sources: ["main.swift"],
                    targetDependencies: ["Shared"],
                    productDependencies: ["AdaEngine"]
                ),
                SwiftPackageTarget(
                    name: "Shared",
                    type: "regular",
                    path: "Sources/Shared",
                    sources: ["SharedHelper.swift"],
                    targetDependencies: [],
                    productDependencies: ["Collections"]
                ),
            ],
            dependencies: [
                SwiftPackageDependency(identity: "adaengine", type: "fileSystem", url: nil, path: "../AdaEngine", requirement: nil),
                SwiftPackageDependency(
                    identity: "swift-collections",
                    type: "sourceControl",
                    url: "https://github.com/apple/swift-collections.git",
                    path: nil,
                    requirement: "from: 1.2.0"
                ),
            ]
        )
        let document = EditorTextDocument(
            id: "GameView.swift",
            title: "main.swift",
            relativePath: "Sources/Game/main.swift",
            absolutePath: gameSourceURL.appendingPathComponent("main.swift").path,
            language: .swift,
            content: "",
            errorMessage: nil
        )
        let declaration = EditorPreviewDeclaration(id: "GameView", title: "GameView", typeName: "GameView", line: 3)
        let runner = FakeProcessRunner(results: []) { command in
            let fileManager = FileManager.default
            let scratchPathIndex = command.arguments.firstIndex(of: "--scratch-path")
            let scratchPath = scratchPathIndex.flatMap { index -> String? in
                let valueIndex = command.arguments.index(after: index)
                guard command.arguments.indices.contains(valueIndex) else {
                    return nil
                }
                return command.arguments[valueIndex]
            }
            let buildRoot =
                scratchPath.map { URL(fileURLWithPath: $0, isDirectory: true) }
                ?? command.workingDirectory.appendingPathComponent(".build", isDirectory: true)
            let buildDirectory = buildRoot.appendingPathComponent("debug", isDirectory: true)
            try? fileManager.createDirectory(at: buildDirectory, withIntermediateDirectories: true)
            try? Data().write(to: buildDirectory.appendingPathComponent("libAdaEditorPreviewBundle.dylib"))
        }
        let previewPackageName = previewDirectoryName(relativePath: document.relativePath, declarationID: declaration.id)
        let previewPackageRoot =
            projectURL
            .appendingPathComponent(".build/adaeditor-previews", isDirectory: true)
            .appendingPathComponent(previewPackageName, isDirectory: true)
        let retainedBuildMarker =
            previewPackageRoot
            .appendingPathComponent(".build", isDirectory: true)
            .appendingPathComponent("retained-artifact.txt")
        try fileManager.createDirectory(at: retainedBuildMarker.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "keep".write(to: retainedBuildMarker, atomically: true, encoding: .utf8)
        try fileManager.createDirectory(at: previewPackageRoot.appendingPathComponent("Sources/Game", isDirectory: true), withIntermediateDirectories: true)
        try "stale".write(to: previewPackageRoot.appendingPathComponent("Sources/Game/Stale.swift"), atomically: true, encoding: .utf8)

        let artifact = try await EditorPreviewBuilder(processRunner: runner)
            .build(
                EditorPreviewBuildRequest(
                    projectURL: projectURL,
                    document: document,
                    packageModel: model,
                    declaration: declaration
                ),
                toolchain: SwiftToolchain(swiftExecutablePath: "/usr/bin/swift", sourceKitLSPExecutablePath: nil)
            )

        let previewRoot = projectURL.appendingPathComponent(".build/adaeditor-previews", isDirectory: true)
        let previewPackageURL = try #require(findFirstFile(named: "Package.swift", under: previewRoot, fileManager: fileManager))
        let manifest = try String(contentsOf: previewPackageURL, encoding: .utf8)
        let scratchRoot = previewPackageURL.deletingLastPathComponent()
        let commands = await runner.commands

        #expect(artifact.symbolName == "ada_editor_preview_make_GameView")
        #expect(artifact.libraryURL.lastPathComponent == "libAdaEditorPreviewBundle.dylib")
        #expect(artifact.libraryURL.path.contains("/.build/build-"))
        #expect(commands.first?.arguments.contains("--scratch-path") == true)
        #expect(manifest.contains(#".library(name: "AdaEditorPreviewBundle", type: .dynamic, targets: ["Game"])"#))
        #expect(manifest.contains(#".package(name: "AdaEngine", path: "\#(adaEnginePackageURL().path)")"#))
        #expect(manifest.contains(#".package(name: "swift-collections", url: "https://github.com/apple/swift-collections.git", from: "1.2.0")"#))
        #expect(manifest.contains(#"name: "Game""#))
        #expect(manifest.contains(#"dependencies: ["Shared", .product(name: "AdaEngine", package: "AdaEngine")]"#))
        #expect(manifest.contains(#"dependencies: [.product(name: "Collections", package: "swift-collections")]"#))
        #expect(!fileManager.fileExists(atPath: scratchRoot.appendingPathComponent("Sources/Game/main.swift").path))
        #expect(!fileManager.fileExists(atPath: scratchRoot.appendingPathComponent("Sources/Game/Stale.swift").path))
        #expect(fileManager.fileExists(atPath: retainedBuildMarker.path))
        let copiedMain = try String(contentsOf: scratchRoot.appendingPathComponent("Sources/Game/AdaEditorPreviewMain.swift"), encoding: .utf8)
        #expect(!copiedMain.contains("@main"))
        #expect(copiedMain.contains("@Previewable"))
        #expect(fileManager.fileExists(atPath: scratchRoot.appendingPathComponent("Sources/Shared/SharedHelper.swift").path))
    }

    @Test("source scanner prefers package model sources and falls back to Sources and Tests")
    func swiftSourceScannerCountsPackageSourcesAndFallback() throws {
        let fileManager = FileManager.default
        let projectURL = fileManager.temporaryDirectory
            .appendingPathComponent("AdaEditorSourceScan-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: projectURL) }

        try fileManager.createDirectory(at: projectURL.appendingPathComponent("Sources/Game", isDirectory: true), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: projectURL.appendingPathComponent("Tests/GameTests", isDirectory: true), withIntermediateDirectories: true)
        try "struct Game {}\n".write(to: projectURL.appendingPathComponent("Sources/Game/Game.swift"), atomically: true, encoding: .utf8)
        try "struct Ignored {}\n".write(to: projectURL.appendingPathComponent("Sources/Game/Ignored.swift"), atomically: true, encoding: .utf8)
        try "struct GameTests {}\n".write(to: projectURL.appendingPathComponent("Tests/GameTests/GameTests.swift"), atomically: true, encoding: .utf8)

        let model = SwiftPackageModel(
            name: "Game",
            products: [],
            targets: [
                SwiftPackageTarget(name: "Game", type: "regular", path: "Sources/Game", sources: ["Game.swift"], targetDependencies: [], productDependencies: []),
                SwiftPackageTarget(name: "GameTests", type: "test", path: "Tests/GameTests", sources: [], targetDependencies: ["Game"], productDependencies: []),
            ],
            dependencies: []
        )

        let modeledFiles = SwiftPMWorkspaceService.swiftSourceFiles(projectURL: projectURL, packageModel: model, fileManager: fileManager)
        #expect(modeledFiles.map(\.lastPathComponent) == ["Game.swift", "GameTests.swift"])
        let productionFiles = SwiftPMWorkspaceService.swiftSourceFiles(
            projectURL: projectURL,
            packageModel: model,
            includeTests: false,
            fileManager: fileManager
        )
        #expect(productionFiles.map(\.lastPathComponent) == ["Game.swift"])

        let fallbackFiles = SwiftPMWorkspaceService.swiftSourceFiles(projectURL: projectURL, packageModel: nil, fileManager: fileManager)
        #expect(fallbackFiles.map(\.lastPathComponent) == ["Game.swift", "Ignored.swift", "GameTests.swift"])
        let productionFallbackFiles = SwiftPMWorkspaceService.swiftSourceFiles(
            projectURL: projectURL,
            packageModel: nil,
            includeTests: false,
            fileManager: fileManager
        )
        #expect(productionFallbackFiles.map(\.lastPathComponent) == ["Game.swift", "Ignored.swift"])
    }

    @Test("build progress parser extracts Swift file target and unique completion count")
    func buildProgressParserTracksCompiledSwiftFiles() {
        let knownFiles = [
            URL(fileURLWithPath: "/tmp/Game/Sources/Game/main.swift"),
            URL(fileURLWithPath: "/tmp/Game/Sources/Game/Player.swift"),
        ]
        var parser = SwiftPMBuildProgressParser()

        let first = parser.parse(line: "[1/5] Compiling Game main.swift", knownFiles: knownFiles)
        let duplicate = parser.parse(line: "[2/5] Compiling Game main.swift", knownFiles: knownFiles)
        let second = parser.parse(line: "[3/5] Compiling Game Player.swift", knownFiles: knownFiles)
        let nonSwift = parser.parse(line: "[4/5] Linking Game", knownFiles: knownFiles)

        #expect(first == SwiftPMBuildProgress(completed: 1, currentFile: "main.swift", currentTarget: "Game"))
        #expect(duplicate.completed == 1)
        #expect(second == SwiftPMBuildProgress(completed: 2, currentFile: "Player.swift", currentTarget: "Game"))
        #expect(nonSwift == SwiftPMBuildProgress(completed: 2, currentFile: nil, currentTarget: nil))
    }

    @Test("indexing progress preserves split lines and emits one batch")
    func indexingProgressCoalescesOutput() async throws {
        let knownFiles = [
            URL(fileURLWithPath: "/tmp/Game/Sources/Game/main.swift"),
            URL(fileURLWithPath: "/tmp/Game/Sources/Game/Player.swift"),
        ]
        let tracker = SwiftPMBuildProgressTracker(minimumEmissionInterval: 60, now: 0)

        let firstBatch = await tracker.consume(
            EditorProcessOutputEvent(stream: .standardOutput, text: "[1/2] Compiling Game main."),
            knownFiles: knownFiles,
            now: 0.01
        )
        let secondBatch = await tracker.consume(
            EditorProcessOutputEvent(stream: .standardOutput, text: "swift\n[2/2] Compiling Game Player.swift\n"),
            knownFiles: knownFiles,
            now: 0.02
        )
        let flushedBatch = try #require(await tracker.finish(knownFiles: knownFiles, now: 0.03))

        #expect(firstBatch == nil)
        #expect(secondBatch == nil)
        #expect(
            flushedBatch.lines == [
                "[1/2] Compiling Game main.swift",
                "[2/2] Compiling Game Player.swift",
            ]
        )
        #expect(flushedBatch.buildProgress == SwiftPMBuildProgress(completed: 2, currentFile: "Player.swift", currentTarget: "Game"))
    }

    #if os(macOS) || os(Linux)
        @Test("process runner remains responsive while a child process is running")
        func processRunnerCanCancelRunningProcess() async throws {
            let runner = EditorProcessRunner()
            let command = EditorProcessCommand(
                executablePath: "/bin/sleep",
                arguments: ["3"],
                workingDirectory: URL(fileURLWithPath: "/tmp", isDirectory: true)
            )
            let resultTask = Task {
                await runner.run(command)
            }

            try await Task.sleep(for: .milliseconds(100))
            await runner.cancelAll()
            let result = await resultTask.value

            #expect(!result.succeeded)
        }
    #endif

    @Test("fake process runner streams output before returning final result")
    func fakeProcessRunnerStreamsOutput() async {
        let projectURL = URL(fileURLWithPath: "/tmp/Game", isDirectory: true)
        let command = EditorProcessCommand(executablePath: "/usr/bin/swift", arguments: ["build"], workingDirectory: projectURL)
        let runner = FakeProcessRunner(
            results: [EditorProcessResult(command: command, exitCode: 0, standardOutput: "done\n", standardError: "")],
            outputChunks: [[EditorProcessOutputEvent(stream: .standardOutput, text: "[1/1] Compiling Game main.swift\n")]]
        )
        let collector = OutputEventCollector()

        let result = await runner.run(command) { event in
            await collector.append(event)
        }
        let streamed = await collector.events

        #expect(result.succeeded)
        #expect(streamed == [EditorProcessOutputEvent(stream: .standardOutput, text: "[1/1] Compiling Game main.swift\n")])
    }

    @Test("build output parser extracts diagnostics")
    func buildDiagnosticsParse() {
        let projectURL = URL(fileURLWithPath: "/tmp/Game", isDirectory: true)
        let diagnostics = EditorDiagnostic.parseBuildOutput("/tmp/Game/Sources/Game/main.swift:3:12: error: cannot find 'foo' in scope", projectURL: projectURL)

        #expect(diagnostics.count == 1)
        #expect(diagnostics[0].severity == .error)
        #expect(diagnostics[0].range.start.line == 2)
        #expect(diagnostics[0].range.start.character == 11)
        #expect(diagnostics[0].message == "cannot find 'foo' in scope")
    }

    @Test("process diagnostics include every stderr line")
    func processDiagnosticsIncludeStandardErrorLines() {
        let projectURL = URL(fileURLWithPath: "/tmp/Game", isDirectory: true)
        let command = EditorProcessCommand(executablePath: "/usr/bin/swift", arguments: ["package", "resolve"], workingDirectory: projectURL)
        let result = EditorProcessResult(
            command: command,
            exitCode: 0,
            standardOutput: "/tmp/Game/Sources/Game/main.swift:3:12: warning: unused value\n",
            standardError: """
                Fetching https://example.com/Dependency.git
                /tmp/Game/Sources/Game/main.swift:4:8: error: cannot find 'bar' in scope
                """
        )

        let diagnostics = EditorDiagnostic.diagnostics(from: result, projectURL: projectURL)

        #expect(
            diagnostics.map(\.message) == [
                "unused value",
                "Fetching https://example.com/Dependency.git",
                "cannot find 'bar' in scope",
            ]
        )
        #expect(diagnostics.map(\.severity) == [.warning, .information, .error])
        #expect(diagnostics[1].filePath == "/tmp/Game/Package.swift")
    }

    @Test("LSP semantic tokens decode delta encoded response")
    func semanticTokensDecode() {
        let response: JSONRPCValue = .object([
            "data": .array([.int(0), .int(0), .int(6), .int(15), .int(0), .int(1), .int(4), .int(4), .int(18), .int(0)])
        ])

        let tokens = SourceKitLSPClient.decodeSemanticTokens(
            from: response,
            legend: [
                "namespace", "type", "class", "enum", "interface", "struct", "typeParameter", "parameter", "variable", "property",
                "enumMember", "event", "function", "method", "macro", "keyword", "modifier", "comment", "string",
            ],
            modifiersLegend: []
        )

        #expect(
            tokens == [
                EditorSemanticToken(line: 0, startCharacter: 0, length: 6, type: "keyword", modifiers: []),
                EditorSemanticToken(line: 1, startCharacter: 4, length: 4, type: "string", modifiers: []),
            ]
        )
    }

    @Test("LSP completion decodes list results and text edits")
    func completionDecode() {
        let items = SourceKitLSPClient.decodeCompletionItems(
            from: .object([
                "isIncomplete": .bool(false),
                "items": .array([
                    .object([
                        "label": .string("update"),
                        "detail": .string("func update()"),
                        "kind": .int(2),
                        "sortText": .string("002"),
                        "textEdit": .object([
                            "newText": .string("update()"),
                            "range": sourceRange(4, 8, 4, 10),
                        ]),
                    ]),
                    .object([
                        "label": .string("upAxis"),
                        "insertText": .string("upAxis"),
                        "kind": .int(10),
                        "sortText": .string("001"),
                    ]),
                ]),
            ])
        )

        #expect(items.map(\.label) == ["upAxis", "update"])
        #expect(items.map(\.kind) == [.property, .method])
        #expect(items[1].insertText == "update()")
        #expect(
            items[1].replacementRange
                == EditorSourceRange(
                    start: EditorSourceLocation(line: 4, character: 8),
                    end: EditorSourceLocation(line: 4, character: 10)
                )
        )
    }

    @Test("LSP publish diagnostics decodes severity and canonical source")
    func publishDiagnosticsDecode() throws {
        let result = try #require(
            SourceKitLSPClient.decodePublishedDiagnostics(
                from: .object([
                    "uri": .string("file:///tmp/Game/Sources/Game/main.swift"),
                    "diagnostics": .array([
                        .object([
                            "range": sourceRange(2, 4, 2, 10),
                            "severity": .int(1),
                            "source": .string("swift"),
                            "message": .string("cannot find 'player' in scope"),
                        ])
                    ]),
                ])
            )
        )

        #expect(result.uri == "file:///tmp/Game/Sources/Game/main.swift")
        #expect(result.diagnostics.count == 1)
        #expect(result.diagnostics[0].filePath == "/tmp/Game/Sources/Game/main.swift")
        #expect(result.diagnostics[0].severity == .error)
        #expect(result.diagnostics[0].source == "sourcekit-lsp")
    }

    @Test("LSP document updates are versioned and completion uses UTF-16 positions")
    @MainActor
    func sourceKitDocumentChangeAndUnicodeCompletion() async throws {
        let connection = FakeSourceKitLSPConnection(responses: [
            "textDocument/completion": .array([
                .object([
                    "label": .string("update"),
                    "textEdit": .object([
                        "newText": .string("update"),
                        "range": sourceRange(0, 2, 0, 4),
                    ]),
                ])
            ]),
            "textDocument/semanticTokens/full": .object([
                "data": .array([.int(0), .int(2), .int(2), .int(8), .int(0)])
            ]),
            "textDocument/documentHighlight": .array([
                .object(["range": sourceRange(0, 2, 0, 4), "kind": .int(1)])
            ]),
            "textDocument/hover": .object([
                "contents": .object([
                    "kind": .string("markdown"),
                    "value": .string("func update()"),
                ]),
                "range": sourceRange(0, 2, 0, 4),
            ]),
            "textDocument/references": .array([]),
        ])
        let client = SourceKitLSPClient(connection: connection)
        let fileURL = URL(fileURLWithPath: "/tmp/Game/Sources/Game/main.swift")
        try await client.start(
            toolchain: SwiftToolchain(swiftExecutablePath: "/usr/bin/swift", sourceKitLSPExecutablePath: "/usr/bin/sourcekit-lsp"),
            projectURL: URL(fileURLWithPath: "/tmp/Game", isDirectory: true)
        )
        try await client.openDocument(fileURL: fileURL, language: .swift, text: "😀u")
        try await client.openDocument(fileURL: fileURL, language: .swift, text: "😀up")
        let items = try await client.completion(fileURL: fileURL, position: EditorSourceLocation(line: 0, character: 3))
        let tokens = try await client.refreshSemanticTokens(fileURL: fileURL)
        let highlights = try await client.documentHighlights(fileURL: fileURL, position: EditorSourceLocation(line: 0, character: 3))
        let hover = try await client.hover(fileURL: fileURL, position: EditorSourceLocation(line: 0, character: 3))
        _ = try await client.references(fileURL: fileURL, position: EditorSourceLocation(line: 0, character: 3))
        let notifications = await connection.notifications
        let requests = await connection.requests

        let initializeParams = try #require(requests.first { $0.method == "initialize" }?.params)
        guard
            case let .object(initializeObject) = initializeParams,
            case let .array(workspaceFolders)? = initializeObject["workspaceFolders"],
            case let .object(workspaceFolder)? = workspaceFolders.first,
            case let .object(capabilities)? = initializeObject["capabilities"],
            case let .object(experimentalCapabilities)? = capabilities["experimental"],
            case let .object(workspaceCapabilities)? = capabilities["workspace"],
            case let .object(textDocumentCapabilities)? = capabilities["textDocument"],
            case let .object(semanticTokenCapabilities)? = textDocumentCapabilities["semanticTokens"]
        else {
            Issue.record("Expected SourceKit-LSP workspace and semantic token initialize capabilities")
            return
        }
        #expect(workspaceFolder["name"] == .string("Game"))
        #expect(workspaceFolder["uri"] == .string(URL(fileURLWithPath: "/tmp/Game", isDirectory: true).absoluteString))
        #expect(workspaceCapabilities["workspaceFolders"] == .bool(true))
        #expect(
            experimentalCapabilities["sourcekit/workspace/getReferenceDocument"]
                == .object(["supported": .bool(true)])
        )
        #expect(semanticTokenCapabilities["formats"] == .array([.string("relative")]))
        let preparationParams = try #require(requests.first { $0.method == "workspace/_sourceKitOptions" }?.params)
        guard case let .object(preparationObject) = preparationParams else {
            Issue.record("Expected SourceKit-LSP document preparation parameters")
            return
        }
        #expect(preparationObject["prepareTarget"] == .bool(true))
        #expect(preparationObject["allowFallbackSettings"] == .bool(false))
        #expect(requests.contains { $0.method == "workspace/synchronize" })

        #expect(notifications.map(\.method).contains("textDocument/didOpen"))
        let change = try #require(notifications.first { $0.method == "textDocument/didChange" }?.params)
        guard
            case let .object(changeObject) = change,
            case let .object(versionedDocument)? = changeObject["textDocument"]
        else {
            Issue.record("Expected versioned didChange parameters")
            return
        }
        #expect(versionedDocument["version"] == .int(2))

        let completionParams = try #require(requests.last { $0.method == "textDocument/completion" }?.params)
        guard
            case let .object(completionObject) = completionParams,
            case let .object(position)? = completionObject["position"]
        else {
            Issue.record("Expected completion position parameters")
            return
        }
        #expect(position["character"] == .int(4))
        #expect(
            items.first?.replacementRange
                == EditorSourceRange(
                    start: EditorSourceLocation(line: 0, character: 1),
                    end: EditorSourceLocation(line: 0, character: 3)
                )
        )
        let applied = try #require(EditorViewModel.applyingCompletion(items[0], to: "😀up", at: EditorSourceLocation(line: 0, character: 3)))
        #expect(applied.text == "😀update")
        #expect(tokens.first?.startCharacter == 1)
        #expect(tokens.first?.length == 2)
        #expect(
            highlights.first?.range
                == EditorSourceRange(
                    start: EditorSourceLocation(line: 0, character: 1),
                    end: EditorSourceLocation(line: 0, character: 3)
                )
        )
        #expect(
            hover?.range
                == EditorSourceRange(
                    start: EditorSourceLocation(line: 0, character: 1),
                    end: EditorSourceLocation(line: 0, character: 3)
                )
        )
        let referencesParams = try #require(requests.last { $0.method == "textDocument/references" }?.params)
        guard
            case let .object(referencesObject) = referencesParams,
            case let .object(referencesPosition)? = referencesObject["position"]
        else {
            Issue.record("Expected references position parameters")
            return
        }
        #expect(referencesPosition["character"] == .int(4))
    }

    @Test("LSP transport routes server requests before colliding response IDs")
    func sourceKitServerRequestRouting() {
        #expect(SourceKitLSPStdioConnection.launchArguments == ["--experimental-feature", "sourcekit-options-request"])
        let route = SourceKitLSPStdioConnection.route(for: [
            "jsonrpc": .string("2.0"),
            "id": .int(1),
            "method": .string("workspace/configuration"),
            "params": .object(["items": .array([])]),
        ])

        #expect(route == .serverMessage(method: "workspace/configuration", id: .int(1)))
        #expect(SourceKitLSPStdioConnection.route(for: ["jsonrpc": .string("2.0"), "id": .int(1), "result": .null]) == .response(id: 1))
    }

    @Test("completion application replaces the LSP range or inferred identifier prefix")
    @MainActor
    func completionApplication() throws {
        let explicit = try #require(
            EditorViewModel.applyingCompletion(
                EditorCompletionItem(
                    label: "update",
                    detail: nil,
                    insertText: "update()",
                    replacementRange: EditorSourceRange(
                        start: EditorSourceLocation(line: 1, character: 8),
                        end: EditorSourceLocation(line: 1, character: 10)
                    ),
                    sortText: nil
                ),
                to: "struct Game {\n    let up\n}",
                at: EditorSourceLocation(line: 1, character: 10)
            )
        )
        let inferred = try #require(
            EditorViewModel.applyingCompletion(
                EditorCompletionItem(label: "player", detail: nil, insertText: "player", replacementRange: nil, sortText: nil),
                to: "let pla = 1",
                at: EditorSourceLocation(line: 0, character: 7)
            )
        )
        let multiline = try #require(
            EditorViewModel.applyingCompletion(
                EditorCompletionItem(label: "func", detail: nil, insertText: "func main() {\n}", replacementRange: nil, sortText: nil),
                to: "fu",
                at: EditorSourceLocation(line: 0, character: 2)
            )
        )

        #expect(explicit.text == "struct Game {\n    let update()\n}")
        #expect(explicit.caret == EditorSourceLocation(line: 1, character: 16))
        #expect(inferred.text == "let player = 1")
        #expect(multiline.text == "func main() {\n}")
        #expect(multiline.caret == EditorSourceLocation(line: 1, character: 1))
    }

    @Test("LSP definition decodes location and location links")
    func definitionDecode() {
        let response: JSONRPCValue = .array([
            .object([
                "uri": .string("file:///tmp/Game/Sources/Game/main.swift"),
                "range": sourceRange(2, 4, 2, 12),
            ]),
            .object([
                "targetUri": .string("file:///tmp/Game/Sources/Game/Player.swift"),
                "targetRange": sourceRange(10, 0, 20, 1),
                "targetSelectionRange": sourceRange(12, 9, 12, 15),
            ]),
        ])

        let targets = SourceKitLSPClient.decodeDefinitionTargets(from: response)

        #expect(targets.count == 2)
        #expect(targets[0].filePath == "/tmp/Game/Sources/Game/main.swift")
        #expect(targets[0].selectionRange.start.line == 2)
        #expect(targets[1].filePath == "/tmp/Game/Sources/Game/Player.swift")
        #expect(targets[1].selectionRange.start.character == 9)
    }

    @Test("SourceKit generated interfaces are requested and attached to definitions")
    func generatedInterfaceDefinition() async throws {
        let uri = "sourcekit-lsp://generated-swift-interface/Foundation.swiftinterface?moduleName=Foundation"
        let interface = "/// A notification delivery center.\npublic class NotificationCenter {}\n"
        let connection = FakeSourceKitLSPConnection(responses: [
            "textDocument/definition": .object([
                "targetUri": .string(uri),
                "targetRange": sourceRange(0, 0, 1, 34),
                "targetSelectionRange": sourceRange(1, 13, 1, 31),
            ]),
            "sourcekit/workspace/getReferenceDocument": .object([
                "content": .string(interface)
            ]),
        ])
        let client = SourceKitLSPClient(connection: connection)
        let projectURL = URL(fileURLWithPath: "/tmp/Game", isDirectory: true)
        let fileURL = projectURL.appendingPathComponent("Sources/Game/main.swift")
        try await client.start(
            toolchain: SwiftToolchain(swiftExecutablePath: "/usr/bin/swift", sourceKitLSPExecutablePath: "/usr/bin/sourcekit-lsp"),
            projectURL: projectURL
        )

        let targets = try await client.definition(fileURL: fileURL, position: EditorSourceLocation(line: 0, character: 4))
        let target = try #require(targets.first)
        #expect(target.uri == uri)
        #expect(target.content == interface)
        #expect(target.selectionRange == EditorSourceRange(
            start: EditorSourceLocation(line: 1, character: 13),
            end: EditorSourceLocation(line: 1, character: 31)
        ))
        let requests = await connection.requests
        #expect(requests.contains { $0.method == "sourcekit/workspace/getReferenceDocument" })
    }

    @Test("LSP references hover and document highlights decode")
    func symbolFeatureDecoders() {
        let references = SourceKitLSPClient.decodeReferences(
            from: .array([
                .object([
                    "uri": .string("file:///tmp/Game/Sources/Game/main.swift"),
                    "range": sourceRange(3, 2, 3, 8),
                ])
            ])
        )
        let hover = SourceKitLSPClient.decodeHover(
            from: .object([
                "contents": .object([
                    "kind": .string("markdown"),
                    "value": .string("func update()"),
                ]),
                "range": sourceRange(3, 2, 3, 8),
            ])
        )
        let highlights = SourceKitLSPClient.decodeDocumentHighlights(
            from: .array([
                .object([
                    "range": sourceRange(3, 2, 3, 8),
                    "kind": .int(3),
                ])
            ])
        )

        #expect(references.map(\.filePath) == ["/tmp/Game/Sources/Game/main.swift"])
        #expect(hover?.contents == "func update()")
        #expect(hover?.range?.start.character == 2)
        #expect(
            highlights == [
                EditorDocumentHighlight(
                    range: EditorSourceRange(
                        start: EditorSourceLocation(line: 3, character: 2),
                        end: EditorSourceLocation(line: 3, character: 8)
                    ),
                    kind: .write
                )
            ]
        )
    }

    @Test("package manifest editor adds executable target")
    func manifestEditorAddsExecutableTarget() throws {
        let result = try PackageManifestEditor.edit(simpleManifest, command: .addExecutableTarget(name: "Game", dependencies: ["AdaEngine"]))

        #expect(result.changed)
        #expect(result.manifest.contains(#".executable(name: "Game", targets: ["Game"])"#))
        #expect(result.manifest.contains(#".executableTarget(name: "Game", dependencies: ["AdaEngine"])"#))
    }

    @Test("package manifest editor adds dependency plugin and tests")
    func manifestEditorAddsPackageItems() throws {
        var manifest = simpleManifest
        manifest = try PackageManifestEditor.edit(manifest, command: .addDependency(url: "https://example.com/lib.git", requirement: #"from: "1.0.0""#)).manifest
        manifest = try PackageManifestEditor.edit(manifest, command: .addPlugin(name: "ShaderPlugin", capability: ".buildTool()")).manifest
        manifest = try PackageManifestEditor.edit(manifest, command: .addTestTarget(name: "GameTests", dependencies: ["Game"])).manifest

        #expect(manifest.contains(#".package(url: "https://example.com/lib.git", from: "1.0.0")"#))
        #expect(manifest.contains(#".plugin(name: "ShaderPlugin", targets: ["ShaderPlugin"])"#))
        #expect(manifest.contains(#".plugin(name: "ShaderPlugin", capability: .buildTool(), dependencies: [])"#))
        #expect(manifest.contains(#".testTarget(name: "GameTests", dependencies: ["Game"])"#))
    }

    @Test("package manifest editor adds asset resources to executable target")
    func manifestEditorAddsAssetResources() throws {
        let result = try PackageManifestEditor.edit(
            simpleManifestWithExecutableTarget,
            command: .ensureAssetResources(targetName: nil, assetsPath: "Assets")
        )
        let secondResult = try PackageManifestEditor.edit(
            result.manifest,
            command: .ensureAssetResources(targetName: nil, assetsPath: "Assets")
        )

        #expect(result.changed)
        #expect(result.manifest.contains(#"path: ".""#))
        #expect(result.manifest.contains(#"sources: ["Sources/Game"]"#))
        #expect(result.manifest.contains(#"resources: [.copy("Assets")]"#))
        #expect(!secondResult.changed)
    }

    @Test("package manifest editor requires target when executable target is ambiguous")
    func manifestEditorRequiresTargetForAmbiguousExecutables() throws {
        do {
            _ = try PackageManifestEditor.edit(
                multiExecutableManifest,
                command: .ensureAssetResources(targetName: nil, assetsPath: "Assets")
            )
            Issue.record("Expected manifest edit to throw")
        } catch let error as PackageManifestEditError {
            #expect(error.structuredDescription.contains("unsupportedManifestShape"))
        }

        let result = try PackageManifestEditor.edit(
            multiExecutableManifest,
            command: .ensureAssetResources(targetName: "Tools", assetsPath: "Assets")
        )
        #expect(result.manifest.contains(#".executableTarget(name: "Tools", dependencies: [], path: ".", sources: ["Sources/Tools"], resources: [.copy("Assets")])"#))
    }

    @Test("package manifest editor adds and removes real dependencies by normalized identity")
    func manifestEditorAddsAndRemovesDependencies() throws {
        var manifest =
            try PackageManifestEditor.edit(
                simpleManifestWithExecutableTarget,
                command: .addLocalDependency(name: "My_Library", path: "../MyLibrary")
            )
            .manifest
        manifest =
            try PackageManifestEditor.edit(
                manifest,
                command: .addDependency(url: "https://example.com/Other-Library.git", requirement: #"from: "1.2.0""#)
            )
            .manifest

        let removedLocal = try PackageManifestEditor.edit(manifest, command: .removeDependency(identity: "my-library"))
        let removedRemote = try PackageManifestEditor.edit(removedLocal.manifest, command: .removeDependency(identity: "OTHER_library.git"))

        #expect(removedLocal.changed)
        #expect(!removedLocal.manifest.contains("My_Library"))
        #expect(removedRemote.changed)
        #expect(!removedRemote.manifest.contains("Other-Library.git"))
        #expect(try !PackageManifestEditor.edit(removedRemote.manifest, command: .removeDependency(identity: "other-library")).changed)
    }

    @Test("removing a dependency also removes target product references")
    func manifestEditorRemovesProductReferences() throws {
        let withAdaEngine = try PackageManifestEditor.edit(
            simpleManifestWithExecutableTarget,
            command: .ensureAdaEngineDependency(path: "/tmp/AdaEngine", targetName: "Game")
        )
        let removed = try PackageManifestEditor.edit(withAdaEngine.manifest, command: .removeDependency(identity: "ADAENGINE"))

        #expect(withAdaEngine.manifest.contains(#".package(name: "AdaEngine", path: "/tmp/AdaEngine")"#))
        #expect(withAdaEngine.manifest.contains(#".product(name: "AdaEngine", package: "AdaEngine")"#))
        #expect(!removed.manifest.contains(#"package: "AdaEngine""#))
        #expect(!removed.manifest.contains(#"name: "AdaEngine""#))
    }

    @Test("AdaEngine synchronization links every executable and is idempotent")
    func manifestEditorEnsuresAdaEngineForEveryExecutable() throws {
        let first = try PackageManifestEditor.edit(
            multiExecutableManifest,
            command: .ensureAdaEngineDependency(path: "/tmp/AdaEngine", targetName: nil)
        )
        let second = try PackageManifestEditor.edit(
            first.manifest,
            command: .ensureAdaEngineDependency(path: "/tmp/AdaEngine", targetName: nil)
        )

        #expect(first.changed)
        #expect(first.manifest.components(separatedBy: #".product(name: "AdaEngine", package: "AdaEngine")"#).count - 1 == 2)
        #expect(!second.changed)
    }

    @Test("target configuration synchronizes sources excludes and resources")
    func manifestEditorConfiguresTargetBuildSelection() throws {
        let first = try PackageManifestEditor.edit(
            packageRootTargetManifest,
            command: .configureTarget(
                name: "Game",
                sources: ["Sources/Game", "Sources/Shared.swift"],
                exclude: ["Sources/Game/Drafts"],
                resources: ["Assets", "Localization"]
            )
        )
        let second = try PackageManifestEditor.edit(
            first.manifest,
            command: .configureTarget(
                name: "Game",
                sources: ["Sources/Game", "Sources/Shared.swift"],
                exclude: ["Sources/Game/Drafts"],
                resources: ["Assets", "Localization"]
            )
        )

        #expect(first.manifest.contains(#"sources: ["Sources/Game", "Sources/Shared.swift"]"#))
        #expect(first.manifest.contains(#"exclude: ["Sources/Game/Drafts"]"#))
        #expect(first.manifest.contains(#"resources: [.copy("Assets"), .copy("Localization")]"#))
        #expect(!second.changed)
    }

    @Test("target configuration converts project-relative paths for an implicit target root")
    func manifestEditorNormalizesImplicitTargetPaths() throws {
        let result = try PackageManifestEditor.edit(
            standardImplicitTargetManifest,
            command: .configureTarget(
                name: "Game",
                sources: ["Sources/Game/main.swift", "Sources/Game/Gameplay"],
                exclude: ["Sources/Game/Drafts"],
                resources: ["Sources/Game/Assets"]
            )
        )

        #expect(result.manifest.contains(#"sources: ["main.swift", "Gameplay"]"#))
        #expect(result.manifest.contains(#"exclude: ["Drafts"]"#))
        #expect(result.manifest.contains(#"resources: [.copy("Assets")]"#))
        #expect(!result.manifest.contains(#"sources: ["Sources/Game/main.swift""#))
    }

    @Test("external project resources remain relative to an implicit target root")
    func manifestEditorKeepsImplicitTargetForProjectResources() throws {
        let result = try PackageManifestEditor.edit(
            standardImplicitTargetManifest,
            command: .configureTarget(name: "Game", sources: [], exclude: [], resources: ["Assets"])
        )

        #expect(!result.manifest.contains(#"path: ".""#))
        #expect(!result.manifest.contains("\n            sources:"))
        #expect(result.manifest.contains(#"resources: [.copy("../../Assets")]"#))
    }

    @Test("remote dependency requirements are validated before editing")
    func manifestEditorRejectsUnsafeRequirements() {
        let invalidRequirements = ["", "from: latest", #"from: "1""#, #"branch: "main", products: []"#]
        for requirement in invalidRequirements {
            do {
                _ = try PackageManifestEditor.edit(
                    simpleManifest,
                    command: .addDependency(url: "https://example.com/lib.git", requirement: requirement)
                )
                Issue.record("Expected requirement to be rejected: \(requirement)")
            } catch let error as PackageManifestEditError {
                #expect(error.structuredDescription.contains("invalidArgument"))
            } catch {
                Issue.record("Unexpected error: \(error)")
            }
        }
    }

    @Test("candidate manifest syntax is validated after editing")
    func manifestEditorRejectsSyntacticallyInvalidCandidate() {
        do {
            _ = try PackageManifestEditor.edit(
                simpleManifest,
                command: .addDependency(url: "https://example.com/\nlib.git", requirement: #"branch: "main""#)
            )
            Issue.record("Expected invalid candidate manifest to be rejected")
        } catch let error as PackageManifestEditError {
            #expect(error == .invalidSwiftSyntax)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}

private actor OutputEventCollector {
    var events: [EditorProcessOutputEvent] = []

    func append(_ event: EditorProcessOutputEvent) {
        events.append(event)
    }
}

private struct FakeSourceKitLSPCall: Sendable {
    var method: String
    var params: JSONRPCValue?
}

private actor FakeSourceKitLSPConnection: SourceKitLSPConnecting {
    private let responses: [String: JSONRPCValue]
    private(set) var requests: [FakeSourceKitLSPCall] = []
    private(set) var notifications: [FakeSourceKitLSPCall] = []
    private(set) var stopCount = 0
    private var notificationHandler: (@Sendable (String, JSONRPCValue?) async -> Void)?

    init(completionResponse: JSONRPCValue) {
        self.responses = ["textDocument/completion": completionResponse]
    }

    init(responses: [String: JSONRPCValue]) {
        self.responses = responses
    }

    func start(executablePath _: String, projectURL _: URL) {}

    func request(method: String, params: JSONRPCValue?) -> JSONRPCValue? {
        requests.append(FakeSourceKitLSPCall(method: method, params: params))
        if method == "workspace/_sourceKitOptions" {
            return .object(["kind": .string("normal")])
        }
        if method == "workspace/synchronize" {
            return .null
        }
        return responses[method] ?? .object([:])
    }

    func notify(method: String, params: JSONRPCValue?) async {
        notifications.append(FakeSourceKitLSPCall(method: method, params: params))
        await notificationHandler?(method, params)
    }

    func setNotificationHandler(_ handler: (@Sendable (String, JSONRPCValue?) async -> Void)?) {
        notificationHandler = handler
    }

    func stop() {
        stopCount += 1
    }
}

private actor FakeProcessRunner: EditorProcessRunning {
    var commands: [EditorProcessCommand] = []
    private(set) var cancelCount = 0
    private var results: [EditorProcessResult]
    private var outputChunks: [[EditorProcessOutputEvent]]
    private let onRun: (@Sendable (EditorProcessCommand) -> Void)?

    init(
        results: [EditorProcessResult],
        outputChunks: [[EditorProcessOutputEvent]] = [],
        onRun: (@Sendable (EditorProcessCommand) -> Void)? = nil
    ) {
        self.results = results
        self.outputChunks = outputChunks
        self.onRun = onRun
    }

    func run(_ command: EditorProcessCommand) async -> EditorProcessResult {
        await run(command) { _ in }
    }

    func run(_ command: EditorProcessCommand, output: @Sendable @escaping (EditorProcessOutputEvent) async -> Void) async -> EditorProcessResult {
        commands.append(command)
        onRun?(command)
        if !outputChunks.isEmpty {
            for event in outputChunks.removeFirst() {
                await output(event)
            }
        }
        if !results.isEmpty {
            return results.removeFirst()
        }
        return EditorProcessResult(command: command, exitCode: 0, standardOutput: "", standardError: "")
    }

    func semanticTokens(fileURL _: URL, language _: EditorSourceLanguage, text _: String) async -> [EditorSemanticToken] {
        []
    }

    func cancelAll() {
        cancelCount += 1
    }
}

private actor WorkspaceOutputRecorder {
    private(set) var events: [EditorProcessOutputEvent] = []

    func append(_ event: EditorProcessOutputEvent) {
        events.append(event)
    }
}

private actor WorkspaceProgressRecorder {
    private(set) var updates: [SwiftPMWorkspaceProgress] = []

    func append(_ update: SwiftPMWorkspaceProgress) {
        updates.append(update)
    }
}

private actor RecordingWorkspaceService: SwiftPMWorkspaceServicing {
    private(set) var bootstrapCallCount = 0
    private(set) var commands: [SwiftPMCommandKind] = []
    private(set) var completionRequests: [(position: EditorSourceLocation, text: String)] = []
    private let hoverResponse: EditorSymbolHover?
    private let definitionResponse: [EditorSourceSymbolTarget]
    private let documentHighlightResponse: [EditorDocumentHighlight]
    private let outputEvents: [EditorProcessOutputEvent]

    init(
        hoverResponse: EditorSymbolHover? = nil,
        definitionResponse: [EditorSourceSymbolTarget] = [],
        documentHighlightResponse: [EditorDocumentHighlight] = [],
        outputEvents: [EditorProcessOutputEvent] = []
    ) {
        self.hoverResponse = hoverResponse
        self.definitionResponse = definitionResponse
        self.documentHighlightResponse = documentHighlightResponse
        self.outputEvents = outputEvents
    }

    nonisolated func makeCommand(_ kind: SwiftPMCommandKind, projectURL: URL, toolchain: SwiftToolchain) -> EditorProcessCommand {
        SwiftPMWorkspaceService().makeCommand(kind, projectURL: projectURL, toolchain: toolchain)
    }

    func bootstrap(projectURL: URL) -> SwiftPMBootstrapResult {
        bootstrapCallCount += 1
        let toolchain = SwiftToolchain(swiftExecutablePath: "swift", sourceKitLSPExecutablePath: nil)
        let resolve = EditorProcessResult(
            command: makeCommand(.resolve, projectURL: projectURL, toolchain: toolchain),
            exitCode: 0,
            standardOutput: "",
            standardError: ""
        )
        return SwiftPMBootstrapResult(
            toolchain: toolchain,
            resolveResult: resolve,
            packageModel: nil,
            describeResult: resolve,
            indexBuildResult: nil,
            diagnostics: []
        )
    }

    func execute(_ kind: SwiftPMCommandKind, projectURL: URL) -> EditorProcessResult {
        commands.append(kind)
        return result(for: kind, projectURL: projectURL)
    }

    func execute(
        _ kind: SwiftPMCommandKind,
        projectURL: URL,
        output: @Sendable @escaping (EditorProcessOutputEvent) async -> Void
    ) async -> EditorProcessResult {
        commands.append(kind)
        for event in outputEvents {
            await output(event)
        }
        return result(for: kind, projectURL: projectURL)
    }

    private func result(for kind: SwiftPMCommandKind, projectURL: URL) -> EditorProcessResult {
        let toolchain = SwiftToolchain(swiftExecutablePath: "swift", sourceKitLSPExecutablePath: nil)
        return EditorProcessResult(
            command: makeCommand(kind, projectURL: projectURL, toolchain: toolchain),
            exitCode: 0,
            standardOutput: "",
            standardError: ""
        )
    }

    func semanticTokens(fileURL _: URL, language _: EditorSourceLanguage, text _: String) -> [EditorSemanticToken] { [] }
    func completions(fileURL _: URL, language _: EditorSourceLanguage, text: String, position: EditorSourceLocation) -> [EditorCompletionItem] {
        completionRequests.append((position, text))
        return []
    }
    func definition(fileURL _: URL, language _: EditorSourceLanguage, text _: String, position _: EditorSourceLocation) -> [EditorSourceSymbolTarget] {
        definitionResponse
    }
    func references(fileURL _: URL, language _: EditorSourceLanguage, text _: String, position _: EditorSourceLocation) -> [EditorSourceReference] { [] }
    func hover(fileURL _: URL, language _: EditorSourceLanguage, text _: String, position _: EditorSourceLocation) -> EditorSymbolHover? { hoverResponse }
    func documentHighlights(fileURL _: URL, language _: EditorSourceLanguage, text _: String, position _: EditorSourceLocation) -> [EditorDocumentHighlight] {
        documentHighlightResponse
    }
    func cancel() {}
}

private func waitForRecordedCommands(_ service: RecordingWorkspaceService, count: Int) async throws {
    for _ in 0..<500 {
        if await service.commands.count >= count {
            return
        }
        try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("Timed out waiting for \(count) workspace commands")
}

private func waitForCompletionRequests(_ service: RecordingWorkspaceService, count: Int) async throws {
    for _ in 0..<500 {
        if await service.completionRequests.count >= count {
            return
        }
        try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("Timed out waiting for \(count) completion requests")
}

private func testDiagnostic(message: String, source: String) -> EditorDiagnostic {
    EditorDiagnostic(
        filePath: "/tmp/Game/main.swift",
        range: EditorSourceRange(
            start: EditorSourceLocation(line: 0, character: 0),
            end: EditorSourceLocation(line: 0, character: 1)
        ),
        severity: .error,
        message: message,
        source: source
    )
}

private func findFirstFile(named fileName: String, under root: URL, fileManager: FileManager) -> URL? {
    guard
        let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
    else {
        return nil
    }

    for case let url as URL in enumerator where url.lastPathComponent == fileName {
        return url
    }

    return nil
}

private func adaEnginePackageURL() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .standardizedFileURL
}

private func previewDirectoryName(relativePath: String, declarationID: String) -> String {
    let value = "\(relativePath)-\(declarationID)"
    let scalarSum = value.unicodeScalars.reduce(UInt64(5381)) { partial, scalar in
        ((partial << 5) &+ partial) &+ UInt64(scalar.value)
    }
    return "\(declarationID)-\(String(scalarSum, radix: 16))"
}

private let packageDescriptionJSON = """
    {
      "name": "Game",
      "dependencies": [
        {"identity":"adaengine","type":"fileSystem","path":"../AdaEngine"}
      ],
      "products": [
        {"name":"Game","targets":["Game"],"type":{"executable":null}},
        {"name":"GamePlugin","targets":["GamePlugin"],"type":{"plugin":null}}
      ],
      "targets": [
        {"name":"Game","type":"executable","path":"Sources/Game","sources":["main.swift"],"target_dependencies":[],"product_dependencies":["AdaEngine"]},
        {"name":"GameTests","type":"test","path":"Tests/GameTests","sources":["GameTests.swift"],"target_dependencies":["Game"],"product_dependencies":[]},
        {"name":"GamePlugin","type":"plugin","path":"Plugins/GamePlugin","sources":["main.swift"],"target_dependencies":[],"product_dependencies":[]}
      ]
    }
    """

private let simpleManifest = """
    // swift-tools-version: 6.2
    import PackageDescription

    let package = Package(
        name: "Game",
        products: [
        ],
        dependencies: [
        ],
        targets: [
        ]
    )
    """

private let simpleManifestWithExecutableTarget = """
    // swift-tools-version: 6.2
    import PackageDescription

    let package = Package(
        name: "Game",
        products: [
            .executable(name: "Game", targets: ["Game"])
        ],
        dependencies: [
        ],
        targets: [
            .executableTarget(name: "Game", dependencies: [])
        ]
    )
    """

private let multiExecutableManifest = """
    // swift-tools-version: 6.2
    import PackageDescription

    let package = Package(
        name: "Game",
        products: [
            .executable(name: "Game", targets: ["Game"]),
            .executable(name: "Tools", targets: ["Tools"])
        ],
        dependencies: [
        ],
        targets: [
            .executableTarget(name: "Game", dependencies: []),
            .executableTarget(name: "Tools", dependencies: [])
        ]
    )
    """

private let standardImplicitTargetManifest = """
    // swift-tools-version: 6.2
    import PackageDescription

    let package = Package(
        name: "Game",
        products: [.executable(name: "Game", targets: ["Game"])],
        dependencies: [],
        targets: [.executableTarget(name: "Game", dependencies: [])]
    )
    """

private let packageRootTargetManifest = """
    // swift-tools-version: 6.2
    import PackageDescription

    let package = Package(
        name: "Game",
        products: [.executable(name: "Game", targets: ["Game"])],
        dependencies: [],
        targets: [.executableTarget(name: "Game", dependencies: [], path: ".")]
    )
    """

private func sourceRange(_ startLine: Int, _ startCharacter: Int, _ endLine: Int, _ endCharacter: Int) -> JSONRPCValue {
    .object([
        "start": .object([
            "line": .int(startLine),
            "character": .int(startCharacter),
        ]),
        "end": .object([
            "line": .int(endLine),
            "character": .int(endCharacter),
        ]),
    ])
}
