import Foundation
import Testing

@testable import AdaEditor

@Suite("Editor real workspace")
struct EditorRealWorkspaceTests {
    @Test("real project tree contains root files and never falls back to samples")
    @MainActor
    func projectTreeUsesOnlyDiskEntries() throws {
        let projectURL = try makeRealWorkspaceDirectory(named: "RealTree")
        defer { removeRealWorkspaceDirectory(projectURL) }

        try "// swift-tools-version: 6.2\n"
            .write(
                to: projectURL.appendingPathComponent("Package.swift"),
                atomically: true,
                encoding: .utf8
            )
        try "# Real project\n"
            .write(
                to: projectURL.appendingPathComponent("README.md"),
                atomically: true,
                encoding: .utf8
            )
        let sourceDirectory = projectURL.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        let realContent = "let sourceOfTruth = \"disk\"\n"
        try realContent.write(
            to: sourceDirectory.appendingPathComponent("EngineLoop.ada"),
            atomically: true,
            encoding: .utf8
        )
        let ignoredBuildDirectory = projectURL.appendingPathComponent(".build", isDirectory: true)
        try FileManager.default.createDirectory(at: ignoredBuildDirectory, withIntermediateDirectories: true)
        try "mock"
            .write(
                to: ignoredBuildDirectory.appendingPathComponent("Generated.swift"),
                atomically: true,
                encoding: .utf8
            )

        var metadata = ProjectSystem.defaultProject(projectName: "RealTree")
        metadata.paths.sources = "src"
        try ProjectSystem.saveProject(metadata, at: projectURL)

        let project = EditorProjectReference(name: "RealTree", path: projectURL.path)
        let viewModel = EditorViewModel(project: project)

        #expect(viewModel.workbench.openDocuments.isEmpty)
        #expect(viewModel.projectSidebar.items.contains { $0.relativePath == "Package.swift" })
        #expect(viewModel.projectSidebar.items.contains { $0.relativePath == "README.md" })
        #expect(!viewModel.projectSidebar.items.contains { $0.relativePath.hasPrefix(".ada") })
        #expect(!viewModel.projectSidebar.items.contains { $0.relativePath.hasPrefix(".build") })

        let sourceItem = try #require(viewModel.projectSidebar.items.first { $0.relativePath == "src/EngineLoop.ada" })
        viewModel.openProjectItem(sourceItem)
        guard case let .text(document) = viewModel.workbench.activeDocument else {
            Issue.record("Expected a real text document")
            return
        }
        #expect(document.content == realContent)
        #expect(document.absolutePath == sourceItem.id)
        #expect(!document.content.contains("Game simulation entry point"))
    }

    @Test("empty real project stays empty")
    @MainActor
    func emptyProjectDoesNotShowSampleFiles() throws {
        let projectURL = try makeRealWorkspaceDirectory(named: "EmptyTree")
        defer { removeRealWorkspaceDirectory(projectURL) }

        let project = EditorProjectReference(name: "EmptyTree", path: projectURL.path)
        let viewModel = EditorViewModel(project: project)

        #expect(viewModel.projectSidebar.items.isEmpty)
        #expect(viewModel.workbench.openDocuments.isEmpty)
        #expect(viewModel.workbench.activeDocument == nil)
    }

