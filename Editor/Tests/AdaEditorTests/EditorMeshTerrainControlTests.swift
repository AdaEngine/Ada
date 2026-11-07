@_spi(AdaEngine) @testable import AdaEngine
@_spi(Internal) import AdaUI
import Testing

@testable import AdaEditor

@MainActor
@Suite("Mesh terrain native controls", .serialized)
struct EditorMeshTerrainControlTests {
    init() {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            RenderWorldPlugin().setup(in: AppWorlds(main: World(name: "Mesh terrain controls")))
        }
    }

    @Test("Joining controls retain the chosen target and prevent actions while a generation is pending")
    func joiningPanelSelectsTargetAndDisablesPendingActions() throws {
        let state = EditorTerrainEditingState()
        state.dockTab = "Joining"
        state.meshSourceName = "Oak trunk"
        state.meshTargets = [.init(id: "ground", name: "Ground"), .init(id: "island", name: "Island")]
        state.meshTargetEditorID = "ground"
        var joined = 0
        state.sourceActions = .init(create: {}, materials: {}, variation: {}, mesh: {}, texture: {}, extend: {}, generate: {}, join: { joined += 1 })
        let previousPresenter = ContextMenuPresentationCenter.present
        var presentation: ContextMenuPresentation?
        ContextMenuPresentationCenter.present = { presentation = $0 }
        defer { ContextMenuPresentationCenter.present = previousPresenter }
        let container = UIContainerView(rootView: EditorTerrainDockPanel(state: state, onChange: {}).theme(.adaEditor))
        container.frame = Rect(x: 0, y: 0, width: 1_100, height: 280)
        container.layoutSubviews()
        let join = UINodeSelector.accessibilityIdentifier("AdaEditor.Terrain.JoinSelected")
        #expect(container.uiFindNodes(matching: join).count == 1)
        guard !container.uiFindNodes(matching: join).isEmpty else { return }
        _ = try container.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.Terrain.JoinTarget"))
        let menu = try #require(presentation)
        let choose = try #require(menu.items.first { $0.title == "Island" }?.action)
        choose()
        #expect(state.meshTargetEditorID == "island")
        container.update(1 / 60); container.layoutIfNeeded()
        presentation = nil
        _ = try container.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.Terrain.JoinTarget"))
        #expect(presentation?.items.filter(\.isSelected).map(\.title) == ["Island"])
        _ = try container.uiTapNode(matching: join)
        #expect(joined == 1)
        state.isSourceBusy = true
        container.update(1 / 60); container.layoutIfNeeded()
        _ = try container.uiTapNode(matching: join)
        #expect(joined == 1)
        state.isSourceBusy = false
        state.meshSourceName = nil
        container.update(1 / 60); container.layoutIfNeeded()
        _ = try container.uiTapNode(matching: join)
        #expect(joined == 1)
    }
}
