@_spi(AdaEngine) import AdaEngine
@_spi(Internal) import AdaUI
import Foundation
import Testing

@testable import AdaEditor

@Suite("Editor project switcher", .serialized)
@MainActor
struct EditorProjectSwitcherTests {
    @Test("Opening invalid project metadata shows its cause and recovery suggestion")
    func invalidProjectError() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let metadata = root.appendingPathComponent(".ada/project.json")
        try FileManager.default.createDirectory(at: metadata.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "not valid JSON".write(to: metadata, atomically: true, encoding: .utf8)
        let store = EditorProjectStore(storageURL: root.appendingPathComponent("recents.json"))
        let model = EditorProjectSwitcherViewModel(currentProject: nil, store: store)
        model.toggle()
        #expect(model.projectForOpening(at: root) == nil)
        let message = try #require(model.errorMessage)
        #expect(message.contains("JSON"))
        #expect(message.contains("Fix the JSON syntax"))
        #expect(!message.contains("ProjectSystemError"))
        #expect(model.isPresented)
        #expect(try store.loadProjects().isEmpty)
    }

    @Test("Section headers and footer keep their height when an opening error is shown", arguments: [false, true])
    func errorDoesNotCompressHeaders(hasCurrentProject: Bool) async throws {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            RenderWorldPlugin().setup(in: AppWorlds(main: World(name: "ProjectSwitcherTests")))
        }
        let current = EditorProjectReference(name: "Current", path: "/tmp/Current.adaproject")
        let model = EditorProjectSwitcherViewModel(currentProject: hasCurrentProject ? current : nil)
        model.recentProjects = (0..<20).map { EditorProjectReference(name: "Project \($0)", path: "/tmp/Project\($0)") }
        let size = Size(width: EditorProjectSwitcherLayout.width, height: EditorProjectSwitcherLayout.height)
        let container = UIContainerView(rootView: EditorProjectSwitcherPanel(viewModel: model, onOpenProject: { _ in }).theme(.adaEditor))
        container.frame = Rect(origin: .zero, size: size)
        container.bounds.size = size
        container.layoutIfNeeded()
        let listBefore = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.ProjectSwitcher.List"))
        let originalListHeight = listBefore.absoluteFrame.height
        model.errorMessage = String(repeating: "The project metadata is invalid. Fix .ada/project.json and try again. ", count: 6)
        try await Task.sleep(for: .milliseconds(50))
        container.layoutIfNeeded()
        let recentTitle = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.ProjectSwitcher.Section.Recent Projects"))
        #expect(recentTitle.absoluteFrame.height >= EditorProjectSwitcherLayout.sectionHeaderHeight)
        if hasCurrentProject {
            let currentTitle = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.ProjectSwitcher.Section.This Window"))
            #expect(currentTitle.absoluteFrame.height >= EditorProjectSwitcherLayout.sectionHeaderHeight)
            #expect(currentTitle.absoluteFrame.maxY <= recentTitle.absoluteFrame.minY)
        }
        let list = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.ProjectSwitcher.List"))
        let error = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.ProjectSwitcher.Error"))
        let footer = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.ProjectSwitcher.OpenLocalProject"))
        #expect(list.absoluteFrame.height < originalListHeight)
        #expect(list.absoluteFrame.maxY <= error.absoluteFrame.minY + 1)
        #expect(error.absoluteFrame.height == EditorProjectSwitcherLayout.errorHeight)
        #expect(error.absoluteFrame.maxY <= footer.absoluteFrame.minY + 1)
        #expect(footer.absoluteFrame.height == 36)
        #expect(footer.absoluteFrame.maxY <= size.height)
    }
}