    @Test("text edits autosave atomically and external changes are not overwritten")
    @MainActor
    func textAutosaveAndConflictProtection() async throws {
        let projectURL = try makeRealWorkspaceProject(named: "TextAutosave")
        defer { removeRealWorkspaceDirectory(projectURL) }

        let sourceURL = projectURL.appendingPathComponent("Sources/main.swift")
        try "let value = 1\n".write(to: sourceURL, atomically: true, encoding: .utf8)
        let project = EditorProjectReference(name: "TextAutosave", path: projectURL.path)
        let viewModel = EditorViewModel(project: project, autosaveDelay: .milliseconds(10))
        let sourceItem = try #require(viewModel.projectSidebar.items.first { $0.relativePath == "Sources/main.swift" })
        viewModel.openProjectItem(sourceItem)
        let documentID = try #require(viewModel.workbench.activeDocument?.id)

        viewModel.workbench.updateTextDocument(id: documentID) { document in
            document.content = "let value = 2\n"
            document.isDirty = true
        }
        let didAutosaveText = await waitForRealWorkspaceCondition {
            (try? String(contentsOf: sourceURL, encoding: .utf8)) == "let value = 2\n"
                && viewModel.workbench.activeDocument?.isDirty == false
        }

        #expect(didAutosaveText)
        #expect(try String(contentsOf: sourceURL, encoding: .utf8) == "let value = 2\n")
        #expect(viewModel.workbench.activeDocument?.isDirty == false)

        try "let value = 3 // external\n".write(to: sourceURL, atomically: true, encoding: .utf8)
        viewModel.workbench.updateTextDocument(id: documentID) { document in
            document.content = "let value = 4 // local\n"
            document.isDirty = true
        }
        let didReportConflict = await waitForRealWorkspaceCondition {
            guard case let .text(document)? = viewModel.workbench.activeDocument else {
                return false
            }
            return document.statusMessage == "Save blocked: file changed on disk"
        }

        #expect(didReportConflict)
        #expect(try String(contentsOf: sourceURL, encoding: .utf8) == "let value = 3 // external\n")
        guard case let .text(conflictedDocument)? = viewModel.workbench.activeDocument else {
            Issue.record("Expected the conflicted text document")
            return
        }
        #expect(conflictedDocument.isDirty)
        #expect(conflictedDocument.statusMessage == "Save blocked: file changed on disk")
        #expect(conflictedDocument.errorMessage != nil)
    }

    @Test("scene hierarchy edits autosave valid YAML and invalid YAML is rejected")
    @MainActor
    func sceneAutosaveValidatesYAML() async throws {
        let projectURL = try makeRealWorkspaceProject(named: "SceneAutosave")
        defer { removeRealWorkspaceDirectory(projectURL) }

        let sceneDirectory = projectURL.appendingPathComponent("Assets/Scenes", isDirectory: true)
        try FileManager.default.createDirectory(at: sceneDirectory, withIntermediateDirectories: true)
        let sceneURL = sceneDirectory.appendingPathComponent("Main.ascn")
        let originalContent = SceneDocumentFormat.defaultSceneYAML(projectName: "SceneAutosave")
        try originalContent.write(to: sceneURL, atomically: true, encoding: .utf8)

        let project = EditorProjectReference(name: "SceneAutosave", path: projectURL.path)
        let viewModel = EditorViewModel(project: project, autosaveDelay: .milliseconds(10))
        let sceneItem = try #require(viewModel.projectSidebar.items.first { $0.relativePath == "Assets/Scenes/Main.ascn" })
        viewModel.openProjectItem(sceneItem)
        let documentID = try #require(viewModel.workbench.activeDocument?.id)

        viewModel.workbench.addEntity(to: documentID)
        let didAutosaveScene = await waitForRealWorkspaceCondition {
            guard
                let content = try? String(contentsOf: sceneURL, encoding: .utf8),
                let model = try? EditorSceneModel.decode(from: content)
            else {
                return false
            }
            return model.entities.count == 2 && viewModel.workbench.activeDocument?.isDirty == false
        }

        #expect(didAutosaveScene)
        let savedContent = try String(contentsOf: sceneURL, encoding: .utf8)
        #expect(try EditorSceneModel.decode(from: savedContent).entities.count == 2)
        #expect(viewModel.workbench.activeDocument?.isDirty == false)

        guard case let .scene(savedDocument)? = viewModel.workbench.activeDocument else {
            Issue.record("Expected a scene document")
            return
        }
        let firstLine = try #require(viewModel.workbench.sceneLines(for: savedDocument).first)
        viewModel.workbench.updateSceneLine(documentID: documentID, lineIndex: 0, value: "[")
        let didRejectInvalidScene = await waitForRealWorkspaceCondition {
            guard case let .scene(document)? = viewModel.workbench.activeDocument else {
                return false
            }
            return document.statusMessage == "Save blocked" && document.errorMessage != nil
        }

        #expect(didRejectInvalidScene)
        #expect(try String(contentsOf: sceneURL, encoding: .utf8) == savedContent)
        guard case let .scene(invalidDocument)? = viewModel.workbench.activeDocument else {
            Issue.record("Expected an invalid scene document")
            return
        }
        #expect(invalidDocument.isDirty)
        #expect(invalidDocument.statusMessage == "Save blocked")
        #expect(invalidDocument.errorMessage != nil)

        viewModel.workbench.updateSceneLine(documentID: documentID, lineIndex: 0, value: firstLine)
        let didRecoverSceneAutosave = await waitForRealWorkspaceCondition {
            guard
                let content = try? String(contentsOf: sceneURL, encoding: .utf8),
                let model = try? EditorSceneModel.decode(from: content)
            else {
                return false
            }
            return model.entities.count == 2 && viewModel.workbench.activeDocument?.isDirty == false
        }
        #expect(didRecoverSceneAutosave)
        #expect(viewModel.workbench.activeDocument?.isDirty == false)
        #expect(try EditorSceneModel.decode(from: String(contentsOf: sceneURL, encoding: .utf8)).entities.count == 2)
    }

