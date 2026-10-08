//
//  RuntimeWindow.swift
//  AdaEngine
//
//  Created by Codex on 26.04.2026.
//

import AdaApp
import AdaECS
import AdaRender
import AdaScene
@_spi(Internal) import AdaUI
import AdaUtils
import Math

extension UIWindowManager {
    @MainActor
    @discardableResult
    public func spawnWindow<Content: View>(
        configuration: UIWindow.Configuration,
        @ViewBuilder content: () -> Content
    ) -> UIWindow {
        let window = UIWindow(configuration: configuration)
        let container = UIContainerView(rootView: content())
        container.backgroundColor = .clear
        container.autoresizingRules = [.flexibleWidth, .flexibleHeight]
        container.frame = Rect(origin: .zero, size: window.frame.size)
        window.addSubview(container)
        container.layoutSubviews()

        var camera = Camera(window: .windowId(window.id))
        if configuration.background.isTransparent {
            camera.backgroundColor = Color(red: 0, green: 0, blue: 0, alpha: 0)
        }
        let cameraEntity = AppWorldsSession.current?
            .spawn(
                bundle: Camera2D(camera: camera)
            )
        window.runtimeCameraEntity = cameraEntity

        if configuration.showsImmediately {
            window.showWindow(makeFocused: configuration.makeKey)
        }
        return window
    }
}
