#if os(iOS)
    @_spi(AdaEngine) import AdaEngine
    #if DEBUG && canImport(AdaMCPPlugin)
        import AdaMCPPlugin
        import Foundation
    #endif

    struct AdaEditorPhoneApp: App {
        var body: some AppScene {
            WindowGroup {
                MobileEditorRootView()
                    .theme(.adaEditor)
            }
            .windowMode(.windowed)
            .windowTitle("Ada Studio")
            #if DEBUG && canImport(AdaMCPPlugin)
                .addPlugins(MCPPlugin(configuration: .init(
                    enableHTTP: CommandLine.arguments.contains { $0.hasPrefix("--mcp-port=") },
                    enableStdio: false,
                    host: EditorMCPServerAddress.host,
                    port: EditorMCPServerAddress.port,
                    endpoint: EditorMCPServerAddress.endpoint,
                    serverName: "Ada Studio Mobile"
                )))
            #endif
        }
    }
#endif
