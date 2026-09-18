//
//  AppPlatformPlugin.swift
//  AdaEngine
//
//  Created by Vladislav Prusakov on 29.05.2025.
//

import AdaApp
import AdaECS
import AdaUI
import AdaUtils
import Logging

/// Plugin that configurate AdaEngine for specific platform.
public struct AppPlatformPlugin: Plugin {
    public init() {}

    @MainActor
    public func setup(in app: AppWorlds) {
        let argc = CommandLine.argc
        let argv = unsafe CommandLine.unsafeArgv

        do {
            let application: Application
            #if os(macOS)
                application = unsafe try MacApplication(argc: argc, argv: argv)
            #endif

            #if os(iOS) || os(tvOS) || os(visionOS)
                application = unsafe try AppleEmbeddedApplication(argc: argc, argv: argv)
            #endif

            #if os(Android)
                application = unsafe try AndroidApplication(argc: argc, argv: argv)
            #endif

            #if os(Linux)
                application = unsafe try LinuxApplication(argc: argc, argv: argv)
            #endif

            #if os(Windows)
                application = unsafe try WindowsApplication(argc: argc, argv: argv)
            #endif

            #if WASM
                application = unsafe try BrowserApplication(argc: argc, argv: argv)
            #endif

            Application.shared = application
            app.insertResource(application)
            app.insertResource(
                WindowManagerResource(windowManager: application.windowManager)
            )

            app.addSystem(ApplicationUpdateSystem.self, on: .preUpdate)

            app.setRunner {
                do {
                    #if ENABLE_RUN_IN_CONCURRENCY
                        try await application.run(app)
                    #else
                        try application.run(app)
                    #endif
                } catch {
                    Logger(label: "org.adaengine.AppPlatform").error("\(error)")
                }
            }
        } catch {
            fatalError("Can't initialise application: \(error)")
        }
    }
}

@System
@MainActor
public func ApplicationUpdate(
    _ windowManager: Res<WindowManagerResource>
) async {
    if windowManager.windowManager.windows.isEmpty,
        Application.shared.lastWindowCloseBehavior == .terminateApplication {
        Application.shared.terminate()
    }
}
