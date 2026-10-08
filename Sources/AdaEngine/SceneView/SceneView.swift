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
/// `onFrameRendered` receives the scene texture on the main actor after GPU completion.
/// Read pixels during the callback; the texture is reused for subsequent frames.
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
    let isInteractive: Bool
    let make: @MainActor (inout AppWorlds) -> Void
    let updateContent: @MainActor (World, AdaUtils.TimeInterval) -> Void
    let onFrameRendered: (@MainActor (Texture2D) -> Void)?
    let placeholder: @MainActor () -> Placeholder

    public init(
        isInteractive: Bool = true,
        make: @escaping @MainActor (inout AppWorlds) -> Void,
        updateContent: @escaping @MainActor (World, AdaUtils.TimeInterval) -> Void,
        onFrameRendered: (@MainActor (Texture2D) -> Void)? = nil
    ) where Placeholder == EmptyView {
        self.isInteractive = isInteractive
        self.make = make
        self.updateContent = updateContent
        self.onFrameRendered = onFrameRendered
        self.placeholder = { EmptyView() }
    }

    public init(
        isInteractive: Bool = true,
        make: @escaping @MainActor (inout AppWorlds) -> Void,
        updateContent: @escaping @MainActor (World, AdaUtils.TimeInterval) -> Void,
        onFrameRendered: (@MainActor (Texture2D) -> Void)? = nil,
        @ViewBuilder placeholder: @escaping @MainActor () -> Placeholder
    ) {
        self.isInteractive = isInteractive
        self.make = make
        self.updateContent = updateContent
        self.onFrameRendered = onFrameRendered
        self.placeholder = placeholder
    }

    public var body: some View {
        OffscreenViewportContainer(
            delegateFactory: { [make, updateContent, onFrameRendered] in
                SceneViewCoordinator(
                    make: make,
                    updateContent: updateContent,
                    onFrameRendered: onFrameRendered
                )
            },
            contentBuilder: { [placeholder, isInteractive] delegate in
                let coordinator = delegate as! SceneViewCoordinator
                ZStack {
                    OffscreenViewportView(delegate: coordinator, isInteractive: isInteractive)

                    if coordinator.renderTexture == nil {
                        placeholder()
                    }
                }
            }
        )
    }
}
