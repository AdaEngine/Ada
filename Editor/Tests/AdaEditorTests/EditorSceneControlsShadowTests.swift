@_spi(AdaEngine) import AdaEngine
import Testing

@testable import AdaEditor

@Suite("Scene controls shadow")
@MainActor
struct EditorSceneControlsShadowTests {
    @Test("Capsule shadow records a shader effect and compiles its shader")
    func shadowShaderCompiles() throws {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            RenderWorldPlugin().setup(in: AppWorlds(main: World(name: "SceneControlsShadow")))
        }
        let controls = EditorSceneViewportControls(
            activeTool: .translate,
            displayMode: .threeD,
            isPlaying: false,
            size: Size(width: 900, height: 500),
            onPlay: {},
            onSelectDisplayMode: { _ in },
            onSelectTool: { _ in },
            onStop: {}
        )
        let container = UIContainerView(rootView: controls.theme(.adaEditor))
        container.frame = Rect(x: 0, y: 0, width: 900, height: 500)
        container.bounds.size = container.frame.size
        container.layoutIfNeeded()

        let context = UIGraphicsContext()
        container.draw(with: context)
        let material = try #require(context.getDrawCommands().compactMap { command -> Material? in
            guard case let .drawShaderEffect(_, material) = command else {
                return nil
            }
            return material
        }.first)

        _ = try material.makeShaderModule(defines: [])
    }
}
