//
//  AdaEditorApp.swift
//  AdaEngine
//
//  Created by v.prusakov on 8/10/21.
//

import AdaEngine
import Foundation
import Logging

#if canImport(AdaMCPPlugin)
    import AdaMCPPlugin
#endif

@main
enum AdaApplicationEntry {
    @MainActor static func main() async throws {
        if Bundle.main.bundleIdentifier == "org.adaengine.player" || CommandLine.arguments.contains("--ada-player") {
            try await AppRuntime.run(AdaPlayerApp())
        } else {
            try await AppRuntime.run(AdaEditorApp())
        }
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

    private static var mcpPort: Int {
        let value = CommandLine.arguments.first { $0.hasPrefix("--mcp-port=") }?.split(separator: "=").last
        guard let value, let port = Int(value), (0...65535).contains(port) else {
            return 2510
        }
        return port
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
                        host: "127.0.0.1",
                        port: Self.mcpPort,
                        endpoint: "/mcp",
                        serverName: "Ada Editor",
                        serverVersion: "0.1.0",
                        instructions: """
                            Inspect and automate the live Ada Editor. Use world.list_worlds to select Main or a SceneView subworld,
                            automation.capabilities for writable types, automation.run for YAML/JSON steps, logs.read for cursor-based logs,
                            and profiler.live_snapshot for metrics. Runtime ECS changes are not saved to scene files.
                            """
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
