@_spi(Internal) import AdaApp
@_spi(AdaEngine) import AdaEngine
@_spi(Internal) import AdaUI
import Foundation
import Testing

@testable import AdaEditor

@MainActor
@Suite("Project tree expansion", .serialized)
struct EditorProjectTreeStateTests {
    @Test("Source subfolders remain unique descendants of the configured source target")
    func sourceHierarchy() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let model = fixture.model()
        model.expandAll()
        let rows = model.visibleItems
        #expect(Set(rows.map(\.id)).count == rows.count)
        #expect(rows.first { $0.relativePath == "Sources" }?.level == 0)
        #expect(rows.first { $0.relativePath == "Sources/Base" }?.level == 1)
        #expect(rows.first { $0.relativePath == "Sources/Base/Nested" }?.level == 2)
        #expect(rows.first { $0.relativePath == "Sources/Base/Nested/Commands.ada" }?.level == 3)
        #expect(model.revealFile(relativePath: "README.md"))
        #expect(model.displayMode == .files)
    }

    @Test("Disclosure retains outgoing rows and reverses smoothly from the current height")
    func presentationReversal() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let model = fixture.model()
        let closed = model.visibleItems
        let presentation = EditorProjectTreePresentation(items: closed)
        let order = model.items.map(\.id)
        let start = Date(timeIntervalSinceReferenceDate: 0)
        model.expandAll()
        let opened = model.visibleItems
        presentation.update(to: opened, order: order, at: start)
        let halfway = presentation.rows(at: start.addingTimeInterval(0.09))
        let child = try #require(halfway.first { $0.item.relativePath == "Sources/Base" })
        #expect(child.fraction > 0 && child.fraction < 1)
        presentation.update(to: closed, order: order, at: start.addingTimeInterval(0.09))
        #expect(presentation.rows(at: start.addingTimeInterval(0.09)).first { $0.id == child.id }?.fraction == child.fraction)
        let closing = try #require(presentation.rows(at: start.addingTimeInterval(0.135)).first { $0.id == child.id })
        #expect(closing.fraction > 0 && closing.fraction < child.fraction)
        presentation.finishIfNeeded(at: start.addingTimeInterval(0.30))
        #expect(!presentation.isAnimating)
        #expect(presentation.rows(at: start.addingTimeInterval(1)).map(\.id) == closed.map(\.id))
    }

    @Test("Mounted folders animate height and retain visible indentation")
    func disclosureMotionAndIndentation() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        prepareTreeRenderer()
        let model = fixture.model()
        let container = makeContainer(model: model)
        await settle(container)
        let root = UINodeSelector.accessibilityIdentifier("AdaEditor.ProjectTree.Tree")
        let child = UINodeSelector.accessibilityIdentifier("AdaEditor.ProjectTree.Row.Sources/Base")
        _ = try container.uiTapNode(matching: root)
        await settle(container)
        try await Task.sleep(for: .milliseconds(65))
        await settle(container)
        let expanding = try container.uiNode(matching: child).absoluteFrame.height
        #expect(expanding > 0 && expanding < 28)
        try await Task.sleep(for: .milliseconds(170))
        await settle(container)
        #expect(try container.uiNode(matching: child).absoluteFrame.height == 28)
        let parentArrow = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.ProjectTree.Disclosure.Sources"))
        let childArrow = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.ProjectTree.Disclosure.Sources/Base"))
        #expect(childArrow.absoluteFrame.minX - parentArrow.absoluteFrame.minX >= 15)
        _ = try container.uiTapNode(matching: root)
        await settle(container)
        try await Task.sleep(for: .milliseconds(65))
        await settle(container)
        let collapsing = try container.uiNode(matching: child).absoluteFrame.height
        #expect(collapsing > 0 && collapsing < 28)
        try await Task.sleep(for: .milliseconds(170))
        await settle(container)
        #expect(container.uiFindNodes(matching: child).isEmpty)
    }

    @Test("Crosshair reveals the active tab, opens its ancestors and scrolls to an offscreen file")
    func crosshairRevealsActiveTab() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        for index in 0..<160 {
            try Data().write(to: fixture.root.appendingPathComponent("Sources/Pad\(String(format: "%03d", index)).ada"))
        }
        try Data().write(to: fixture.root.appendingPathComponent("Sources/ZLast.ada"))
        prepareTreeRenderer()
        let editor = EditorViewModel(project: fixture.project)
        let target = try #require(editor.projectSidebar.items.first { $0.relativePath == "Sources/ZLast.ada" })
        editor.openProjectItem(target)
        let activeTab = editor.workbench.activeDocumentID
        let container = makeContainer(model: editor.projectSidebar, onReveal: { editor.revealActiveDocumentInProjectTree() })
        await settle(container)
        _ = try container.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.ProjectTree.RevealActiveFile"))
        await settle(container)
        try await Task.sleep(for: .milliseconds(240))
        await settle(container)
        #expect(editor.projectSidebar.selectedItem?.id == target.id)
        #expect(editor.workbench.activeDocumentID == activeTab)
        let node = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.ProjectTree.ZLast.ada"))
        let viewport = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.ProjectTree.ScrollView"))
        #expect(node.absoluteFrame.minY >= viewport.absoluteFrame.minY)
        #expect(node.absoluteFrame.maxY <= viewport.absoluteFrame.maxY)
    }

    @Test("A tall navigator keeps file selection responsive through retained row content")
    func tallNavigatorSelection() async throws {
        prepareTreeRenderer()
        let items = (0..<80).map { index in
            EditorProjectSidebarViewModel.Item(
                id: "File\(index).ada", disclosure: "", icon: "", title: "File\(index).ada",
                relativePath: "File\(index).ada", level: 0, isActive: false, isFolder: false, kind: .text(.ada)
            )
        }
        let model = EditorProjectSidebarViewModel(items: items, displayMode: .files)
        let container = makeContainer(model: model, onOpenItem: { model.select($0) })
        container.frame.size.height = 1280
        container.bounds.size = container.frame.size
        await settle(container)
        var longest = Duration.zero
        for index in [2, 7, 11, 2] {
            let frame = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.ProjectTree.\(items[index].title)")).absoluteFrame
            let started = ContinuousClock.now
            for phase in [MouseEvent.Phase.began, .ended] {
                container.onMouseEvent(MouseEvent(window: .empty, button: .left,
                    mousePosition: Point(frame.midX, frame.midY), phase: phase, modifierKeys: [], time: 0))
            }
            await settle(container)
            longest = max(longest, started.duration(to: .now))
            #expect(model.selectedItem?.id == items[index].id)
            #expect(try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.ProjectTree.\(items[index].title)")).isInteractable)
        }
        #expect(longest < .seconds(1))
        print("Tall navigator selection and layout: maximum \(longest)")
    }

    private func prepareTreeRenderer() {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            RenderWorldPlugin().setup(in: AppWorlds(main: World(name: "ProjectTreeMotion")))
        }
    }

    private func makeContainer(
        model: EditorProjectSidebarViewModel, onReveal: @escaping () -> Void = {},
        onOpenItem: ((EditorProjectSidebarViewModel.Item) -> Void)? = nil
    ) -> UIContainerView<some View> {
        let container = UIContainerView(rootView: EditorProjectSidebar(
            viewModel: model, projectRootItem: nil, onOpenItem: onOpenItem ?? { model.toggleFolder($0) },
            onOpenRawItem: { _ in }, onNewFile: { _ in }, onImportAssets: {}, onDropFiles: { _ in true },
            onRevealItem: { _ in }, onOpenInDefaultApplication: { _ in }, onOpenInTerminal: { _ in },
            onFindInFolder: { _ in }, onFindInProjectRoot: {}, onCopyPath: { _, _ in }, onDeleteItem: { _ in },
            onRevealActiveFile: onReveal, isRevealActiveFileEnabled: true
        ).theme(.adaEditor))
        container.frame = Rect(x: 0, y: 0, width: 340, height: 480)
        container.bounds.size = container.frame.size
        container.layoutIfNeeded()
        return container
    }
    @Test("A real project starts with closed folders in both display modes")
    func startsCollapsed() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let editor = EditorViewModel(project: fixture.project)
        #expect(editor.projectSidebar.visibleItems.map(\.relativePath) == ["Assets", "Sources"])
        editor.projectSidebar.selectDisplayMode(.files)
        #expect(editor.projectSidebar.visibleItems.map(\.relativePath) == ["Assets", "Sources", "README.md"])
        #expect(!editor.projectSidebar.hasExpandedFolders)
    }

    @Test("Reopening restores exactly the expanded paths, including children of a closed parent")
    func restoresExpandedPaths() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let model = fixture.model()
        for path in ["Assets", "Assets/Audio", "Assets/Audio/Weather"] {
            model.toggleFolder(try fixture.folder(path))
        }
        model.toggleFolder(try fixture.folder("Assets/Audio"))
        let restored = fixture.model()
        #expect(restored.collapsedFolderIDs == model.collapsedFolderIDs)
        #expect(restored.visibleItems.map(\.relativePath) == ["Assets", "Assets/Audio", "Sources"])
        restored.toggleFolder(try fixture.folder("Assets/Audio"))
        #expect(restored.visibleItems.contains { $0.relativePath == "Assets/Audio/Weather/rain.wav" })
        #expect(restored.isCollapsed(try fixture.folder("Sources")))
        restored.selectDisplayMode(.files)
        #expect(restored.visibleItems.contains { $0.relativePath == "Assets/Audio/Weather/rain.wav" })

        let otherPath = fixture.root.appendingPathComponent("OtherProject").path
        let other = fixture.model(projectPath: otherPath)
        #expect(!other.hasExpandedFolders)
    }

    @Test("Refreshing keeps open folders and leaves newly discovered folders closed")
    func refreshPreservesExpansion() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let editor = EditorViewModel(project: fixture.project)
        editor.projectSidebar.toggleFolder(try fixture.folder("Assets"))
        editor.projectSidebar.toggleFolder(try fixture.folder("Assets/Audio"))
        let nested = fixture.root.appendingPathComponent("Assets/Audio/New/Nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data().write(to: nested.appendingPathComponent("new.wav"))
        editor.refreshProjectFiles(logsRefresh: false)
        #expect(!editor.projectSidebar.isCollapsed(try fixture.folder("Assets/Audio")))
        let newFolder = try #require(editor.projectSidebar.items.first { $0.relativePath == "Assets/Audio/New" })
        #expect(editor.projectSidebar.isCollapsed(newFolder))
        #expect(!editor.projectSidebar.visibleItems.contains { $0.relativePath == "Assets/Audio/New/Nested" })
        let reopened = EditorViewModel(project: fixture.project)
        #expect(reopened.projectSidebar.collapsedFolderIDs == editor.projectSidebar.collapsedFolderIDs)
    }

    @Test("The toolbar toggles every nested folder and retains New File behavior")
    func toolbarInteraction() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let previousLanguage = EditorLocalization.shared.preference
        defer { EditorLocalization.shared.preference = previousLanguage }
        EditorLocalization.shared.preference = .english
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            RenderWorldPlugin().setup(in: AppWorlds(main: World(name: "ProjectTreeExpansion")))
        }
        let model = fixture.model()
        var newFileCount = 0
        let container = UIContainerView(rootView: EditorProjectSidebar(
            viewModel: model, projectRootItem: nil, onOpenItem: { model.toggleFolder($0) },
            onOpenRawItem: { _ in }, onNewFile: { _ in newFileCount += 1 }, onImportAssets: {},
            onDropFiles: { _ in true }, onRevealItem: { _ in }, onOpenInDefaultApplication: { _ in },
            onOpenInTerminal: { _ in }, onFindInFolder: { _ in }, onFindInProjectRoot: {},
            onCopyPath: { _, _ in }, onDeleteItem: { _ in }
        ).theme(.adaEditor))
        container.frame = Rect(x: 0, y: 0, width: 300, height: 500)
        container.bounds.size = container.frame.size
        container.layoutIfNeeded()
        let toggle = UINodeSelector.accessibilityIdentifier("AdaEditor.ProjectTree.ToggleAllFolders")
        let newFile = UINodeSelector.accessibilityIdentifier("AdaEditor.ProjectTree.NewFile")
        #expect(try container.uiNode(matching: newFile).absoluteFrame.width == 26)
        #expect(try container.uiNode(matching: toggle).absoluteFrame.width == 26)
        _ = try container.uiTapNode(matching: toggle)
        await settle(container)
        try await Task.sleep(for: .milliseconds(220))
        await settle(container)
        #expect(model.collapsedFolderIDs.isEmpty)
        #expect(!container.uiFindNodes(matching: .accessibilityIdentifier("AdaEditor.ProjectTree.rain.wav")).isEmpty)
        _ = try container.uiTapNode(matching: toggle)
        await settle(container)
        try await Task.sleep(for: .milliseconds(220))
        await settle(container)
        #expect(!model.hasExpandedFolders)
        #expect(container.uiFindNodes(matching: .accessibilityIdentifier("AdaEditor.ProjectTree.rain.wav")).isEmpty)
        #expect(fixture.model().collapsedFolderIDs == model.collapsedFolderIDs)
        EditorLocalization.shared.preference = .russian
        await settle(container)
        #expect(try container.uiNode(matching: newFile).absoluteFrame.maxX <= 300)
        _ = try container.uiTapNode(matching: newFile)
        #expect(newFileCount == 1)
    }

    private func settle<Content: View>(_ container: UIContainerView<Content>) async {
        for _ in 0..<5 {
            await Task.yield()
            container.update(1.0 / 60)
            container.layoutIfNeeded()
        }
    }

    @MainActor
    private struct Fixture {
        let root: URL
        let suite: String
        let defaults: UserDefaults
        var project: EditorProjectReference { .init(name: "Tree", path: root.path) }
        var items: [EditorProjectSidebarViewModel.Item] {
            EditorViewModel.projectTreeItems(for: project, fileManager: .default)
        }

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("ProjectTree-\(UUID().uuidString)")
            suite = "AdaEditor.ProjectTree.Tests.\(UUID().uuidString)"
            defaults = try #require(UserDefaults(suiteName: suite))
            for path in ["Assets/Audio/Weather", "Sources/Base/Nested"] {
                try FileManager.default.createDirectory(at: root.appendingPathComponent(path), withIntermediateDirectories: true)
            }
            for path in ["Assets/Audio/Weather/rain.wav", "Sources/Player.ada", "Sources/Base/Nested/Commands.ada", "README.md"] {
                try Data().write(to: root.appendingPathComponent(path))
            }
            try ProjectSystem.saveProject(ProjectSystem.defaultProject(projectName: "Tree", buildSystem: .adaScript), at: root)
        }

        func model(projectPath: String? = nil) -> EditorProjectSidebarViewModel {
            EditorProjectSidebarViewModel(
                items: items, sourceRootTarget: .init(relativePath: "Sources", title: "Tree"),
                projectPath: projectPath ?? root.path, defaults: defaults
            )
        }

        func folder(_ path: String) throws -> EditorProjectSidebarViewModel.Item {
            try #require(items.first { $0.isFolder && $0.relativePath == path })
        }

        func cleanUp() {
            defaults.removePersistentDomain(forName: suite)
            UserDefaults.standard.removeObject(forKey: "AdaEditor.ProjectTree.ExpandedFolders." + root.standardizedFileURL.path)
            try? FileManager.default.removeItem(at: root)
        }
    }
}
