//
//  WindowSpawnModifier.swift
//  AdaEngine
//
//  Created by Vladislav Prusakov on 27.04.2026.
//

@_spi(Internal) import AdaUI
import AdaUtils
import Math

extension View {
    public func window<WindowContent: View>(
        isPresented: Binding<Bool>,
        configuration: UIWindow.Configuration,
        @ViewBuilder content: @escaping () -> WindowContent
    ) -> ModifiedContent<Self, PresentWindowViewModifier<WindowContent>> {
        modifier(
            PresentWindowViewModifier(isPresented: isPresented, configuration: configuration, windowContent: content)
        )
    }
}

public struct PresentWindowViewModifier<WindowContent: View>: ViewModifier {
    @Binding var isPresented: Bool
    let configuration: UIWindow.Configuration
    let windowContent: () -> WindowContent

    public func body(content: Content) -> some View {
        content
            .background(
                PresentWindowHolderView<WindowContent>(
                    isPresented: _isPresented,
                    configuration: configuration,
                    content: windowContent
                )
            )
    }
}

private struct PresentWindowHolderView<WindowContent: View>: View {
    @Binding var isPresented: Bool
    let configuration: UIWindow.Configuration
    var content: () -> WindowContent

    @State private var window: UIWindow?
    @Environment(\.windowManager) private var windowManager
    @Environment(\.world) private var world

    var body: some View {
        EmptyView()
            .onChange(of: isPresented) { _, newValue in
                if let window, !newValue {
                    dispawnWindow(window)
                } else if newValue {
                    spawnWindow()
                }
            }
    }

    private func spawnWindow() {
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
        let cameraEntity = world?
            .spawn(
                bundle: Camera2D(camera: camera)
            )
        window.runtimeCameraEntity = cameraEntity

        if configuration.showsImmediately {
            window.showWindow(makeFocused: configuration.makeKey)
        }
        self.window = window
    }

    private func dispawnWindow(_ window: UIWindow) {
        window.close()
        self.window = window
        self.isPresented = false
    }
}
