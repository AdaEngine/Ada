//
//  ApplicationCreate.swift
//  AdaEngine
//
//  Created by v.prusakov on 10/9/21.
//

#if WASM && canImport(JavaScriptEventLoop)
    import _CJavaScriptKit
    import JavaScriptEventLoop
#endif

/// A type that represents the structure and behavior of an app.
@MainActor @preconcurrency
public protocol App: Sendable {
    /// The content of the app.
    associatedtype Content: AppScene

    /// Creates an instance of the app using the body that you define for its content.
    init()

    /// Main scene in your app.
    var body: Content { get }
}

extension App {
    public init() {
        self.init()
    }

    // Initializes and runs the app.
    #if WASM && canImport(JavaScriptEventLoop)
        public static func main() {
            JavaScriptEventLoop.installGlobalExecutor()
            Task { @MainActor in
                do {
                    try await AppRuntime.run(Self())
                } catch {
                    print("AdaEngine finished with error: \(error)")
                }
            }
            swjs_unsafe_event_loop_yield()
        }
    #else
        public static func main() async throws {
            try await AppRuntime.run(Self())
        }
    #endif
}

/// Starts a native AdaEngine application from a preconstructed app value.
///
/// Process entry points use this host API. Runtime-loaded projects create
/// sessions inside that host instead of defining or invoking another `@main`.
@MainActor
public enum AppRuntime {
    public static func run<Application: App>(_ application: Application) async throws {
        let appContext = AppContext(application)
        try await appContext.run()
    }
}
