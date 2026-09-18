//
//  WindowGroup.swift
//  AdaEngine
//
//  Created by Vladislav Prusakov on 08.06.2024.
//

import AdaApp
import AdaECS
import AdaScene
import AdaUtils
import Foundation
import Math

/// A scene that presents a group of identically structured windows.
public struct WindowGroup<Content: View>: AppScene {
    /// Content view
    let content: Content

    /// The file path to use for the `AssetsPlugin`.
    let filePath: StaticString
    let assetBundle: Bundle?

    public var body: some AppScene {
        DefaultAppWindow(filePath: filePath, assetBundle: assetBundle)
            .addPlugins(WindowGroupPlugin(content: self.content))
    }

    /// Creates a window group.
    /// - Parameter contentView: A closure that creates the content for each instance of the group.
    /// - Parameter filePath: The file path to use for the `AssetsPlugin`.
    public init(@ViewBuilder content: () -> Content, filePath: StaticString = #filePath, assetBundle: Bundle? = nil) {
        self.content = content()
        self.filePath = filePath
        self.assetBundle = assetBundle
    }
}

package struct WindowGroupPlugin<Content: View>: Plugin, @unchecked Sendable {
    let content: Content

    package func setup(in app: borrowing AppWorlds) {
        if app.getResource(ApplicationFramePacing.self) == nil {
            app.insertResource(ApplicationFramePacing.displaySynchronized())
        }
        app.insertResource(
            InitialContainerView {
                UIContainerView(rootView: self.content)
            }
        )
        app.addSystem(WindowGroupUpdateSystem.self, on: .startup)

        var camera = Camera()
        camera.backgroundColor = .clear
        app.spawn(bundle: Camera2D(camera: camera))
    }
}

struct InitialContainerView: Resource, @unchecked Sendable {
    var view: UIView?
    let makeView: @MainActor () -> UIView

    init(makeView: @escaping @MainActor () -> UIView) {
        self.makeView = makeView
    }
}

@System
@MainActor
func WindowGroupUpdate(
    _ context: WorldUpdateContext,
    _ primaryWindow: Res<PrimaryWindow>,
    _ containerView: ResMut<InitialContainerView>
) {
    let targetWindow = primaryWindow.window
    let view: UIView
    if let existingView = containerView.wrappedValue.view {
        view = existingView
    } else {
        view = containerView.wrappedValue.makeView()
        containerView.wrappedValue.view = view
    }

    guard
        let currentPrimaryWindow = context.world.getResource(PrimaryWindow.self)?.window,
        currentPrimaryWindow === targetWindow,
        targetWindow.windowManager.windows[targetWindow.id] != nil
    else {
        return
    }

    if view.parentView === targetWindow {
        return
    }

    if view.parentView != nil {
        view.removeFromParentView()
    }

    view.autoresizingRules = [.flexibleWidth, .flexibleHeight]
    view.frame = targetWindow.bounds
    view.backgroundColor = .clear
    targetWindow.backgroundColor = .clear
    targetWindow.addSubview(view)
    view.layoutSubviews()
}
