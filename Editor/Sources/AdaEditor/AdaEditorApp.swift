//
//  AdaEditorApp.swift
//  AdaEngine
//
//  Created by v.prusakov on 8/10/21.
//

import AdaEngine
import Foundation
import Logging

#if os(iOS)
    import UIKit
#endif

#if canImport(AdaMCPPlugin)
    import AdaMCPPlugin
#endif

@main
enum AdaApplicationEntry {
    @MainActor static func main() async throws {
        if Bundle.main.bundleIdentifier == "org.adaengine.player" || CommandLine.arguments.contains("--ada-player") {
            try await AppRuntime.run(AdaPlayerApp())
            return
        }
        #if os(iOS)
            if UIDevice.current.userInterfaceIdiom == .phone {
                try await AppRuntime.run(AdaEditorPhoneApp())
                return
            }
        #endif
        try await AppRuntime.run(AdaEditorApp())
    }
}

struct AdaEditorApp: App {
    init() {
        EditorComponentRegistry.registerBuiltIns()
        _ = EditorProjectOpenURLRouter.shared
        EditorAchievementBootstrap.install()
        EditorCloudSettingsView.installSync()
        let notifications = EditorNotificationCenter.shared
        notifications.onAction = { EditorNotificationRouter.shared.receive($0) }
        #if os(macOS) || os(iOS)
            EditorSystemNotifications.shared.install(on: notifications)
        #endif
        Task {
            await notifications.start()
            EditorUpdateCenter.shared.start()
        }
    }

    var body: some AppScene {
        WindowGroup {
            ProjectOpeningView()
        }
        .windowMode(.windowed)
        .windowTitle("Ada Editor")
        .windowTitleBar(
            WindowTitleBar(
                background: .transparent,
                reservesSafeArea: EditorWindowSafeAreaPolicy.reservesSystemSafeArea,
                dragRegionHeight: 52
            )
        )
        .windowTrafficLightOffset(x: 0, y: ProjectOpeningLayout.trafficLightOffsetY)
        .windowShadow(ProjectOpeningWindowConfiguration.hasShadow)
        .windowResizable(ProjectOpeningWindowConfiguration.isResizable)
        .minimumSize(width: ProjectOpeningLayout.windowWidth, height: ProjectOpeningLayout.windowHeight)
        #if canImport(AdaMCPPlugin)
            .addPlugins(
                MCPPlugin(
                    configuration: .init(
                        enableHTTP: true,
                        enableStdio: true,
                        host: EditorMCPServerAddress.host,
                        port: EditorMCPServerAddress.port,
                        endpoint: EditorMCPServerAddress.endpoint,
                        serverName: "Ada Editor",
                        serverVersion: "0.1.0",
                        instructions: """
                            Inspect and automate the live Ada Editor and its open project. Use editor.project.context and editor.scene.list_open
                            to orient first. Use editor.scene.get before editor.scene.apply and pass the returned revision. Structured scene edits
                            update the open document, enter Ada Editor undo history, and are saved through the editor's normal save/autosave path.
                            Use editor.build.start/editor.test.start/editor.play.start for project tasks, editor.task.status to poll, and editor.output.read for logs.
                            Use editor.gravity.* tools for project-aware Gravity LSP operations on .ada and .gravity files. Runtime ECS changes made with automation.run are not saved to scene files.
                            """,
                        additionalTools: {
                            EditorAgentMCPTools.tools()
                                + EditorAgentWorkspaceMCPTools.tools()
                                + EditorAgentGravityMCPTools.tools()
                        },
                        additionalToolHandler: { name, arguments in
                            if let result = EditorAgentMCPTools.shared.handle(name: name, arguments: arguments) {
                                return result
                            }
                            if let result = EditorAgentWorkspaceMCPTools.shared.handle(name: name, arguments: arguments) {
                                return result
                            }
                            return await EditorAgentGravityMCPTools.shared.handle(name: name, arguments: arguments)
                        }
                    )
                )
            )
        #endif
    }
}

extension Foundation.Bundle {
    public static var editor: Foundation.Bundle {
        #if SWIFT_PACKAGE
            return Self.module
        #else
            return Foundation.Bundle(for: BundleToken.self)
        #endif
    }
}

#if !SWIFT_PACKAGE
    class BundleToken {}
#endif
