//
//  ProjectEditorLauncher.swift
//  AdaEngine
//

@_spi(AdaEngine) import AdaEngine

enum EditorWindowSafeAreaPolicy {
    #if os(Windows)
        static let dragRegionHeight: Float = 32
    #else
        static let dragRegionHeight: Float = 52
    #endif
    #if os(iOS)
        static let reservesSystemSafeArea = true
    #else
        static let reservesSystemSafeArea = false
    #endif
}

@MainActor
enum ProjectEditorLauncher {
    /// Native scene wrappers provide these routes instead of spawning a second application.
    static var nativeProjectOpener: ((EditorProjectReference) -> Void)?
    static var nativeWelcomeOpener: ((Bool) -> Void)?
    static let windowTitlePrefix = "AdaEditor"
    static let windowWidth: Float = 1280
    static let windowHeight: Float = 800
    static let trafficLightOffsetY: Float = 4

    static func openEditor(
        for project: EditorProjectReference,
        closing pickerWindow: UIWindow? = UIWindowManager.shared?.activeWindow
            ?? AppWorldsSession.current?.main.getResource(PrimaryWindow.self)?.window
    ) {
        if let nativeProjectOpener {
            nativeProjectOpener(project)
            return
        }
        guard let manager = UIWindowManager.shared else {
            return
        }
        let configuration = UIWindow.Configuration(
            title: L10n.text("Ada - \(project.name)"),
            frame: Rect(x: 0, y: 0, width: ProjectOpeningLayout.windowWidth, height: ProjectOpeningLayout.windowHeight),
            minimumSize: Size(width: ProjectOpeningLayout.windowWidth, height: ProjectOpeningLayout.windowHeight),
            mode: .fullScreenWindowed,
            titleBar: .init(
                background: .transparent,
                reservesSafeArea: EditorWindowSafeAreaPolicy.reservesSystemSafeArea,
                dragRegionHeight: EditorWindowSafeAreaPolicy.dragRegionHeight,
                trafficLightOffset: Point(x: 0, y: Self.trafficLightOffsetY)
            ),
            showsImmediately: false,
            makeKey: true
        )

        let editorWindow = manager.spawnWindow(configuration: configuration) {
            EditorView(project: project)
        }
        promoteToPrimaryWindow(editorWindow)
        editorWindow.showWindow(makeFocused: true)
        // Auto-open can finish while Studio is unfocused, so the source window
        // falls back to the previous primary window instead of being left open.
        pickerWindow?.close()
    }

    static func openWelcome(makeFocused: Bool = true, beginCreatingProject: Bool = false) {
        if let nativeWelcomeOpener {
            nativeWelcomeOpener(beginCreatingProject)
            return
        }
        guard let manager = UIWindowManager.shared else {
            return
        }
        let configuration = UIWindow.Configuration(
            title: windowTitlePrefix,
            frame: Rect(x: 0, y: 0, width: ProjectOpeningLayout.windowWidth, height: ProjectOpeningLayout.windowHeight),
            minimumSize: Size(width: ProjectOpeningLayout.windowWidth, height: ProjectOpeningLayout.windowHeight),
            mode: .windowed,
            titleBar: .init(
                background: .transparent,
                reservesSafeArea: EditorWindowSafeAreaPolicy.reservesSystemSafeArea,
                dragRegionHeight: EditorWindowSafeAreaPolicy.dragRegionHeight,
                trafficLightOffset: Point(x: 0, y: ProjectOpeningLayout.trafficLightOffsetY)
            ),
            showsImmediately: false,
            makeKey: true,
            hasShadow: ProjectOpeningWindowConfiguration.hasShadow,
            isResizable: ProjectOpeningWindowConfiguration.isResizable
        )
        let window = manager.spawnWindow(configuration: configuration) {
            ProjectOpeningView(autoOpenLastProject: false, initiallyCreatingProject: beginCreatingProject)
        }
        promoteToPrimaryWindow(window)
        window.showWindow(makeFocused: makeFocused)
    }

    static func title(for project: EditorProjectReference) -> String {
        "\(project.name) - \(windowTitlePrefix)"
    }

    private static func promoteToPrimaryWindow(_ window: UIWindow) {
        AppWorldsSession.current?
            .insertResource(PrimaryWindow(window: window))
            .insertResource(PrimaryWindowId(windowId: window.id))
    }
}
