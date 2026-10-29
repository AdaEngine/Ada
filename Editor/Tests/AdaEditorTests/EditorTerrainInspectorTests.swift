@_spi(AdaEngine) import AdaEngine
@_spi(Internal) import AdaUI
import Testing

@testable import AdaEditor

@MainActor
extension EditorLocalizationTests {
    @Test("Brush controls fit a narrow Inspector, update the active brush and survive language changes")
    func mountedInspector() async throws {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            RenderWorldPlugin().setup(in: AppWorlds(main: World(name: "TerrainInspector")))
        }
        let previousLanguage = EditorLocalization.shared.preference
        defer { EditorLocalization.shared.preference = previousLanguage }
        let viewport = EditorSceneViewportModel()
        viewport.setTerrainEditing(true)
        let inspector = EditorInspectorSidebarViewModel()
        attach(inspector, to: viewport)
        var creations = 0
        var changes = 0
        inspector.setTerrainTools(owner: viewport, state: viewport.terrainEditing, create: { creations += 1 }, settingsChanged: { changes += 1 })
        let container = UIContainerView(rootView: EditorInspectorSidebar(viewModel: inspector).theme(.adaEditor))
        container.frame = Rect(x: 0, y: 0, width: 300, height: 720)
        container.bounds.size = container.frame.size
        container.layoutIfNeeded()
        let controls = EditorTerrainBrushMode.allCases.map { "AdaEditor.Terrain.Mode.\($0.rawValue)" }
            + ["AdaEditor.Terrain.Radius", "AdaEditor.Terrain.Strength", "AdaEditor.Terrain.Create"]
        for language in [EditorLanguage.english, .russian] {
            EditorLocalization.shared.preference = language
            await refresh(container)
            for identifier in controls {
                let node = try container.uiNode(matching: .accessibilityIdentifier(identifier))
                #expect(node.absoluteFrame.origin.x >= 0)
                #expect(node.absoluteFrame.origin.x + node.absoluteFrame.size.width <= 300.5)
                #expect(node.absoluteFrame.size.width > 0)
                #expect(node.absoluteFrame.origin.y + node.absoluteFrame.size.height <= 720)
            }
            let slider = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.Terrain.Radius"))
            #expect(slider.absoluteFrame.size.width > 200)
        }
        _ = try container.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.Terrain.Mode.Lower Ground"))
        #expect(viewport.terrainEditing.mode == .lower)
        #expect(changes == 1)
        _ = try container.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.Terrain.Create"))
        #expect(creations == 1)
        inspector.isInspectingPlayMode = true
        await refresh(container)
        #expect(container.uiFindNodes(matching: .accessibilityIdentifier("AdaEditor.Terrain.Panel")).isEmpty)
        inspector.isInspectingPlayMode = false
        viewport.setTerrainEditing(false)
        await refresh(container)
        #expect(container.uiFindNodes(matching: .accessibilityIdentifier("AdaEditor.Terrain.Panel")).isEmpty)
    }

    @Test("Switching scenes replaces brush ownership and closing an old viewport preserves the current controls")
    func sceneOwnership() {
        let inspector = EditorInspectorSidebarViewModel()
        let first = EditorSceneViewportModel()
        let second = EditorSceneViewportModel()
        first.terrainEditing.mode = .flatten
        first.terrainEditing.radius = 12
        attach(inspector, to: first)
        inspector.setTerrainTools(owner: first, state: first.terrainEditing, create: {}, settingsChanged: {})
        #expect(inspector.terrainEditing === first.terrainEditing)
        attach(inspector, to: second)
        #expect(inspector.terrainEditing == nil)
        var creations = 0
        inspector.setTerrainTools(owner: second, state: second.terrainEditing, create: { creations += 1 }, settingsChanged: {})
        inspector.clearSceneViewportActions(owner: first)
        #expect(inspector.terrainEditing === second.terrainEditing)
        #expect(inspector.terrainEditing?.mode == .raise)
        #expect(inspector.terrainEditing?.radius == 4)
        inspector.createTerrainRequested()
        #expect(creations == 1)
        inspector.clearSceneViewportActions(owner: second)
        #expect(inspector.terrainEditing == nil)
        inspector.createTerrainRequested()
        #expect(creations == 1)
    }

    private func attach(_ inspector: EditorInspectorSidebarViewModel, to viewport: EditorSceneViewportModel) {
        inspector.setSceneViewportActions(
            owner: viewport, applyGizmoChange: { _ in }, addEntity: { _ in }, addComponent: { _ in }, removeComponent: { _ in },
            updateComponentField: { _, _, _ in }, addScriptableObject: { _ in }, removeScriptableObject: { _ in },
            updateScriptableObjectField: { _, _, _ in }
        )
    }

    private func refresh<Content: View>(_ container: UIContainerView<Content>) async {
        for _ in 0..<10 {
            await Task.yield()
            container.update(1 / 60)
            container.layoutIfNeeded()
        }
    }
}
