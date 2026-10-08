//
//  ProjectEditorLauncher.swift
//  AdaEngine
//

@_spi(AdaEngine) import AdaEngine

enum EditorWindowSafeAreaPolicy {
    #if os(iOS)
        static let reservesSystemSafeArea = true
    #else
        static let reservesSystemSafeArea = false
    #endif
}

@MainActor
enum ProjectEditorLauncher {
    static let windowTitlePrefix = "AdaEditor"
    static let windowWidth: Float = 1280
    static let windowHeight: Float = 800

    static func openEditor(
        for project: EditorProjectReference,
        closing pickerWindow: UIWindow? = UIWindowManager.shared?.activeWindow
    ) {
        let configuration = UIWindow.Configuration(
            title: "Ada - \(project.name)",
            frame: Rect(x: 0, y: 0, width: ProjectOpeningLayout.windowWidth, height: ProjectOpeningLayout.windowHeight),
            minimumSize: Size(width: ProjectOpeningLayout.windowWidth, height: ProjectOpeningLayout.windowHeight),
            mode: .fullScreenWindowed,
            titleBar: .init(
                background: .transparent,
                reservesSafeArea: EditorWindowSafeAreaPolicy.reservesSystemSafeArea,
                dragRegionHeight: 52,
                trafficLightOffset: Point(x: 0, y: ProjectOpeningLayout.trafficLightOffsetY)
            ),
            showsImmediately: false,
            makeKey: true
        )

        let editorWindow = UIWindowManager.shared.spawnWindow(configuration: configuration) {
            EditorView(project: project)
        }
        promoteToPrimaryWindow(editorWindow)
        editorWindow.showWindow(makeFocused: true)
        pickerWindow?.close()
    }

    static func openWelcome(makeFocused: Bool = true, beginCreatingProject: Bool = false) {
        let configuration = UIWindow.Configuration(
            title: windowTitlePrefix,
            frame: Rect(x: 0, y: 0, width: ProjectOpeningLayout.windowWidth, height: ProjectOpeningLayout.windowHeight),
            minimumSize: Size(width: ProjectOpeningLayout.windowWidth, height: ProjectOpeningLayout.windowHeight),
            mode: .windowed,
            titleBar: .init(
                background: .transparent,
                reservesSafeArea: EditorWindowSafeAreaPolicy.reservesSystemSafeArea,
                dragRegionHeight: 52,
                trafficLightOffset: Point(x: 0, y: ProjectOpeningLayout.trafficLightOffsetY)
            ),
            showsImmediately: false,
            makeKey: true,
            hasShadow: ProjectOpeningWindowConfiguration.hasShadow,
            isResizable: ProjectOpeningWindowConfiguration.isResizable
        )
        let window = UIWindowManager.shared.spawnWindow(configuration: configuration) {
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
