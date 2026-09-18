@_spi(AdaEngine) import AdaEngine
@_spi(Internal) import AdaUI
import Testing

@testable import AdaEditor

@Suite("Settings tree", .serialized)
@MainActor
struct EditorSettingsTreeTests {
    @Test("Nested selection filters the settings page and sections can collapse")
    func selectsAndCollapses() async throws {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            RenderWorldPlugin().setup(in: AppWorlds(main: World(name: "SettingsTree")))
        }
        let model = EditorSettingsWindowViewModel(editorViewModel: EditorViewModel(project: nil), selectedSection: .general)
        let container = UIContainerView(rootView: EditorSettingsWindowView(viewModel: model).theme(.adaEditor))
        container.frame = Rect(x: 0, y: 0, width: 1000, height: 720)
        container.bounds.size = container.frame.size
        container.layoutIfNeeded()
        _ = try container.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.Settings.Page.EDITOR FONT"))
        for _ in 0..<10 {
            await Task.yield()
            container.update(1.0 / 60.0)
            container.layoutIfNeeded()
        }
        #expect(model.selectedPage == "EDITOR FONT")
        #expect(container.uiFindNodes(matching: .accessibilityIdentifier("AdaEditor.Settings.Group.APPEARANCE")).isEmpty)
        let group = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.Settings.Group.EDITOR FONT"))
        #expect(group.absoluteFrame.minX < 250)
        _ = try container.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.Settings.Section.General"))
        for _ in 0..<10 {
            await Task.yield()
            container.update(1.0 / 60.0)
            container.layoutIfNeeded()
        }
        #expect(model.collapsedSections.contains(.general))
        #expect(model.selectedPage == "EDITOR FONT")
        #expect(model.selectedSection == .general)
        #expect(container.uiFindNodes(matching: .accessibilityIdentifier("AdaEditor.Settings.Page.EDITOR FONT")).isEmpty)
        model.searchText = "syntax"
        #expect(model.filteredSections == [.general])
        #expect(model.visiblePages(in: .general) == ["SYNTAX APPEARANCE"])
    }

    @Test("Changing sections clears nested selection without resetting drafts")
    func preservesDrafts() {
        let model = EditorSettingsWindowViewModel(editorViewModel: EditorViewModel(project: nil), selectedSection: .general)
        model.codeFontSize = 19
        model.selectPage("EDITOR FONT", in: .general)
        model.selectPage("CONTEXT", in: .agent)
        #expect(model.selectedSection == .agent)
        #expect(model.showsPage("CONTEXT"))
        #expect(!model.showsPage("PERMISSIONS"))
        model.selectedSection = .general
        #expect(model.selectedPage == "CLOUD ACCOUNT")
        #expect(model.codeFontSize == 19)
    }
    @Test("Collapsible headers only change expansion, including during search")
    func headersDoNotNavigate() {
        let model = EditorSettingsWindowViewModel(editorViewModel: nil, selectedSection: .general)
        #expect(model.selectedPage == "CLOUD ACCOUNT")
        model.activateSection(.agent)
        #expect(model.collapsedSections.contains(.agent))
        #expect(model.selectedSection == .general)
        #expect(model.selectedPage == "CLOUD ACCOUNT")
        model.activateSection(.agent)
        #expect(!model.collapsedSections.contains(.agent))
        #expect(model.selectedPage == "CLOUD ACCOUNT")
        model.searchText = "agent"
        model.activateSection(.agent)
        #expect(model.collapsedSections.contains(.agent))
        model.activateSection(.notifications)
        #expect(model.selectedSection == .notifications)
        #expect(model.selectedPage == nil)
    }

    @Test("No-project Cloud and Appearance occupy separate pages")
    func noProjectPagesDoNotOverlap() async throws {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            RenderWorldPlugin().setup(in: AppWorlds(main: World(name: "CloudSettingsLayout")))
        }
        let model = EditorSettingsWindowViewModel(editorViewModel: nil, selectedSection: .general)
        let container = UIContainerView(rootView: EditorSettingsWindowView(viewModel: model).theme(.adaEditor))
        container.frame = Rect(x: 0, y: 0, width: 1000, height: 720)
        container.bounds.size = container.frame.size
        container.layoutIfNeeded()
        let card = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.Cloud.AccountCard"))
        let signIn = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.Cloud.SignIn"))
        let title = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.Settings.Group.CLOUD ACCOUNT"))
        #expect(card.absoluteFrame.minY >= title.absoluteFrame.maxY)
        #expect(signIn.absoluteFrame.minY >= card.absoluteFrame.minY)
        #expect(signIn.absoluteFrame.maxY <= card.absoluteFrame.maxY)
        #expect(card.absoluteFrame.size.height > 90)
        #expect(container.uiFindNodes(matching: .accessibilityIdentifier("AdaEditor.Settings.Group.APPEARANCE")).isEmpty)
        model.selectPage("APPEARANCE", in: .general)
        for _ in 0..<10 {
            await Task.yield()
            container.update(1.0 / 60.0)
            container.layoutIfNeeded()
        }
        #expect(container.uiFindNodes(matching: .accessibilityIdentifier("AdaEditor.Cloud.SignIn")).isEmpty)
        _ = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.Settings.Group.APPEARANCE"))
    }

    @Test("Project context stays pinned to the bottom of the settings sidebar")
    func projectContextStaysAtSidebarBottom() throws {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            RenderWorldPlugin().setup(in: AppWorlds(main: World(name: "SettingsSidebarLayout")))
        }
        let model = EditorSettingsWindowViewModel(editorViewModel: EditorViewModel(project: nil), selectedSection: .general)
        let container = UIContainerView(rootView: EditorSettingsWindowView(viewModel: model).theme(.adaEditor))
        container.frame = Rect(x: 0, y: 0, width: 1000, height: 720)
        container.bounds.size = container.frame.size
        container.layoutIfNeeded()

        let context = try container.uiNode(
            matching: .accessibilityIdentifier(EditorSettingsWindowView.sidebarContextAccessibilityIdentifier)
        )
        #expect(abs(context.absoluteFrame.maxY - container.bounds.height) < 0.5)
    }
}
