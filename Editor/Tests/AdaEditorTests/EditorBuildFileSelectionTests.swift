@_spi(AdaEngine) import AdaEngine
@_spi(Internal) import AdaUI
import Foundation
import Math
import Testing

@testable import AdaEditor

@Suite("Editor build file selection", .serialized)
@MainActor
struct EditorBuildFileSelectionTests {
    @Test("file and folder selections preserve names and persist after reopening")
    func selectionPersists() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try ProjectSystem.saveProject(ProjectSystem.defaultProject(buildSystem: .adaScript), at: root)
        let sources = root.appendingPathComponent("Sources")
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        let file = sources.appendingPathComponent("Shared, Game.swift")
        try Data().write(to: file)
        let reference = EditorProjectReference(name: "Game", path: root.path)
        let model = EditorViewModel(project: reference)

        model.addBuildFiles([sources, file, file], to: .included)
        model.addBuildFiles([file], to: .excluded)
        #expect(model.projectIncludedFiles == ["Sources", "Sources/Shared, Game.swift"])
        model.removeBuildFile("Sources", from: .included)
        model.saveProjectSettings()

        let reopened = EditorViewModel(project: reference)
        #expect(reopened.projectIncludedFiles == ["Sources/Shared, Game.swift"])
        #expect(reopened.projectExcludedFiles == ["Sources/Shared, Game.swift"])
    }

    @Test("invalid selections leave the complete draft unchanged")
    func rejectsOutsideAndMissingFiles() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("Game")
        try ProjectSystem.saveProject(ProjectSystem.defaultProject(buildSystem: .adaScript), at: root)
        let inside = root.appendingPathComponent("Game.swift")
        let outside = base.appendingPathComponent("Outside.swift")
        try Data().write(to: inside)
        try Data().write(to: outside)
        let link = root.appendingPathComponent("Linked.swift")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let model = EditorViewModel(project: EditorProjectReference(name: "Game", path: root.path))
        for invalid in [outside, link, root.appendingPathComponent("Missing.swift")] {
            model.addBuildFiles([inside, invalid], to: .included)
            #expect(model.projectIncludedFiles.isEmpty)
            #expect(model.projectSettingsStatusMessage.contains("inside the project"))
        }
    }

    @Test("minus button removes only its row through the UI event path")
    func removeRowInteraction() throws {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            RenderWorldPlugin().setup(in: AppWorlds(main: World(name: "BuildFileListTests")))
        }
        let model = EditorViewModel()
        model.projectIncludedFiles = ["Sources/Game", "Sources/Shared.swift"]
        model.projectExcludedFiles = ["Sources/Drafts"]
        let container = UIContainerView(rootView: EditorBuildFileList(viewModel: model, selection: .included))
        container.frame = Rect(x: 0, y: 0, width: 600, height: 200)
        container.bounds.size = container.frame.size
        container.layoutIfNeeded()

        _ = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.Settings.IncludedFiles.Add"))
        _ = try container.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.Settings.IncludedFiles.Remove.Sources/Game"))

        #expect(model.projectIncludedFiles == ["Sources/Shared.swift"])
        #expect(model.projectExcludedFiles == ["Sources/Drafts"])
    }
}