    @Test("configured resource roots expose real asset metadata and references")
    @MainActor
    func configuredResourceRootAssets() throws {
        let projectURL = try makeRealWorkspaceProject(named: "ResourceRoots")
        defer { removeRealWorkspaceDirectory(projectURL) }

        var metadata = try ProjectSystem.loadProject(at: projectURL)
        metadata.paths.resourceRoots = ["GameData"]
        try ProjectSystem.saveProject(metadata, at: projectURL)
        let resourceDirectory = projectURL.appendingPathComponent("GameData/Textures", isDirectory: true)
        try FileManager.default.createDirectory(at: resourceDirectory, withIntermediateDirectories: true)
        let assetData = Data([0x89, 0x50, 0x4E, 0x47, 0x01, 0x02])
        let assetURL = resourceDirectory.appendingPathComponent("player.png")
        try assetData.write(to: assetURL, options: [.atomic])

        let project = EditorProjectReference(name: "ResourceRoots", path: projectURL.path)
        let viewModel = EditorViewModel(project: project)
        let assetItem = try #require(viewModel.projectSidebar.items.first { $0.relativePath == "GameData/Textures/player.png" })
        #expect(assetItem.kind == .image)
        viewModel.openProjectItem(assetItem)

        guard case let .asset(document) = viewModel.workbench.activeDocument else {
            Issue.record("Expected an asset document")
            return
        }
        #expect(document.absolutePath.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path } == assetURL.resolvingSymlinksInPath().path)
        #expect(document.assetReference == "@res://Textures/player.png")
        #expect(document.byteCount == Int64(assetData.count))
        #expect(document.modifiedAt != nil)
    }

    @Test("replace scene document schedules autosave for production viewport edits")
    @MainActor
    func replaceSceneDocumentSchedulesAutosave() async throws {
        let projectURL = try makeRealWorkspaceProject(named: "ReplaceSceneAutosave")
        defer { removeRealWorkspaceDirectory(projectURL) }

        let sceneDirectory = projectURL.appendingPathComponent("Assets/Scenes", isDirectory: true)
        try FileManager.default.createDirectory(at: sceneDirectory, withIntermediateDirectories: true)
        let sceneURL = sceneDirectory.appendingPathComponent("Main.ascn")
        try SceneDocumentFormat.defaultSceneYAML(projectName: "ReplaceSceneAutosave")
            .write(
                to: sceneURL,
                atomically: true,
                encoding: .utf8
            )

        let project = EditorProjectReference(name: "ReplaceSceneAutosave", path: projectURL.path)
        let viewModel = EditorViewModel(project: project, autosaveDelay: .milliseconds(10))
        let sceneItem = try #require(viewModel.projectSidebar.items.first { $0.relativePath == "Assets/Scenes/Main.ascn" })
        viewModel.openProjectItem(sceneItem)
        guard case var .scene(updatedDocument)? = viewModel.workbench.activeDocument else {
            Issue.record("Expected a scene document")
            return
        }
        var model = try #require(updatedDocument.sceneModel)
        _ = model.addEntity(name: "Viewport Entity")
        updatedDocument.sceneModel = model
        updatedDocument.content = try model.encodedYAML()
        updatedDocument.isDirty = true

        viewModel.workbench.replaceSceneDocument(updatedDocument)
        let didAutosaveReplacement = await waitForRealWorkspaceCondition {
            guard
                let content = try? String(contentsOf: sceneURL, encoding: .utf8),
                let model = try? EditorSceneModel.decode(from: content)
            else {
                return false
            }
            return model.entities.contains { $0.name == "Viewport Entity" }
                && viewModel.workbench.activeDocument?.isDirty == false
                && viewModel.outputLines.contains { $0.text.contains("Autosaved Assets/Scenes/Main.ascn") }
        }

        #expect(didAutosaveReplacement)
        let savedModel = try EditorSceneModel.decode(from: String(contentsOf: sceneURL, encoding: .utf8))
        #expect(savedModel.entities.contains { $0.name == "Viewport Entity" })
        #expect(viewModel.workbench.activeDocument?.isDirty == false)
        #expect(viewModel.outputLines.contains { $0.text.contains("Autosaved Assets/Scenes/Main.ascn") })
    }

