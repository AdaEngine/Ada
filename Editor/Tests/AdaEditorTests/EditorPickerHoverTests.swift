@_spi(AdaEngine) import AdaEngine
import AdaInput
@_spi(Internal) import AdaUI
import Foundation
import Math
import Testing

@testable import AdaEditor

@MainActor
@Suite("Picker row hover", .serialized)
struct EditorPickerHoverTests {
    init() {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            RenderWorldPlugin().setup(in: AppWorlds(main: World(name: "PickerHoverTests")))
        }
    }

    @Test("Project rows and the local-project footer highlight across their full width without changing selection")
    func projectSwitcher() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PickerHover-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = EditorProjectStore(storageURL: root.appendingPathComponent("recents.json"))
        let current = try store.createProject(named: "Current", at: root, template: .adaScript)
        _ = try store.createProject(named: "First", at: root, template: .adaScript)
        _ = try store.createProject(named: "Second", at: root, template: .adaScript)
        let model = EditorProjectSwitcherViewModel(currentProject: current, store: store)
        model.toggle()
        let recent = try #require(model.filteredRecentProjects.first)
        var opened: EditorProjectReference?
        let container = UIContainerView(rootView: EditorProjectSwitcherPanel(
            viewModel: model, onOpenProject: { opened = $0 }
        ).theme(.adaEditor))
        prepare(container, size: Size(width: EditorProjectSwitcherLayout.width, height: EditorProjectSwitcherLayout.height))
        let selectedColor = Theme.adaEditor.editorColors.surface.opacity(0.72)
        let selectionCount = fillCount(container, color: selectedColor)
        #expect(selectionCount > 0)
        let rows = [current] + model.filteredRecentProjects
        let identifiers = rows.map { "AdaEditor.ProjectSwitcher.Project.\($0.id)" }
            + ["AdaEditor.ProjectSwitcher.OpenLocalProject"]
        let frames = try identifiers.map { try container.uiNode(matching: .accessibilityIdentifier($0)).absoluteFrame }
        for frame in frames {
            try checkHover(container, at: Point(frame.maxX - 10, frame.midY), outside: Point(2, 2))
            #expect(model.currentProject == current)
            #expect(opened == nil)
            #expect(fillCount(container, color: selectedColor) == selectionCount)
        }
        let row = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.ProjectSwitcher.Project.\(recent.id)"))
        click(container, at: Point(row.absoluteFrame.maxX - 10, row.absoluteFrame.midY))
        #expect(opened?.path == recent.path)
        #expect(!model.isPresented)
    }

    @Test("Targets and Files rows hover at their edges while keeping the selected background and click action")
    func displayModes() throws {
        let model = EditorProjectSidebarViewModel(items: [], displayMode: .targets, isDisplayModeMenuPresented: true)
        let container = UIContainerView(rootView: EditorProjectSidebar(
            viewModel: model, projectRootItem: nil, onOpenItem: { _ in },
            onOpenRawItem: { _ in }, onNewFile: { _ in }, onImportAssets: {}, onDropFiles: { _ in true },
            onRevealItem: { _ in }, onOpenInDefaultApplication: { _ in }, onOpenInTerminal: { _ in },
            onFindInFolder: { _ in }, onFindInProjectRoot: {}, onCopyPath: { _, _ in }, onDeleteItem: { _ in }
        ).theme(.adaEditor))
        prepare(container, size: Size(width: 320, height: 400))
        let selectedColor = Theme.adaEditor.editorColors.blue.opacity(0.34)
        let selectionCount = fillCount(container, color: selectedColor)
        #expect(selectionCount > 0)
        for mode in EditorProjectSidebarViewModel.DisplayMode.allCases {
            let row = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.ProjectTree.DisplayMode.\(mode.title)"))
            #expect(row.absoluteFrame.width == 156)
            try checkHover(container, at: Point(row.absoluteFrame.maxX - 4, row.absoluteFrame.midY), outside: Point(315, 399))
            #expect(model.displayMode == .targets)
            #expect(model.isDisplayModeMenuPresented)
            #expect(fillCount(container, color: selectedColor) == selectionCount)
        }
        let files = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.ProjectTree.DisplayMode.Files"))
        click(container, at: Point(files.absoluteFrame.maxX - 4, files.absoluteFrame.midY))
        #expect(model.displayMode == .files)
        #expect(!model.isDisplayModeMenuPresented)
    }

    private func prepare<Content: View>(_ container: UIContainerView<Content>, size: Size) {
        container.frame = Rect(origin: .zero, size: size)
        container.bounds.size = size
        container.layoutIfNeeded()
    }

    private func checkHover<Content: View>(_ container: UIContainerView<Content>, at point: Point, outside: Point) throws {
        let color = Theme.adaEditor.editorColors.text.opacity(0.10)
        move(container, to: outside)
        let normalCount = fillCount(container, color: color)
        move(container, to: point)
        #expect(fillCount(container, color: color) == normalCount + 1)
        move(container, to: outside)
        #expect(fillCount(container, color: color) == normalCount)
    }

    private func move<Content: View>(_ container: UIContainerView<Content>, to point: Point) {
        container.onMouseEvent(MouseEvent(
            window: .empty, button: .none, mousePosition: point, phase: .changed, modifierKeys: [], time: 0
        ))
        container.update(1 / 60)
        container.layoutIfNeeded()
    }

    private func click<Content: View>(_ container: UIContainerView<Content>, at point: Point) {
        for phase in [MouseEvent.Phase.began, .ended] {
            container.onMouseEvent(MouseEvent(
                window: .empty, button: .left, mousePosition: point, phase: phase, modifierKeys: [], time: 1
            ))
        }
    }

    private func fillCount<Content: View>(_ container: UIContainerView<Content>, color target: Color) -> Int {
        let context = UIGraphicsContext()
        container.draw(in: container.bounds, with: context)
        return context.getDrawCommands().filter { command in
            switch command {
            case let .drawPath(_, _, .fill(color)), let .drawQuad(_, _, color): color == target
            default: false
            }
        }.count
    }
}
