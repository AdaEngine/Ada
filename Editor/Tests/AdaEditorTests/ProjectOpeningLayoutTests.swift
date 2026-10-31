@_spi(AdaEngine) import AdaEngine
@_spi(Internal) @testable import AdaUI
import Foundation
import Math
import Testing

@testable import AdaEditor

@Suite("Project opening layout")
struct ProjectOpeningLayoutTests {
    @Test("creation fills the client area below the desktop menu", arguments: [
        Size(width: 1024, height: 700), Size(width: 1280, height: 720), Size(width: 1600, height: 1000)
    ])
    @MainActor
    func creationFillsDesktopWindow(_ size: Size) async throws {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            RenderWorldPlugin().setup(in: AppWorlds(main: World(name: "LauncherDesktopLayout")))
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = ProjectOpeningViewModel(store: EditorProjectStore(storageURL: root.appendingPathComponent("projects.json")))
        model.beginCreateNewProject()
        let container = UIContainerView(rootView: ProjectOpeningView(autoOpenLastProject: false, viewModel: model)
            .environment(\.windowCaption, WindowCaptionPresentation(isVisible: true)))
        container.frame = Rect(origin: .zero, size: size)
        container.bounds.size = size
        container.layoutIfNeeded()
        for identifier in [ProjectOpeningAccessibility.sidebar, ProjectOpeningAccessibility.explorer, ProjectOpeningAccessibility.detail] {
            let column = try container.uiNode(matching: .accessibilityIdentifier(identifier))
            #expect(abs(column.absoluteFrame.maxY - size.height) < 1)
            #expect(column.absoluteFrame.minY >= 0)
            #expect(column.absoluteFrame.maxX <= size.width)
        }
        let name = try container.uiNode(matching: .accessibilityIdentifier(ProjectOpeningAccessibility.projectName))
        let location = try container.uiNode(matching: .accessibilityIdentifier(ProjectOpeningAccessibility.location))
        let type = try container.uiNode(matching: .accessibilityIdentifier(ProjectOpeningAccessibility.projectType))
        let actions = try container.uiNode(matching: .accessibilityIdentifier(ProjectOpeningAccessibility.createActions))
        #expect(name.absoluteFrame.height >= 44)
        #expect(name.absoluteFrame.maxY <= location.absoluteFrame.minY)
        #expect(location.absoluteFrame.maxY <= type.absoluteFrame.minY)
        #expect(type.absoluteFrame.maxY <= actions.absoluteFrame.minY)
        #expect(abs(actions.absoluteFrame.maxY - (size.height - ProjectOpeningLayout.detailBottomPadding)) < 1)
    }

    @Test(
        "iPad creation uses a navigation title and ordered fields",
        arguments: [
            Size(width: 1194, height: 834),
            Size(width: 834, height: 1194),
        ]
    )
    @MainActor
    func iPadCreationLayout(_ size: Size) async throws {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            let app = AppWorlds(main: World(name: "ProjectOpeningLayoutTests"))
            RenderWorldPlugin().setup(in: app)
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = ProjectOpeningViewModel(store: EditorProjectStore(storageURL: root.appendingPathComponent("projects.json")))
        model.beginCreateNewProject()
        let container = UIContainerView(
            rootView: ProjectOpeningView(autoOpenLastProject: false, viewModel: model)
                .environment(\.userInterfaceIdiom, .pad)
        )
        container.safeAreaInsets = EdgeInsets(top: 32, leading: 0, bottom: 20, trailing: 0)
        container.frame = Rect(origin: .zero, size: size)
        container.bounds.size = size
        container.layoutIfNeeded()

        let title = try container.uiNode(matching: .accessibilityIdentifier("AdaUI.NavigationBar.Title"))
        let name = try container.uiNode(matching: .accessibilityIdentifier(ProjectOpeningAccessibility.projectName))
        let location = try container.uiNode(matching: .accessibilityIdentifier(ProjectOpeningAccessibility.location))
        let type = try container.uiNode(matching: .accessibilityIdentifier(ProjectOpeningAccessibility.projectType))
        let actions = try container.uiNode(matching: .accessibilityIdentifier(ProjectOpeningAccessibility.createActions))
        let detail = try container.uiNode(matching: .accessibilityIdentifier(ProjectOpeningAccessibility.detail))

        #expect(title.absoluteFrame.minY >= 32)
        #expect(title.absoluteFrame.height > 0)
        #expect(title.absoluteFrame.maxY <= name.absoluteFrame.minY)
        #expect(name.absoluteFrame.maxY <= location.absoluteFrame.minY)
        #expect(location.absoluteFrame.maxY <= type.absoluteFrame.minY)
        #expect(detail.absoluteFrame.maxX <= size.width)
        #expect(actions.absoluteFrame.maxX <= size.width - ProjectOpeningLayout.detailPadding)
        #expect(actions.absoluteFrame.maxY <= size.height - 20)
        #expect(container.uiFindNodes(matching: .accessibilityIdentifier(ProjectOpeningAccessibility.createHeader)).isEmpty)
    }