    @Test("symbolic-link text and scene documents are read-only and preserve link identity")
    @MainActor
    func symbolicLinkDocumentsCannotReplaceLinks() throws {
        let projectURL = try makeRealWorkspaceProject(named: "SymlinkSafety")
        defer { removeRealWorkspaceDirectory(projectURL) }
        let targetDirectory = try makeRealWorkspaceDirectory(named: "SymlinkTargets")
        defer { removeRealWorkspaceDirectory(targetDirectory) }

        let textTargetURL = targetDirectory.appendingPathComponent("Target.swift")
        let textTargetContent = "let target = true\n"
        try textTargetContent.write(to: textTargetURL, atomically: true, encoding: .utf8)
        let textLinkURL = projectURL.appendingPathComponent("Sources/Linked.swift")
        try FileManager.default.createSymbolicLink(at: textLinkURL, withDestinationURL: textTargetURL)

        let sceneTargetURL = targetDirectory.appendingPathComponent("Target.ascn")
        let sceneTargetContent = SceneDocumentFormat.defaultSceneYAML(projectName: "SymlinkTarget")
        try sceneTargetContent.write(to: sceneTargetURL, atomically: true, encoding: .utf8)
        let sceneDirectory = projectURL.appendingPathComponent("Assets/Scenes", isDirectory: true)
        try FileManager.default.createDirectory(at: sceneDirectory, withIntermediateDirectories: true)
        let sceneLinkURL = sceneDirectory.appendingPathComponent("Linked.ascn")
        try FileManager.default.createSymbolicLink(at: sceneLinkURL, withDestinationURL: sceneTargetURL)

        let project = EditorProjectReference(name: "SymlinkSafety", path: projectURL.path)
        let viewModel = EditorViewModel(project: project, autosaveDelay: .seconds(5))
        let textItem = try #require(viewModel.projectSidebar.items.first { $0.relativePath == "Sources/Linked.swift" })
        #expect(textItem.isSymbolicLink)
        viewModel.openProjectItem(textItem)
        let textDocumentID = try #require(viewModel.workbench.activeDocument?.id)
        guard case let .text(linkedTextDocument)? = viewModel.workbench.activeDocument else {
            Issue.record("Expected a linked text document")
            return
        }
        #expect(linkedTextDocument.isReadOnly)
        #expect(linkedTextDocument.statusMessage == "Read-only: symbolic link")
        viewModel.workbench.updateTextDocument(id: textDocumentID) { document in
            document.content = "let overwritten = true\n"
            document.isDirty = true
        }
        viewModel.workbench.closeDocument(id: textDocumentID)

        #expect(viewModel.workbench.openDocuments.contains { $0.id == textDocumentID })
        #expect(try textLinkURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true)
        #expect(try String(contentsOf: textTargetURL, encoding: .utf8) == textTargetContent)

        let sceneItem = try #require(viewModel.projectSidebar.items.first { $0.relativePath == "Assets/Scenes/Linked.ascn" })
        #expect(sceneItem.isSymbolicLink)
        viewModel.openProjectItem(sceneItem)
        let sceneDocumentID = try #require(viewModel.workbench.activeDocument?.id)
        guard
            let sceneIndex = viewModel.workbench.openDocuments.firstIndex(where: { $0.id == sceneDocumentID }),
            case var .scene(linkedSceneDocument) = viewModel.workbench.openDocuments[sceneIndex]
        else {
            Issue.record("Expected a linked scene document")
            return
        }
        #expect(linkedSceneDocument.isReadOnly)
        #expect(linkedSceneDocument.statusMessage == "Read-only: symbolic link")
        linkedSceneDocument.content = linkedSceneDocument.content.replacingOccurrences(of: "SymlinkTarget", with: "Overwritten")
        linkedSceneDocument.isDirty = true
        viewModel.workbench.openDocuments[sceneIndex] = .scene(linkedSceneDocument)
        viewModel.workbench.closeDocument(id: sceneDocumentID)

        #expect(viewModel.workbench.openDocuments.contains { $0.id == sceneDocumentID })
        #expect(try sceneLinkURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true)
        #expect(try String(contentsOf: sceneTargetURL, encoding: .utf8) == sceneTargetContent)
    }

