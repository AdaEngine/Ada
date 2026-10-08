import AdaApp

struct PreferredRenderBackendSceneModifier: SceneModifier {
    let backend: RenderBackendType

    func body(content: Content) -> some AppScene {
        unsafe RenderEngine.configurations.preferredBackend = backend
        return content
    }
}

struct RenderUpscalingSceneModifier: SceneModifier {
    let mode: RenderUpscalingMode

    func body(content: Content) -> some AppScene {
        unsafe RenderEngine.configurations.upscaling = mode
        return content
    }
}

extension AppScene {
    /// Set the preferred render backend for the scene.
    public func preferredRenderBackend(_ backend: RenderBackendType) -> some AppScene {
        self.modifier(PreferredRenderBackendSceneModifier(backend: backend))
    }

    /// Configures spatial upscaling for window render targets.
    public func renderUpscaling(_ mode: RenderUpscalingMode) -> some AppScene {
        self.modifier(RenderUpscalingSceneModifier(mode: mode))
    }
}