    @Test("columns and creation form stay inside the minimum window")
    @MainActor
    func contentFitsMinimumWindow() async throws {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            let app = AppWorlds(main: World(name: "ProjectOpeningLayoutTests"))
            RenderWorldPlugin().setup(in: app)
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let viewModel = ProjectOpeningViewModel(store: EditorProjectStore(storageURL: root.appendingPathComponent("projects.json")))
        let container = UIContainerView(
            rootView: ProjectOpeningView(autoOpenLastProject: false, viewModel: viewModel)
        )
        container.frame = Rect(
            x: 0,
            y: 0,
            width: ProjectOpeningLayout.windowWidth,
            height: ProjectOpeningLayout.windowHeight
        )
        container.bounds.size = container.frame.size
        container.layoutIfNeeded()

        let sidebar = try container.uiNode(matching: .accessibilityIdentifier(ProjectOpeningAccessibility.sidebar))
        let explorer = try container.uiNode(matching: .accessibilityIdentifier(ProjectOpeningAccessibility.explorer))
        let detail = try container.uiNode(matching: .accessibilityIdentifier(ProjectOpeningAccessibility.detail))
        let search = try container.uiNode(matching: .accessibilityIdentifier(ProjectOpeningAccessibility.search))

        #expect(sidebar.absoluteFrame.width == ProjectOpeningLayout.sidebarWidth)
        #expect(explorer.absoluteFrame.minX == sidebar.absoluteFrame.maxX)
        #expect(explorer.absoluteFrame.width == ProjectOpeningLayout.explorerWidth)
        #expect(detail.absoluteFrame.minX == explorer.absoluteFrame.maxX)
        #expect(detail.absoluteFrame.maxX <= ProjectOpeningLayout.windowWidth)
        let landing = try container.uiNode(matching: .accessibilityIdentifier(ProjectOpeningAccessibility.landingContent))
        #expect(abs(landing.absoluteFrame.midX - detail.absoluteFrame.midX) < 1)
        #expect(abs(landing.absoluteFrame.midY - detail.absoluteFrame.midY) < 1)
        #expect(search.absoluteFrame.minY < 120)
        #expect(search.absoluteFrame.maxX <= explorer.absoluteFrame.maxX)

        container.frame.size = Size(width: 1600, height: 1000)
        container.bounds.size = container.frame.size
        container.layoutIfNeeded()
        let expandedDetail = try container.uiNode(matching: .accessibilityIdentifier(ProjectOpeningAccessibility.detail))
        let expandedLanding = try container.uiNode(matching: .accessibilityIdentifier(ProjectOpeningAccessibility.landingContent))
        #expect(abs(expandedLanding.absoluteFrame.midX - expandedDetail.absoluteFrame.midX) < 1)
        #expect(abs(expandedLanding.absoluteFrame.midY - expandedDetail.absoluteFrame.midY) < 1)
        container.frame.size = Size(width: ProjectOpeningLayout.windowWidth, height: ProjectOpeningLayout.windowHeight)
        container.bounds.size = container.frame.size
        container.layoutIfNeeded()

        _ = try container.uiTapNode(matching: .accessibilityIdentifier(ProjectOpeningAccessibility.createProject))
        for _ in 0..<100 {
            await Task.yield()
            container.internalUpdate(1.0 / 60.0)
            container.layoutIfNeeded()
            if (try? container.uiNode(matching: .accessibilityIdentifier("AdaUI.NavigationBar.Title"))) != nil {
                break
            }
        }

        let header = try container.uiNode(matching: .accessibilityIdentifier("AdaUI.NavigationBar.Title"))
        let description = try container.uiNode(matching: .accessibilityIdentifier(ProjectOpeningAccessibility.createDescription))
        let projectType = try container.uiNode(matching: .accessibilityIdentifier(ProjectOpeningAccessibility.projectType))
        let actions = try container.uiNode(matching: .accessibilityIdentifier(ProjectOpeningAccessibility.createActions))

        #expect(viewModel.newProjectSourceControl == .defaultForNewProjects)
        if EditorSourceControlProvider.lore.isAvailable {
            let loreLink = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.ProjectOpening.Lore.LearnMore"))
            #expect(loreLink.absoluteFrame.maxY <= ProjectOpeningLayout.windowHeight)
            #expect(loreLink.absoluteFrame.minY >= 0)
        }
        _ = try container.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.ProjectOpening.SourceControl.none"))
        #expect(!viewModel.shouldCreateGitRepository)
        _ = try container.uiTapNode(matching: .accessibilityIdentifier(ProjectOpeningAccessibility.gitToggle))
        #expect(viewModel.shouldCreateGitRepository)

        #expect(header.absoluteFrame.minY >= 0)
        #expect(header.absoluteFrame.maxY <= description.absoluteFrame.minY)
        #expect(description.absoluteFrame.maxY <= projectType.absoluteFrame.minY)
        #expect(actions.absoluteFrame.maxX <= ProjectOpeningLayout.windowWidth - ProjectOpeningLayout.detailPadding)
        #expect(actions.absoluteFrame.maxY <= ProjectOpeningLayout.windowHeight - ProjectOpeningLayout.detailBottomPadding)
    }
}