    @Test("real projects start without sample output")
    @MainActor
    func realProjectOutputIsEmpty() throws {
        let projectURL = try makeRealWorkspaceProject(named: "EmptyOutput")
        defer { removeRealWorkspaceDirectory(projectURL) }

        let project = EditorProjectReference(name: "EmptyOutput", path: projectURL.path)
        let viewModel = EditorViewModel(project: project)

        #expect(viewModel.outputLines.isEmpty)
        #expect(EditorViewModel().outputLines.map(\.text) == AdaEngineStyleContent.logLines)
    }

    @Test("closing aborts when a dirty document cannot be saved")
    @MainActor
    func closeKeepsConflictedAndInvalidDocumentsOpen() throws {
        let projectURL = try makeRealWorkspaceProject(named: "BlockedClose")
        defer { removeRealWorkspaceDirectory(projectURL) }

        let sourceURL = projectURL.appendingPathComponent("Sources/main.swift")
        try "let value = 1\n".write(to: sourceURL, atomically: true, encoding: .utf8)
        let sceneDirectory = projectURL.appendingPathComponent("Assets/Scenes", isDirectory: true)
        try FileManager.default.createDirectory(at: sceneDirectory, withIntermediateDirectories: true)
        let sceneURL = sceneDirectory.appendingPathComponent("Main.ascn")
        try SceneDocumentFormat.defaultSceneYAML(projectName: "BlockedClose")
            .write(
                to: sceneURL,
                atomically: true,
                encoding: .utf8
            )

        let project = EditorProjectReference(name: "BlockedClose", path: projectURL.path)
        let viewModel = EditorViewModel(project: project, autosaveDelay: .seconds(5))
        let sourceItem = try #require(viewModel.projectSidebar.items.first { $0.relativePath == "Sources/main.swift" })
        viewModel.openProjectItem(sourceItem)
        let sourceDocumentID = try #require(viewModel.workbench.activeDocument?.id)
        try "let value = 2 // external\n".write(to: sourceURL, atomically: true, encoding: .utf8)
        viewModel.workbench.updateTextDocument(id: sourceDocumentID) { document in
            document.content = "let value = 3 // local\n"
            document.isDirty = true
        }

        viewModel.workbench.closeDocument(id: sourceDocumentID)

        #expect(viewModel.workbench.openDocuments.contains { $0.id == sourceDocumentID })
        guard case let .text(conflictedDocument)? = viewModel.workbench.openDocuments.first(where: { $0.id == sourceDocumentID }) else {
            Issue.record("Expected the conflicted document to stay open")
            return
        }
        #expect(conflictedDocument.isDirty)
        #expect(conflictedDocument.statusMessage == "Save blocked: file changed on disk")
        #expect(try String(contentsOf: sourceURL, encoding: .utf8) == "let value = 2 // external\n")

        let sceneItem = try #require(viewModel.projectSidebar.items.first { $0.relativePath == "Assets/Scenes/Main.ascn" })
        viewModel.openProjectItem(sceneItem)
        let sceneDocumentID = try #require(viewModel.workbench.activeDocument?.id)
        viewModel.workbench.updateSceneLine(documentID: sceneDocumentID, lineIndex: 0, value: "[")

        viewModel.workbench.closeDocument(id: sceneDocumentID)

        #expect(viewModel.workbench.openDocuments.contains { $0.id == sceneDocumentID })
        guard case let .scene(invalidDocument)? = viewModel.workbench.openDocuments.first(where: { $0.id == sceneDocumentID }) else {
            Issue.record("Expected the invalid scene to stay open")
            return
        }
        #expect(invalidDocument.isDirty)
        #expect(invalidDocument.statusMessage == "Save blocked")
        #expect(try String(contentsOf: sceneURL, encoding: .utf8).contains("format: ada.scene"))
    }

