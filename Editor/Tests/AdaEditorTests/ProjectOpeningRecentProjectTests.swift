@_spi(AdaEngine) import AdaEngine
import AdaInput
@_spi(Internal) import AdaUI
import Foundation
import Math
import Testing

@testable import AdaEditor

@Suite("Recent project management", .serialized)
@MainActor
struct ProjectOpeningRecentProjectTests {
    @Test("Rename persists through reopening and preserves project identity and sources", arguments: EditorProjectTemplate.allCases)
    func renamePersists(template: EditorProjectTemplate) throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = EditorProjectStore(storageURL: root.appendingPathComponent("projects.json"))
        let reference = try store.createProject(named: "Original", at: root, template: template)
        let url = URL(fileURLWithPath: reference.path)
        let source = url.appendingPathComponent(template == .adaScript ? "Sources/Main.ada" : "Sources/Original/Main.ada")
        let originalSource = try Data(contentsOf: source)
        let manifest = url.appendingPathComponent("Package.swift")
        let originalManifest = try? Data(contentsOf: manifest)
        let originalProject = try ProjectSystem.loadProject(at: url)
        let model = ProjectOpeningViewModel(store: store)
        let lastOpenedAt = model.recentProjects.first?.lastOpenedAt
        model.beginRenamingProject(reference)
        model.renamedProjectName = "  Новое имя  "
        model.renameRecentProject()
        #expect(model.projectBeingRenamed == nil)
        #expect(model.selectedProject?.name == "Новое имя")
        #expect(model.selectedProject?.id == reference.id)
        #expect(model.selectedProject?.lastOpenedAt == lastOpenedAt)
        let reopened = try store.openProject(at: url)
        #expect(reopened.name == "Новое имя")
        #expect(reopened.id == reference.id)
        #expect(reopened.path == reference.path)
        #expect(ProjectOpeningViewModel(store: store).recentProjects.first?.name == "Новое имя")
        var expected = originalProject
        expected.project.displayName = "Новое имя"
        #expect(try ProjectSystem.loadProject(at: url) == expected)
        #expect(try Data(contentsOf: source) == originalSource)
        #expect((try? Data(contentsOf: manifest)) == originalManifest)
    }

    @Test("Remove persists, clears selection, and keeps the project on disk")
    func removePersists() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = EditorProjectStore(storageURL: root.appendingPathComponent("projects.json"))
        let reference = try store.createProject(named: "KeepFiles", at: root, template: .adaScript)
        let missing = EditorProjectReference(name: "Missing", path: root.appendingPathComponent("missing").path)
        try store.saveProjects([reference, missing])
        let model = ProjectOpeningViewModel(store: store)
        model.selectProject(reference)
        model.removeRecentProject(reference)
        #expect(model.selectedProject == nil)
        #expect(model.existingProjectPath.isEmpty)
        #expect(try ProjectSystem.loadProject(at: URL(fileURLWithPath: reference.path)).project.name == "KeepFiles")
        #expect(ProjectOpeningViewModel(store: store).recentProjects.map(\.id) == [missing.id])
        model.removeRecentProject(missing)
        #expect(try store.loadProjects().isEmpty)
    }

    @Test("Blank names and unavailable projects keep the rename dialog open with an error")
    func renameFailureAndCancel() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = EditorProjectStore(storageURL: root.appendingPathComponent("projects.json"))
        let reference = try store.createProject(named: "Original", at: root, template: .adaScript)
        let model = ProjectOpeningViewModel(store: store)
        model.beginRenamingProject(reference)
        model.renamedProjectName = " \n "
        model.renameRecentProject()
        #expect(model.recentProjectError != nil)
        #expect(model.projectBeingRenamed == reference)
        #expect(try store.loadProjects().first?.name == reference.name)
        model.cancelRenamingProject()
        #expect(model.projectBeingRenamed == nil)
        #expect(model.recentProjectError == nil)
        try FileManager.default.removeItem(atPath: reference.path)
        model.beginRenamingProject(reference)
        model.renamedProjectName = "New Name"
        model.renameRecentProject()
        #expect(model.recentProjectError != nil)
        #expect(try store.loadProjects().first?.name == reference.name)
    }

    @Test("A right click opens the real row menu, including for a missing project")
    func rowMenuAndRenameDialog() async throws {
        prepareRenderer()
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = EditorProjectStore(storageURL: root.appendingPathComponent("projects.json"))
        let reference = try store.createProject(named: "MenuProject", at: root, template: .adaScript)
        let model = ProjectOpeningViewModel(store: store)
        await model.refreshProjectAvailability()
        var menu: ContextMenuPresentation?
        let previous = ContextMenuPresentationCenter.present
        ContextMenuPresentationCenter.present = { menu = $0 }
        defer { ContextMenuPresentationCenter.present = previous }
        let container = UIContainerView(rootView: ProjectOpeningView(autoOpenLastProject: false, viewModel: model))
        container.frame = Rect(x: 0, y: 0, width: 1024, height: 700)
        container.bounds.size = container.frame.size
        container.layoutIfNeeded()
        let row = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.Launcher.Project.\(reference.id)"))
        container.onMouseEvent(
            MouseEvent(
                window: RID(),
                button: .right,
                mousePosition: Point(row.absoluteFrame.midX, row.absoluteFrame.midY),
                phase: .began,
                modifierKeys: [],
                time: 0
            )
        )
        let rename = try #require(menu?.items.first { $0.title == "Rename…" }?.action)
        #expect(model.projectToOpenInEditor == nil)
        rename()
        for _ in 0..<100 {
            await Task.yield()
            container.layoutIfNeeded()
            if !container.uiFindNodes(matching: .accessibilityIdentifier("AdaEditor.Launcher.Rename.Save")).isEmpty {
                break
            }
        }
        _ = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.Launcher.Rename.Name"))
        model.renamedProjectNameBinding.wrappedValue = "Renamed from Menu"
        _ = try container.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.Launcher.Rename.Save"))
        #expect(try store.loadProjects().first?.name == "Renamed from Menu")
        #expect(model.projectBeingRenamed == nil)

        try FileManager.default.removeItem(atPath: reference.path)
        await model.refreshProjectAvailability()
        let missingRow = UIContainerView(rootView: ProjectOpeningRecentProjectRow(project: reference, viewModel: model))
        missingRow.frame = Rect(x: 0, y: 0, width: 320, height: 58)
        missingRow.bounds.size = missingRow.frame.size
        missingRow.layoutIfNeeded()
        menu = nil
        missingRow.onMouseEvent(MouseEvent(window: RID(), button: .right, mousePosition: Point(100, 25), phase: .began, modifierKeys: [], time: 0))
        let remove = try #require(menu?.items.first { $0.title == "Remove from Recent Projects" })
        #expect(remove.role == .destructive)
        remove.action?()
        #expect(try store.loadProjects().isEmpty)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func prepareRenderer() {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            RenderWorldPlugin().setup(in: AppWorlds(main: World(name: "RecentProjectsUI")))
        }
    }
}
