//
//  AppContext.swift
//  AdaEngine
//
//  Created by v.prusakov on 4/30/24.
//

import AdaECS
import AdaUtils
import Logging

#if WASM && canImport(JavaScriptEventLoop)
    import JavaScriptEventLoop
#endif

/// The context of the app.
@MainActor
@_spi(Internal)
public struct AppContext<T: App>: ~Copyable {
    /// The app.
    private let app: T

    /// Initialize a new app context.
    /// - Throws: An error if the app cannot be initialized.
    init() throws {
        self.app = T()
    }

    /// Initialize a new app context.
    /// - Parameter app: The app to initialize the context with.
    @_spi(Internal)
    public init(_ app: T) {
        self.app = app
    }

    /// Run the app.
    /// - Throws: An error if the app cannot be run.
    @_spi(Internal)
    public func run() async throws {
        #if WASM && canImport(JavaScriptEventLoop)
            JavaScriptEventLoop.installGlobalExecutor()
        #endif

        LoggingSystem.bootstrap {
            MultiplexLogHandler([StreamLogHandler.standardError(label: $0), RuntimeLogHandler(label: $0)])
        }
        let appWorlds = AppWorlds(main: World(name: "MainWorld"))
        AppWorldsSession.current = appWorlds
        appWorlds
            .insertResource(WindowSettings())
            .insertResource(SimulationControl())
            .addPlugin(MainSchedulerPlugin())

        let inputs = _SceneInputs(appWorlds: appWorlds)
        let node = _AppSceneNode(value: app.body)
        _ = T.Content._makeView(node, inputs: inputs)

        try await appWorlds.build()

        #if ENABLE_RUN_IN_CONCURRENCY
            await appWorlds.runner?()
        #else
            appWorlds.runner?()
        #endif
    }
}