    @Test("unreadable text files are read-only and never overwritten")
    @MainActor
    func unreadableTextFileCannotBeOverwritten() throws {
        let projectURL = try makeRealWorkspaceProject(named: "UnreadableText")
        defer { removeRealWorkspaceDirectory(projectURL) }

        let sourceURL = projectURL.appendingPathComponent("Sources/Binary.swift")
        let originalBytes = Data([0xFF, 0xFE, 0x00, 0x80, 0x41])
        try originalBytes.write(to: sourceURL, options: [.atomic])
        let project = EditorProjectReference(name: "UnreadableText", path: projectURL.path)
        let viewModel = EditorViewModel(project: project, autosaveDelay: .seconds(5))
        let sourceItem = try #require(viewModel.projectSidebar.items.first { $0.relativePath == "Sources/Binary.swift" })
        viewModel.openProjectItem(sourceItem)
        let documentID = try #require(viewModel.workbench.activeDocument?.id)

        guard case let .text(unreadableDocument)? = viewModel.workbench.activeDocument else {
            Issue.record("Expected an unreadable text document")
            return
        }
        #expect(unreadableDocument.isReadOnly)
        #expect(unreadableDocument.lastSavedContent == nil)
        #expect(unreadableDocument.errorMessage != nil)
        #expect(unreadableDocument.statusMessage == "Read-only: unable to read as UTF-8")

        let binding = viewModel.workbench.textDocumentBinding(documentID: documentID)
        binding.wrappedValue = "let replacement = true\n"
        #expect(binding.wrappedValue.isEmpty)
        #expect(viewModel.workbench.activeDocument?.isDirty == false)

        viewModel.workbench.updateTextDocument(id: documentID) { document in
            document.content = "forced edit"
            document.isDirty = true
        }
        viewModel.workbench.closeDocument(id: documentID)

        #expect(viewModel.workbench.openDocuments.contains { $0.id == documentID })
        #expect(try Data(contentsOf: sourceURL) == originalBytes)
        guard case let .text(blockedDocument)? = viewModel.workbench.activeDocument else {
            Issue.record("Expected the read-only document to remain active")
            return
        }
        #expect(blockedDocument.isDirty)
        #expect(blockedDocument.statusMessage == "Save blocked: file is read-only")
    }
}

private func makeRealWorkspaceProject(named name: String) throws -> URL {
    let projectURL = try makeRealWorkspaceDirectory(named: name)
    try "// swift-tools-version: 6.2\n"
        .write(
            to: projectURL.appendingPathComponent("Package.swift"),
            atomically: true,
            encoding: .utf8
        )
    try FileManager.default.createDirectory(
        at: projectURL.appendingPathComponent("Sources", isDirectory: true),
        withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
        at: projectURL.appendingPathComponent("Assets", isDirectory: true),
        withIntermediateDirectories: true
    )
    _ = try ProjectSystem.createDefaultProject(at: projectURL)
    return projectURL
}

private func makeRealWorkspaceDirectory(named name: String) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("AdaEditor-\(name)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func removeRealWorkspaceDirectory(_ url: URL) {
    try? FileManager.default.removeItem(at: url)
}

@MainActor
private func waitForRealWorkspaceCondition(
    timeout: Duration = .seconds(3),
    pollInterval: Duration = .milliseconds(20),
    _ condition: () -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)

    while clock.now < deadline {
        if condition() {
            return true
        }

        do {
            try await Task.sleep(for: pollInterval)
        } catch {
            return condition()
        }
    }

    return condition()
}
