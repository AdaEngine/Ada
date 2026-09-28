import AdaApp
import AdaECS

public struct ScenePlugin: Plugin {
    private let includesModel3D: Bool

    /// Creates scene support with optional installation of the built-in 3D model pipeline.
    /// - Parameter includesModel3D: Whether scene setup should install ``Model3DPlugin``.
    public init(includesModel3D: Bool = true) {
        self.includesModel3D = includesModel3D
    }

    public func setup(in app: AppWorlds) {
        EditorGizmo.registerComponent()
        SceneInstance.registerComponent()
        if app.main.getResource(SceneNavigator.self) == nil {
            app.main.insertResource(SceneNavigator(world: app.main))
        }
        KeyframeAnimationPlugin().setup(in: app)
        if includesModel3D {
            Model3DPlugin().setup(in: app)
        }
        app.addSystem(DynamicSceneInitSystem.self)
        app.addSystem(SceneNavigationSystem.self, on: .postUpdate)
    }
}
