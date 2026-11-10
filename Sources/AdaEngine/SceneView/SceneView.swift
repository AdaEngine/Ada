//
//  SceneView.swift
//  AdaEngine
//
//  Created by AdaEngine on 04.04.2026.
//

import AdaApp
import AdaECS
import AdaRender
import AdaUI
import AdaUtils
import Math

/// A view that creates a separate offscreen runtime with its own `World`, renders it
/// into a `RenderTexture`, and embeds the result into the AdaUI view hierarchy.
///
/// The `make` closure is called exactly once per `SceneView` instance before the runtime
/// is built. Use it to configure plugins, resources, and initial scene content.
/// Set `useSceneCameras` to render with the game's active cameras (including 3D)
/// instead of creating a default 2D viewport camera. Their projections and transforms
/// are preserved; render targets and viewport sizes are owned by this view.
/// `onFrameRendered` receives the scene texture on the main actor at the next UI
/// update after GPU completion, when the frame becomes visible to the view.
/// Read pixels during the callback; the texture is reused for subsequent frames.
/// Set `updatesWhenWindowInactive` to false for editor previews: their runtime
/// and rendering stop while the containing window is inactive, retaining its last texture.
///
/// ```swift
/// SceneView(make: { app in
///     app.addPlugin(TransformPlugin())
///     app.main.spawn("Player") {
///         SpriteBundle(texture: playerTexture)
///     }
/// }, updateContent: { world, deltaTime in
///     // Update scene content.
/// })
/// ```
public struct SceneView<Placeholder: View>: View {
    let useSceneCameras: Bool
    let isInteractive: Bool
    let updatesWhenWindowInactive: Bool
    let make: @MainActor (inout AppWorlds) -> Void
    let updateContent: @MainActor (World, AdaUtils.TimeInterval) -> Void
    let onFrameRendered: (@MainActor (Texture2D) -> Void)?
    let placeholder: @MainActor () -> Placeholder
    private var prepareFramePresentation: (@MainActor () -> (@MainActor () -> Void))?
    private var frameCaptureLabel: String?
    private var pipelinedRendering = false

    /// Makes completed frames of this scene readable through ``SceneViewFrameRegistry``.
    ///
    /// Use it for the running game, never for editor tooling previews, so automation
    /// captures the game camera instead of the surrounding window.
    public func frameCaptureLabel(_ label: String?) -> Self {
        var view = self
        view.frameCaptureLabel = label
        return view
    }

    /// Renders this scene one frame behind its simulation, overlapping the scene's rendering with the
    /// next frame's simulation and the window's UI. Frames take about as long as the slower of the two
    /// instead of their sum; input reaches the screen one frame later.
    ///
    /// Scene systems must follow the pipelined-rendering rules: render systems read the scene only
    /// during extraction, and gameplay code does not mutate assets in place while they are rendered.
    public func pipelinedRendering(_ isEnabled: Bool = true) -> Self {
        var view = self
        view.pipelinedRendering = isEnabled
        return view
    }

    /// Captures companion UI state for a scheduled scene frame. The returned
    /// closure runs when that exact frame becomes the displayed texture, before
    /// UI drawing. Frames discarded by resize or shutdown are never presented.
    @_spi(AdaEngine)
    public func onPrepareFramePresentation(
        _ prepare: @escaping @MainActor () -> (@MainActor () -> Void)
    ) -> Self {
        var view = self
        view.prepareFramePresentation = prepare
        return view
    }

    public init(
        isInteractive: Bool = true,
        useSceneCameras: Bool = false,
        updatesWhenWindowInactive: Bool = true,
        make: @escaping @MainActor (inout AppWorlds) -> Void,
        updateContent: @escaping @MainActor (World, AdaUtils.TimeInterval) -> Void,
        onFrameRendered: (@MainActor (Texture2D) -> Void)? = nil
    ) where Placeholder == EmptyView {
        self.useSceneCameras = useSceneCameras
        self.isInteractive = isInteractive
        self.updatesWhenWindowInactive = updatesWhenWindowInactive
        self.make = make
        self.updateContent = updateContent
        self.onFrameRendered = onFrameRendered
        self.placeholder = { EmptyView() }
    }

    public init(
        isInteractive: Bool = true,
        useSceneCameras: Bool = false,
        updatesWhenWindowInactive: Bool = true,
        make: @escaping @MainActor (inout AppWorlds) -> Void,
        updateContent: @escaping @MainActor (World, AdaUtils.TimeInterval) -> Void,
        onFrameRendered: (@MainActor (Texture2D) -> Void)? = nil,
        @ViewBuilder placeholder: @escaping @MainActor () -> Placeholder
    ) {
        self.useSceneCameras = useSceneCameras
        self.isInteractive = isInteractive
        self.updatesWhenWindowInactive = updatesWhenWindowInactive
        self.make = make
        self.updateContent = updateContent
        self.onFrameRendered = onFrameRendered
        self.placeholder = placeholder
    }

    public var body: some View {
        OffscreenViewportContainer(
            delegateFactory: { [make, updateContent, onFrameRendered, useSceneCameras, prepareFramePresentation, frameCaptureLabel, pipelinedRendering] in
                SceneViewCoordinator(
                    useSceneCameras: useSceneCameras,
                    make: make,
                    updateContent: updateContent,
                    onFrameRendered: onFrameRendered,
                    prepareFramePresentation: prepareFramePresentation,
                    frameCaptureLabel: frameCaptureLabel,
                    pipelinedRendering: pipelinedRendering
                )
            },
            contentBuilder: { [placeholder, isInteractive, updatesWhenWindowInactive] delegate in
                let coordinator = delegate as! SceneViewCoordinator
                ZStack {
                    OffscreenViewportView(delegate: coordinator, isInteractive: isInteractive, updatesWhenWindowInactive: updatesWhenWindowInactive)

                    if coordinator.renderTexture == nil {
                        placeholder()
                    }
                }
            }
        )
    }
}
